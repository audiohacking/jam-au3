// Copyright 2026 AudioHacking / Google LLC (Magenta RealTime)
#pragma once
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>
#include <magentart/realtime_runner.h>
#include <atomic>
#include "Jam_SharedState.h"

using magentart::core::RealtimeRunner;

@interface JamAudioUnit : AUAudioUnit

@property (nonatomic, copy) NSString* modelName;
@property (nonatomic, strong) NSData* modelBookmark;
@property (nonatomic, copy) NSString* promptText;
@property (nonatomic, assign) BOOL uiPlaying;

- (RealtimeRunner*)engine;
- (JamSharedState*)sharedState;
- (void)pollOfflineState;
- (void)setNoteOn:(uint8_t)note on:(BOOL)on;
- (NSArray<NSNumber*>*)activeNotes;
- (void)readAudioLevels:(float*)outLeft right:(float*)outRight;
- (std::atomic<bool>*)soloMode;
- (std::atomic<float>*)cfgNotesSliderValue;
- (void)applyPromptTextToEngine:(NSString*)prompt;
- (BOOL)hasInitializedAssets;
/// Resolve resources on disk and call init_assets if not already loaded.
- (BOOL)ensureAssetsInitialized;

@end

@interface JamViewController : AUViewController <AUAudioUnitFactory>
@end
