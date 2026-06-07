// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Jam AUv3 Audio Unit — Magenta RealTime Jam instrument for DAW hosts.

#import "Jam_AudioUnit.h"
#import <AVFoundation/AVFoundation.h>
#import "MagentaModelDownloader.h"
#include "magenta_paths.h"
#include "MagentaSettings.h"

@interface JamAudioUnit ()
#if MAGENTART_DEBUG_LOG
@property (nonatomic, copy) void (^debugLogHandler)(NSString *);
#endif
@property (nonatomic, strong) NSMutableArray* logHistory;
@end

@implementation JamAudioUnit {
    RealtimeRunner _engine;
    AUParameterTree* _parameterTree;
    AUAudioUnitBus* _outputBus;
    AUAudioUnitBusArray* _outputBusArray;
    BOOL _modelLoaded;
    AudioConverterRef _resampler;
    float* _resampleBufferL;
    float* _resampleBufferR;
    float* _resampleBufferInterleaved;
    BOOL _isOffline;                 // current state, read by render block
    // Transport and musical context block caching. The host may set these after
    // internalRenderBlock is called, so we can't capture them there. The
    // metrics timer (main thread) caches them once they appear. We keep a
    // strong reference so the blocks stay alive even if the host later
    // sets the property to nil (e.g. during/after offline export).
    AUHostTransportStateBlock _retainedTransportBlock;
    void* _transportBlockPtr;        // raw pointer for render thread (no ARC)
    AUHostMusicalContextBlock _retainedMusicalContextBlock;
    void* _musicalContextBlockPtr;   // raw pointer for render thread (no ARC)
    NSMutableArray* _pendingLogs;
    JamSharedState _sharedState;
    std::atomic<bool> _soloMode;
    std::atomic<float> _gateLevel;
    std::atomic<float> _gateDecaySeconds;
    std::atomic<float> _cfgNotesSliderValue;
    std::atomic<float> _cfgNotesCurrentLevel;
}

// Fallback init — the extension system may call plain init before the factory method.
// Redirect to the designated initializer with our registered component description.
- (instancetype)init {
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_MusicDevice,
        .componentSubType = 'JAM3',
        .componentManufacturer = 'AHck',
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    return [self initWithComponentDescription:desc options:0 error:nil];
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError**)outError {
    self = [super initWithComponentDescription:componentDescription
                                       options:options
                                         error:outError];
    if (!self) return nil;

    _modelLoaded = NO;
    _gateLevel.store(1.0f, std::memory_order_relaxed);
    _gateDecaySeconds.store(2.0f, std::memory_order_relaxed);
    _cfgNotesCurrentLevel.store(50.0f, std::memory_order_relaxed);

    BOOL savedSoloMode = NO;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"Jam_SoloMode"]) {
        savedSoloMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"Jam_SoloMode"];
    }
    _soloMode.store(savedSoloMode, std::memory_order_relaxed);

    float savedCfgNotes = [[NSUserDefaults standardUserDefaults] floatForKey:@"Jam_Param_cfgnotes"];
    _cfgNotesSliderValue.store(savedCfgNotes > 0.0f ? savedCfgNotes : kMagentaDefaultCfgNotes,
                               std::memory_order_relaxed);

    NSString* customResources = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_CustomResourcesPath"];
    std::string resourcesPath = customResources
        ? std::string(customResources.UTF8String)
        : magentart::paths::get_resources_dir();
    if (_engine.init_assets(resourcesPath.c_str())) {
        _modelLoaded = YES;
        _engine.load_musiccoca_model(resourcesPath.c_str(), "musiccoca");
    } else {
        NSLog(@"Jam_AU: Failed to load static assets externally from: %s", resourcesPath.c_str());
    }

    auto makeParam = ^(NSString* ident, NSString* name, AUParameterAddress addr, float min, float max, float def) {
        AUParameter* p = [AUParameterTree
            createParameterWithIdentifier:ident name:name address:addr min:min max:max
            unit:kAudioUnitParameterUnit_Generic unitName:nil
            flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
            valueStrings:nil dependentParameters:nil];
        p.value = def;
        return p;
    };

    AUParameter* tempParam = makeParam(@"temperature", @"Temperature", 0, 0.0, 3.0, 1.3);
    AUParameter* topkParam = makeParam(@"topk", @"Top-K", 1, 1, 1024, 40);
    AUParameter* cfgMusicCoCaParam = makeParam(@"cfgmusiccoca", @"Prompt Adherence", 3, -1.0, 7.0, 3.0);
    AUParameter* cfgNotesParam = makeParam(@"cfgnotes", @"Note Adherence", 4, -1.0, 7.0, 1.0);
    AUParameter* volParam = makeParam(@"volume", @"Volume", 5, -60.0, 12.0, 0.0);

    AUParameter* muteParam = [AUParameterTree
        createParameterWithIdentifier:@"mute" name:@"Mute" address:6 min:0.0 max:1.0
        unit:kAudioUnitParameterUnit_Boolean unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:nil dependentParameters:nil];
    muteParam.value = 0.0;

    AUParameter* unmaskWidthParam = makeParam(@"unmaskwidth", @"Unmask width", 7, 0, 127, 0);

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    float savedBufSize = [defaults objectForKey:@"Jam_AU_BufferSize"] ? [defaults floatForKey:@"Jam_AU_BufferSize"] : 0.0f;

    AUParameter* bufSizeParam = [AUParameterTree
        createParameterWithIdentifier:@"buffersize" name:@"Buffer Size" address:8 min:0.0 max:2.0
        unit:kAudioUnitParameterUnit_Indexed unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:@[@"2048", @"4096", @"8192"] dependentParameters:nil];
    bufSizeParam.value = savedBufSize;

    // Initialize C++ engine's buffer size to match
    size_t initialCap = 8192;
    if (savedBufSize < 0.5f) initialCap = 2048;
    else if (savedBufSize < 1.5f) initialCap = 4096;
    _engine.set_buffer_size(initialCap);

    _engine.set_latency_comp(true);

    AUParameter* latencyCompParam = [AUParameterTree
        createParameterWithIdentifier:@"latencycomp" name:@"Latency Comp" address:9 min:0.0 max:1.0
        unit:kAudioUnitParameterUnit_Boolean unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:nil dependentParameters:nil];
    latencyCompParam.value = 1.0; // Default on

    // Blend weight parameters (addresses 10-15)
    NSMutableArray* weightParams = [NSMutableArray array];
    for (int i = 0; i < 6; i++) {
        NSString* ident = [NSString stringWithFormat:@"weight_%d", i];
        NSString* name = [NSString stringWithFormat:@"Weight %d", i];
        [weightParams addObject:makeParam(ident, name, 10 + i, 0.0, 1.0, 0.0)];
    }

    // Reset state (edge-detected boolean, address 31)
    AUParameter* resetParam = [AUParameterTree
        createParameterWithIdentifier:@"resetstate" name:@"Reset State" address:31 min:0.0 max:1.0
        unit:kAudioUnitParameterUnit_Boolean unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:nil dependentParameters:nil];
    resetParam.value = 0.0;

    // Bypass (address 32)
    AUParameter* bypassParam = [AUParameterTree
        createParameterWithIdentifier:@"bypass" name:@"Bypass" address:32 min:0.0 max:1.0
        unit:kAudioUnitParameterUnit_Boolean unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:nil dependentParameters:nil];
    bypassParam.value = 0.0;

    // Drumless (address 39)
    AUParameter* drumlessParam = [AUParameterTree
        createParameterWithIdentifier:@"drumless" name:@"Filter Drums" address:39 min:0.0 max:1.0
        unit:kAudioUnitParameterUnit_Boolean unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:nil dependentParameters:nil];
    drumlessParam.value = 0.0;

    AUParameter* midiGateParam = [AUParameterTree
        createParameterWithIdentifier:@"midigate" name:@"MIDI Gate" address:45 min:0.0 max:1.0
        unit:kAudioUnitParameterUnit_Boolean unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:nil dependentParameters:nil];
    midiGateParam.value = 0.0;

    AUParameter* onsetModeParam = [AUParameterTree
        createParameterWithIdentifier:@"onsetmode" name:@"Onset Mode" address:46 min:0.0 max:1.0
        unit:kAudioUnitParameterUnit_Indexed unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:@[@"Mask", @"Unmask"] dependentParameters:nil];
    onsetModeParam.value = 0.0;

    // Seed Rotation (address 47)
    AUParameter* seedRotationParam = [AUParameterTree
        createParameterWithIdentifier:@"seedrotation" name:@"Seed Rotation" address:47 min:0.0 max:1000.0
        unit:kAudioUnitParameterUnit_Indexed unitName:nil
        flags:kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable
        valueStrings:nil dependentParameters:nil];
    seedRotationParam.value = 0.0;

    AUParameter* cfgDrumsParam = makeParam(@"cfgdrums", @"Drums Adherence", 48, -1.0, 7.0, 1.0);

    NSMutableArray* allParams = [NSMutableArray arrayWithArray:@[
        tempParam, topkParam, cfgMusicCoCaParam, cfgNotesParam, volParam, muteParam, unmaskWidthParam, bufSizeParam, latencyCompParam,
        cfgDrumsParam
    ]];
    [allParams addObjectsFromArray:weightParams];
    [allParams addObjectsFromArray:@[resetParam, bypassParam, seedRotationParam]];
    [allParams addObject:drumlessParam];
    [allParams addObject:midiGateParam];
    [allParams addObject:onsetModeParam];

    _parameterTree = [AUParameterTree createTreeWithChildren:allParams];

    __unsafe_unretained JamAudioUnit* weakSelf = self;
    _parameterTree.implementorValueObserver = ^(AUParameter* param, AUValue value) {
        if (param.address == 0) weakSelf->_engine.set_temperature(value);
        else if (param.address == 1) weakSelf->_engine.set_top_k((int)value);
        else if (param.address == 3) weakSelf->_engine.set_cfg_musiccoca(value);
        else if (param.address == 4) weakSelf->_engine.set_cfg_notes(value);
        else if (param.address == 5) weakSelf->_engine.set_volume_db(value);
        else if (param.address == 6) weakSelf->_engine.set_mute(value > 0.5f);
        else if (param.address == 7) weakSelf->_engine.set_unmask_width((int)value);
        else if (param.address == 8) {
            size_t cap = 8192;
            if (value < 0.5f) cap = 2048;
            else if (value < 1.5f) cap = 4096;
            weakSelf->_engine.set_buffer_size(cap);
            [[NSUserDefaults standardUserDefaults] setFloat:value forKey:@"Jam_AU_BufferSize"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf willChangeValueForKey:@"latency"];
                [weakSelf didChangeValueForKey:@"latency"];
            });
        }
        else if (param.address == 9) {
            weakSelf->_engine.set_latency_comp(value > 0.5f);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf willChangeValueForKey:@"latency"];
                [weakSelf didChangeValueForKey:@"latency"];
            });
        }
        else if (param.address >= 10 && param.address <= 15) weakSelf->_engine.set_blend_weight((int)param.address - 10, value);
        else if (param.address == 31) {
            if (value > 0.5f) weakSelf->_engine.trigger_reset();
        }
        else if (param.address == 32) weakSelf->_engine.set_bypass(value > 0.5f);
        else if (param.address == 39) weakSelf->_engine.set_drumless(value > 0.5f);
        else if (param.address == 45) weakSelf->_engine.set_midi_gate_enabled(value > 0.5f);
        else if (param.address == 46) weakSelf->_engine.set_onset_mode(value > 0.5f);
        else if (param.address == 48) weakSelf->_engine.set_cfg_drums(value);
        else if (param.address == 47) weakSelf->_engine.set_seed_rotation((int)value);
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter* param) {
        if (param.address == 0) return weakSelf->_engine.get_temperature();
        else if (param.address == 1) return (AUValue)weakSelf->_engine.get_top_k();
        else if (param.address == 3) return weakSelf->_engine.get_cfg_musiccoca();
        else if (param.address == 4) return weakSelf->_engine.get_cfg_notes();
        else if (param.address == 5) return weakSelf->_engine.get_volume_db();
        else if (param.address == 6) return weakSelf->_engine.get_mute() ? 1.0f : 0.0f;
        else if (param.address == 7) return (AUValue)weakSelf->_engine.get_unmask_width();
        else if (param.address == 8) {
            size_t cap = weakSelf->_engine.get_buffer_size();
            if (cap <= 2048) return 0.0f;
            if (cap <= 4096) return 1.0f;
            return 2.0f;
        }
        else if (param.address == 9) return weakSelf->_engine.get_latency_comp() ? 1.0f : 0.0f;
        else if (param.address >= 10 && param.address <= 15) return weakSelf->_engine.get_blend_weight((int)param.address - 10);
        else if (param.address == 31) return 0.0f; // reset is momentary
        else if (param.address == 32) return weakSelf->_engine.get_bypass() ? 1.0f : 0.0f;
        else if (param.address == 39) return weakSelf->_engine.get_drumless() ? 1.0f : 0.0f;
        else if (param.address == 45) return weakSelf->_engine.get_midi_gate_enabled() ? 1.0f : 0.0f;
        else if (param.address == 46) return weakSelf->_engine.get_onset_mode() ? 1.0f : 0.0f;
        else if (param.address == 48) return weakSelf->_engine.get_cfg_drums();
        else if (param.address == 47) return (AUValue)weakSelf->_engine.get_seed_rotation();
        return 0.0;
    };

    // Output bus: stereo 48000 Hz float
    AVAudioFormat* format = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:48000.0 channels:2];
    NSError* busError = nil;
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:&busError];
    if (busError) {
        if (outError) *outError = busError;
        return nil;
    }
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                              busType:AUAudioUnitBusTypeOutput
                                                               busses:@[_outputBus]];

    self.maximumFramesToRender = 4096;

    return self;
}

- (void)pollOfflineState {
    _isOffline = self.isRenderingOffline;

    // Cache the transport block once it becomes available.  The host may
    // set it after internalRenderBlock is called, and may remove it during
    // offline export.  We retain it permanently so the render block can
    // always query transport state.
    if (!_transportBlockPtr) {
        AUHostTransportStateBlock tb = self.transportStateBlock;
        if (tb) {
            _retainedTransportBlock = tb;              // keeps it alive
            _transportBlockPtr = (__bridge void*)tb;   // for render thread
        }
    }

    // Cache the musical context block for the same reasons.
    if (!_musicalContextBlockPtr) {
        AUHostMusicalContextBlock mcb = self.musicalContextBlock;
        if (mcb) {
            _retainedMusicalContextBlock = mcb;
            _musicalContextBlockPtr = (__bridge void*)mcb;
        }
    }
}

- (NSTimeInterval)latency {
    return _engine.get_latency_samples() / 48000.0;
}

// Called by the host when switching between online/offline rendering.
// Updates _isOffline immediately so the render block uses blocking reads
// from the very first offline render call.
- (void)setRenderingOffline:(BOOL)renderingOffline {
    [super setRenderingOffline:renderingOffline];
    _isOffline = renderingOffline;
    if (renderingOffline) {
        // Ensure bounce/export renders audio even if the Jam UI play button is off.
        _uiPlaying = YES;
        _engine.set_bypass(false);
    }
}

- (BOOL)shouldBypassEffect {
    return _engine.get_host_bypass();
}

- (void)setShouldBypassEffect:(BOOL)shouldBypassEffect {
    [super setShouldBypassEffect:shouldBypassEffect];
    _engine.set_host_bypass(shouldBypassEffect);
}

- (void)dealloc {
    _engine.stop();
    _engine.unload();
}

// --- Bus Arrays ---------------------------------------------------------------

- (AUAudioUnitBusArray*)outputBusses {
    return _outputBusArray;
}

// --- Parameter Tree -----------------------------------------------------------

- (AUParameterTree*)parameterTree {
    return _parameterTree;
}

// --- State Serialization ------------------------------------------------------

- (void)applyCustomState:(NSDictionary<NSString *, id> *)state {
    if (state[@"JAM_Prompt"]) self.promptText = state[@"JAM_Prompt"];
    if (state[@"JAM_ModelName"]) self.modelName = state[@"JAM_ModelName"];
    if (state[@"JAM_SoloMode"]) {
        _soloMode.store([state[@"JAM_SoloMode"] boolValue], std::memory_order_relaxed);
    }

    NSString *customResources = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_CustomResourcesPath"];
    std::string loadPathStr = customResources ? std::string(customResources.UTF8String) : magentart::paths::get_resources_dir();
    _engine.load_musiccoca_model(loadPathStr.c_str(), "musiccoca");

    if (state[@"JAM_AudioEmbeddings"]) {
        NSDictionary* audioEmbeddings = state[@"JAM_AudioEmbeddings"];
        for (NSString* key in audioEmbeddings) {
            int index = key.intValue;
            NSData* data = audioEmbeddings[key];
            if (data.length == 768 * sizeof(float)) {
                self->_engine.set_audio_embedding(index, (const float*)data.bytes);
            }
        }
    }

    if (state[@"JAM_ModelBookmark"]) {
        self.modelBookmark = state[@"JAM_ModelBookmark"];

        // Resolve security scoped bookmark
        BOOL isStale = NO;
        NSError* error = nil;
        NSURL* url = [NSURL URLByResolvingBookmarkData:self.modelBookmark
                                               options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&isStale
                                                 error:&error];
        if (url && [url startAccessingSecurityScopedResource]) {
            NSString* path = url.path;
            BOOL isDir = NO;
            [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];

            NSString* mlxfnPath = nil;
            if ([path hasSuffix:@".mlxfn"]) {
                mlxfnPath = path;
            } else if (isDir) {
                NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
                for (NSString *file in contents) {
                    if ([file hasSuffix:@".mlxfn"]) {
                        mlxfnPath = [path stringByAppendingPathComponent:file];
                        break;
                    }
                }
            }

            if (mlxfnPath) {
                // Skip reload if the engine already has a model loaded —
                // setFullState: can be called during parameter automation
                // (undo management) and must not tear down a running model.
                if (self->_engine.is_loaded()) {
                    [url stopAccessingSecurityScopedResource];
                } else {
                // Perform async load so we don't block AU initialization
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    BOOL success = self->_engine.load_model(mlxfnPath.UTF8String);
                    if (success) {
                        [self applyPromptTextToEngine:self.promptText];
                        NSLog(@"Jam_AU: Successfully auto-loaded model from bookmark.");
                    } else {
                        NSLog(@"Jam_AU: Failed to auto-load model from bookmark.");
                    }
                    [url stopAccessingSecurityScopedResource];
                });
                } // else (not already loaded)
            } else {
                [url stopAccessingSecurityScopedResource];
            }
        } else {
            NSLog(@"Jam_AU: Failed to resolve bookmark: %@", error);
        }
    }
}

- (NSDictionary<NSString *,id> *)fullState {
    NSMutableDictionary *state = [[super fullState] mutableCopy];
    if (!state) state = [NSMutableDictionary dictionary];

    if (self.promptText) state[@"JAM_Prompt"] = self.promptText;
    if (self.modelName) state[@"JAM_ModelName"] = self.modelName;
    if (self.modelBookmark) state[@"JAM_ModelBookmark"] = self.modelBookmark;
    state[@"JAM_SoloMode"] = @(_soloMode.load(std::memory_order_relaxed));

    NSMutableDictionary* audioEmbeddings = [NSMutableDictionary dictionary];
    for (int i = 0; i < 6; ++i) {
        float buffer[768];
        if (self->_engine.get_audio_embedding(i, buffer)) {
            NSData* data = [NSData dataWithBytes:buffer length:768 * sizeof(float)];
            audioEmbeddings[[NSString stringWithFormat:@"%d", i]] = data;
        }
    }
    if (audioEmbeddings.count > 0) state[@"JAM_AudioEmbeddings"] = audioEmbeddings;

    return state;
}

- (void)setFullState:(NSDictionary<NSString *,id> *)state {
    [super setFullState:state];
    [self applyCustomState:state];
}

- (NSDictionary<NSString *,id> *)fullStateForDocument {
    NSMutableDictionary *state = [[super fullStateForDocument] mutableCopy];
    if (!state) state = [NSMutableDictionary dictionary];

    if (self.promptText) state[@"JAM_Prompt"] = self.promptText;
    if (self.modelName) state[@"JAM_ModelName"] = self.modelName;
    if (self.modelBookmark) state[@"JAM_ModelBookmark"] = self.modelBookmark;

    NSMutableDictionary* audioEmbeddings = [NSMutableDictionary dictionary];
    for (int i = 0; i < 6; ++i) {
        float buffer[768];
        if (self->_engine.get_audio_embedding(i, buffer)) {
            NSData* data = [NSData dataWithBytes:buffer length:768 * sizeof(float)];
            audioEmbeddings[[NSString stringWithFormat:@"%d", i]] = data;
        }
    }
    if (audioEmbeddings.count > 0) state[@"JAM_AudioEmbeddings"] = audioEmbeddings;

    return state;
}

- (void)setFullStateForDocument:(NSDictionary<NSString *,id> *)state {
    [super setFullStateForDocument:state];
    [self applyCustomState:state];
}


// --- Lifecycle ----------------------------------------------------------------

- (BOOL)allocateRenderResourcesAndReturnError:(NSError**)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;

    [self pollOfflineState]; // Cache transport block early!
    NSString* logMsg = @"allocateRenderResourcesAndReturnError called";
    if (!self.logHistory) {
        self.logHistory = [NSMutableArray array];
    }
    [self.logHistory addObject:logMsg];
    if (self.logHistory.count > 1000) {
        [self.logHistory removeObjectAtIndex:0];
    }

#if MAGENTART_DEBUG_LOG
    if (self.debugLogHandler) {
        self.debugLogHandler(logMsg);
    }
#endif

    if (!_modelLoaded) {
        NSLog(@"Jam_AU: Assets not fully loaded, but continuing allocation to allow UI interaction.");
    }


    double outSampleRate = self.outputBusses[0].format.sampleRate;
    if (std::abs(outSampleRate - 48000.0) > 1.0) {
        AudioStreamBasicDescription outDesc = *self.outputBusses[0].format.streamDescription;
        AudioStreamBasicDescription inDesc;
        inDesc.mSampleRate = 48000.0;
        inDesc.mFormatID = kAudioFormatLinearPCM;
        inDesc.mFormatFlags = static_cast<UInt32>(kAudioFormatFlagIsFloat) | static_cast<UInt32>(kAudioFormatFlagsNativeEndian);
        inDesc.mBytesPerPacket = 8;
        inDesc.mFramesPerPacket = 1;
        inDesc.mBytesPerFrame = 8;
        inDesc.mChannelsPerFrame = 2;
        inDesc.mBitsPerChannel = 32;

        OSStatus err = AudioConverterNew(&inDesc, &outDesc, &_resampler);
        if (err != noErr) {
            NSLog(@"Jam_AU: AudioConverterNew failed with error %d", (int)err);
            if (outError) *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:nil];
            return NO;
        }

        // maximumFramesToRender could be max from host like 4096.
        // 8192 is safe up to ~96kHz -> 44.1kHz downsampling blocks
        _resampleBufferL = (float*)calloc(8192, sizeof(float));
        _resampleBufferR = (float*)calloc(8192, sizeof(float));
        _resampleBufferInterleaved = (float*)calloc(16384, sizeof(float));
    }

    _engine.start();
    return YES;
}

- (void)deallocateRenderResources {
    _engine.stop();
    if (_resampler) {
        AudioConverterDispose(_resampler);
        _resampler = NULL;
    }
    if (_resampleBufferL) {
        free(_resampleBufferL);
        _resampleBufferL = NULL;
    }
    if (_resampleBufferR) {
        free(_resampleBufferR);
        _resampleBufferR = NULL;
    }
    [super deallocateRenderResources];
}

// --- Render -------------------------------------------------------------------

struct ResamplerContext {
    RealtimeRunner* engine;
    float* tempL;
    float* tempR;
    float* tempInterleaved;
    UInt32 maxFrames;
    bool blocking;
};

static OSStatus ConverterDataProc(AudioConverterRef inAudioConverter,
                                  UInt32 *ioNumberDataPackets,
                                  AudioBufferList *ioData,
                                  AudioStreamPacketDescription **outDataPacketDescription,
                                  void *inUserData) {
    ResamplerContext* ctx = (ResamplerContext*)inUserData;

    UInt32 framesToRead = *ioNumberDataPackets;
    if (framesToRead > ctx->maxFrames) {
        framesToRead = ctx->maxFrames;
    }

    if (framesToRead == 0) {
        return noErr;
    }

    ctx->engine->read_audio_stereo(ctx->tempL, ctx->tempR, framesToRead,
                                    ctx->blocking);

    // Interleave data
    float* interleaved = ctx->tempInterleaved;
    for (UInt32 i = 0; i < framesToRead; ++i) {
        interleaved[i * 2] = ctx->tempL[i];
        interleaved[i * 2 + 1] = ctx->tempR[i];
    }

    ioData->mBuffers[0].mData = interleaved;
    ioData->mBuffers[0].mDataByteSize = framesToRead * 2 * sizeof(float);
    ioData->mBuffers[0].mNumberChannels = 2;

    *ioNumberDataPackets = framesToRead;

    if (outDataPacketDescription) {
        *outDataPacketDescription = NULL;
    }

    return noErr;
}

- (AUInternalRenderBlock)internalRenderBlock {
    // Capture raw pointers — safe: their lifetimes span allocate → deallocate.
    __unsafe_unretained JamAudioUnit* unsafeSelf = self;
    RealtimeRunner* engine = &_engine;

    // Snapshot offline state for blocking reads.
    _isOffline = self.isRenderingOffline;

    __block BOOL wasPlaying = YES;
    __block BOOL wasResetHigh = NO;
    __block BOOL wasBeatZero = NO;
    __block BOOL wasDawPlaying = NO;

    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags* actionFlags,
                               const AudioTimeStamp* timestamp,
                               AUAudioFrameCount frameCount,
                               NSInteger outputBusNumber,
                               AudioBufferList* outputData,
                               const AURenderEvent* realtimeEventListHead,
                               AURenderPullInputBlock __unsafe_unretained pullInputBlock) {

        // Read pointers dynamically to avoid capturing NULL if called before allocate.
        AudioConverterRef resampler = unsafeSelf->_resampler;
        float* tempL = unsafeSelf->_resampleBufferL;
        float* tempR = unsafeSelf->_resampleBufferR;
        float* tempInterleaved = unsafeSelf->_resampleBufferInterleaved;

        // Read offline flag first. During bounce the audio thread uses blocking
        // ring-buffer reads; inference-thread ring resets are undefined while
        // the consumer is active (see ring_buffer.h).
        bool isOffline = unsafeSelf->_isOffline;
        engine->set_offline(isOffline);

        // Process parameter and MIDI events
        for (const AURenderEvent* event = realtimeEventListHead;
             event != nullptr; event = event->head.next) {
            if (event->head.eventType == AURenderEventParameter) {
                const AUParameterEvent& paramEvent = event->parameter;
                if (paramEvent.parameterAddress == 0) engine->set_temperature(paramEvent.value);
                else if (paramEvent.parameterAddress == 1) engine->set_top_k((int)paramEvent.value);
                else if (paramEvent.parameterAddress == 3) engine->set_cfg_musiccoca(paramEvent.value);
                else if (paramEvent.parameterAddress == 4) engine->set_cfg_notes(paramEvent.value);
                else if (paramEvent.parameterAddress == 5) engine->set_volume_db(paramEvent.value);
                else if (paramEvent.parameterAddress == 6) engine->set_mute(paramEvent.value > 0.5f);
                else if (paramEvent.parameterAddress == 7) engine->set_unmask_width((int)paramEvent.value);
                else if (paramEvent.parameterAddress == 8) {
                    size_t cap = 8192;
                    if (paramEvent.value < 0.5f) cap = 2048;
                    else if (paramEvent.value < 1.5f) cap = 4096;
                    engine->set_buffer_size(cap);
                }
                else if (paramEvent.parameterAddress == 9) {
                    engine->set_latency_comp(paramEvent.value > 0.5f);
                }
                else if (paramEvent.parameterAddress >= 10 && paramEvent.parameterAddress <= 15) engine->set_blend_weight((int)paramEvent.parameterAddress - 10, paramEvent.value);
                else if (paramEvent.parameterAddress == 31) {
                    bool isHigh = paramEvent.value > 0.5f;
                    if (isHigh && !wasResetHigh && !isOffline) engine->trigger_reset();
                    wasResetHigh = isHigh;
                }
                else if (paramEvent.parameterAddress == 32) {
                    engine->set_bypass(paramEvent.value > 0.5f);
                }
                else if (paramEvent.parameterAddress == 39) {
                    engine->set_drumless(paramEvent.value > 0.5f);
                }
                else if (paramEvent.parameterAddress == 45) engine->set_midi_gate_enabled(paramEvent.value > 0.5f);
                else if (paramEvent.parameterAddress == 46) engine->set_onset_mode(paramEvent.value > 0.5f);
                else if (paramEvent.parameterAddress == 48) engine->set_cfg_drums(paramEvent.value);
            } else if (event->head.eventType == AURenderEventMIDI) {
                const AUMIDIEvent& midiEvent = event->MIDI;
                uint8_t status = midiEvent.data[0] & 0xF0;
                uint8_t note = midiEvent.data[1];
                uint8_t velocity = midiEvent.data[2];
                if (status == 0x90 && velocity > 0) { // Note On
                    engine->set_note_on(note);
                    unsafeSelf->_sharedState.noteOn(note);
                } else if (status == 0x80 || (status == 0x90 && velocity == 0)) { // Note Off
                    engine->set_note_off(note);
                    unsafeSelf->_sharedState.noteOff(note);
                }

            }
        }

        // Read the transport block from the cached raw pointer (set once
        // by pollOfflineState on the main thread, never freed).
        __unsafe_unretained AUHostTransportStateBlock transportBlock =
            (__bridge AUHostTransportStateBlock)(unsafeSelf->_transportBlockPtr);

        BOOL isDawPlaying = NO;
        BOOL isPlaying = unsafeSelf->_uiPlaying; // Start with UI play state

        if (isOffline) {
            // Logic bounce / offline export: always render. Do not run transport
            // edge logic that can reset ring buffers while blocking reads are active.
            isPlaying = YES;
            if (transportBlock) {
                AUHostTransportStateFlags flags = 0;
                double currentSamplePosition = 0;
                double cycleStartBeatPosition = 0;
                double cycleEndBeatPosition = 0;
                if (transportBlock(&flags, &currentSamplePosition, &cycleStartBeatPosition, &cycleEndBeatPosition)) {
                    engine->set_transport_flags((int)flags);
                } else {
                    engine->set_transport_flags(-3);
                }
            } else {
                engine->set_transport_flags(-2);
            }
            wasPlaying = YES;
        } else {
            if (transportBlock) {
                AUHostTransportStateFlags flags = 0;
                double currentSamplePosition = 0;
                double cycleStartBeatPosition = 0;
                double cycleEndBeatPosition = 0;
                if (transportBlock(&flags, &currentSamplePosition, &cycleStartBeatPosition, &cycleEndBeatPosition)) {
                    isDawPlaying = (flags & AUHostTransportStateMoving) != 0;
                    isPlaying = isPlaying || isDawPlaying;
                    engine->set_transport_flags((int)flags);
                } else {
                    engine->set_transport_flags(-3);
                }
            } else {
                engine->set_transport_flags(-2);
            }

            // If DAW was playing and has now stopped, stop the Audio Unit's playback as well.
            if (wasDawPlaying && !isDawPlaying) {
                unsafeSelf->_uiPlaying = NO;
                isPlaying = NO;
            }
            wasDawPlaying = isDawPlaying;

            // Edge detection from stopped to playing
            if (isPlaying && !wasPlaying) {
                engine->reset_for_playback();
                if (resampler) {
                    AudioConverterReset(resampler);
                }
            }
            wasPlaying = isPlaying;

            // Auto-reset when currentBeatPosition is exactly 0. This edge-detects the
            // transition to beat 0.0 so that resets are only triggered once (e.g., when the
            // timeline loops back to start, but not repeatedly if user pauses at the start).
            __unsafe_unretained AUHostMusicalContextBlock musicalContextBlock =
                (__bridge AUHostMusicalContextBlock)(unsafeSelf->_musicalContextBlockPtr);

            if (musicalContextBlock) {
                double currentBeatPosition = 0;
                if (musicalContextBlock(NULL, NULL, NULL, &currentBeatPosition, NULL, NULL)) {
                    if (currentBeatPosition == 0.0 && !wasBeatZero) {
                        engine->trigger_transport_reset();
                    }
                    wasBeatZero = (currentBeatPosition == 0.0);
                }
            }
        }

        float* outL = (float*)outputData->mBuffers[0].mData;
        float* outR = outputData->mNumberBuffers > 1 ? (float*)outputData->mBuffers[1].mData : outL;
        // When bypass is active, the engine writes zeros.  Signal
        // OutputIsSilence so the host can stop calling us — this may
        // restore Ableton's pre-export behavior of not rendering while
        // the transport is stopped.
        bool isBypassed = engine->get_bypass();

        if (isPlaying && !isBypassed) {
            if (resampler) {
                ResamplerContext ctx;
                ctx.engine = engine;
                ctx.tempL = tempL;
                ctx.tempR = tempR;
                ctx.tempInterleaved = tempInterleaved;
                ctx.maxFrames = 8192;
                ctx.blocking = isOffline;

                UInt32 outFrames = frameCount;
                OSStatus err = AudioConverterFillComplexBuffer(resampler, ConverterDataProc, &ctx, &outFrames, outputData, NULL);
                if (err != noErr) {
                    NSLog(@"Jam_AU: AudioConverterFillComplexBuffer failed with error %d", (int)err);
                }
            } else {
                engine->read_audio_stereo(outL, outR, frameCount, isOffline);
            }

            // Jam solo-mode gate and cfg-notes ramp (from standalone Jam app)
            bool anyNoteHeld = false;
            for (int n = 0; n < 128 && !anyNoteHeld; ++n) {
                anyNoteHeld = unsafeSelf->_sharedState.midiNotes[n].load(std::memory_order_relaxed);
            }

            bool isSolo = unsafeSelf->_soloMode.load(std::memory_order_relaxed);
            if (isSolo) {
                const float sliderVal = unsafeSelf->_cfgNotesSliderValue.load(std::memory_order_relaxed);
                const float decaySec = unsafeSelf->_gateDecaySeconds.load(std::memory_order_relaxed);
                float gate = unsafeSelf->_gateLevel.load(std::memory_order_relaxed);
                const float decayPerSample = (decaySec > 0.0f) ? (1.0f / (48000.0f * decaySec)) : 1.0f;

                for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
                    if (anyNoteHeld) {
                        gate = 1.0f;
                    } else {
                        gate -= decayPerSample;
                        if (gate < 0.0f) gate = 0.0f;
                    }
                    outL[i] *= gate;
                    outR[i] *= gate;
                }
                unsafeSelf->_gateLevel.store(gate, std::memory_order_relaxed);

                float cfgNotes = unsafeSelf->_cfgNotesCurrentLevel.load(std::memory_order_relaxed);
                const float targetVal = 50.0f;
                const float rampPerFrame = (decaySec > 0.0f)
                    ? ((targetVal - sliderVal) / (48000.0f * decaySec)) : targetVal;
                if (anyNoteHeld) {
                    cfgNotes = sliderVal;
                } else if (cfgNotes < targetVal) {
                    cfgNotes += rampPerFrame * (float)frameCount;
                    if (cfgNotes > targetVal) cfgNotes = targetVal;
                }
                unsafeSelf->_cfgNotesCurrentLevel.store(cfgNotes, std::memory_order_relaxed);
                engine->set_cfg_notes(cfgNotes);
            } else {
                unsafeSelf->_cfgNotesCurrentLevel.store(
                    unsafeSelf->_cfgNotesSliderValue.load(std::memory_order_relaxed),
                    std::memory_order_relaxed);
                unsafeSelf->_gateLevel.store(1.0f, std::memory_order_relaxed);
                engine->set_cfg_notes(unsafeSelf->_cfgNotesSliderValue.load(std::memory_order_relaxed));
            }

            unsafeSelf->_sharedState.pushAudioSamples(outL, outR, frameCount);
        } else {
            std::memset(outL, 0, frameCount * sizeof(float));
            if (outputData->mNumberBuffers > 1) {
                std::memset(outR, 0, frameCount * sizeof(float));
            }
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }

        return noErr;
    };
}

- (RealtimeRunner*)engine { return &_engine; }

- (JamSharedState*)sharedState { return &_sharedState; }

- (std::atomic<bool>*)soloMode { return &_soloMode; }

- (std::atomic<float>*)cfgNotesSliderValue { return &_cfgNotesSliderValue; }

- (void)setNoteOn:(uint8_t)note on:(BOOL)on {
    if (on) {
        _engine.set_note_on(note);
        _sharedState.noteOn(note);
    } else {
        _engine.set_note_off(note);
        _sharedState.noteOff(note);
    }
}

- (NSArray<NSNumber*>*)activeNotes {
    NSMutableArray* notes = [NSMutableArray array];
    for (int i = 0; i < 128; i++) {
        if (_sharedState.midiNotes[i].load(std::memory_order_relaxed)) {
            [notes addObject:@(i)];
        }
    }
    return notes;
}

- (void)readAudioLevels:(float*)outLeft right:(float*)outRight {
    _sharedState.levelProcessor.read_and_reset_peaks(*outLeft, *outRight);
}

- (void)applyPromptTextToEngine:(NSString*)prompt {
    BOOL isSolo = _soloMode.load(std::memory_order_relaxed);
    NSString* cleanPrompt = [prompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString* engineText = @"";
    if (cleanPrompt.length == 0) {
        engineText = @"silence";
    } else {
        engineText = isSolo ? [NSString stringWithFormat:@"SOLO %@", cleanPrompt] : cleanPrompt;
    }
    std::vector<std::string> texts = {engineText.UTF8String, "", "", "", "", ""};
    std::vector<float> weights = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    _engine.set_text_prompts(texts, weights);
    _engine.set_blend_weights(weights.data(), (int)weights.size());
}

@end
