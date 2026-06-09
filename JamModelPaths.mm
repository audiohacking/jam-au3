// Copyright 2026 Google LLC
//
// Fork-owned sandbox path discovery for MRT2 AUv3.

#import "JamModelPaths.h"
#import "MagentaModelManager.h"
#include "magenta_paths.h"

@implementation JamModelPaths

+ (NSArray<NSString *> *)defaultResourceSearchPaths {
    NSMutableOrderedSet<NSString*>* paths = [NSMutableOrderedSet orderedSet];

    NSString* customPath = [[NSUserDefaults standardUserDefaults] objectForKey:@"MagentaRT_CustomResourcesPath"];
    if (customPath.length > 0) {
        [paths addObject:customPath];
    }

    NSString* realHome = NSHomeDirectoryForUser(NSUserName());
    NSString* magentaRoot = [realHome stringByAppendingPathComponent:@"Documents/Magenta"];
    [paths addObject:[magentaRoot stringByAppendingPathComponent:@"magenta-rt-v2/resources"]];
    [paths addObject:[magentaRoot stringByAppendingPathComponent:@"resources"]];
    [paths addObject:[NSString stringWithUTF8String:magentart::paths::get_resources_dir().c_str()]];

    return paths.array;
}

+ (BOOL)resourcesValidAtPath:(NSString *)resourcesDir {
    if (resourcesDir.length == 0) return NO;

    NSFileManager* fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:resourcesDir isDirectory:&isDir] || !isDir) {
        return NO;
    }

    NSString* cocaDir = [resourcesDir stringByAppendingPathComponent:@"musiccoca"];
    NSString* streamDir = [resourcesDir stringByAppendingPathComponent:@"spectrostream"];
    if (![fm fileExistsAtPath:cocaDir isDirectory:&isDir] || !isDir) return NO;
    if (![fm fileExistsAtPath:streamDir isDirectory:&isDir] || !isDir) return NO;

    NSError* error = nil;
    NSArray<NSString*>* cocaFiles = [fm contentsOfDirectoryAtPath:cocaDir error:&error];
    if (error) return NO;
    BOOL hasTflite = NO;
    for (NSString* name in cocaFiles) {
        if ([name.pathExtension isEqualToString:@"tflite"]) {
            hasTflite = YES;
            break;
        }
    }

    NSArray<NSString*>* streamFiles = [fm contentsOfDirectoryAtPath:streamDir error:&error];
    if (error) return NO;
    BOOL hasMlxfn = NO;
    for (NSString* name in streamFiles) {
        if ([name.pathExtension isEqualToString:@"mlxfn"]) {
            hasMlxfn = YES;
            break;
        }
    }

    return hasTflite && hasMlxfn;
}

+ (BOOL)sharedResourcesAvailableOnDisk {
    for (NSString* path in [self defaultResourceSearchPaths]) {
        if ([self resourcesValidAtPath:path]) {
            return YES;
        }
    }
    return NO;
}

+ (NSArray<NSString *> *)defaultModelsSearchPaths {
    NSMutableOrderedSet<NSString*>* paths = [NSMutableOrderedSet orderedSet];
    NSString* savedPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_ModelFolderPath"];
    if (savedPath.length > 0) {
        [paths addObject:savedPath];
    }
    savedPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"DownloadFolderPath"];
    if (savedPath.length > 0) {
        [paths addObject:savedPath];
    }

    NSString* realHome = NSHomeDirectoryForUser(NSUserName());
    NSString* magentaRoot = [realHome stringByAppendingPathComponent:@"Documents/Magenta"];
    [paths addObject:[magentaRoot stringByAppendingPathComponent:@"magenta-rt-v2/models"]];
    [paths addObject:[magentaRoot stringByAppendingPathComponent:@"models"]];
    [paths addObject:[MagentaModelManager defaultModelsDirectory]];
    [paths addObject:[NSString stringWithUTF8String:magentart::paths::get_models_dir().c_str()]];
    return paths.array;
}

+ (NSString *)resolveResourcesPath {
    for (NSString* path in [self defaultResourceSearchPaths]) {
        if ([self resourcesValidAtPath:path]) {
            return path;
        }
    }
    return [NSString stringWithUTF8String:magentart::paths::get_resources_dir().c_str()];
}

+ (void)ensureCustomResourcesPath {
    NSString* current = [[NSUserDefaults standardUserDefaults] objectForKey:@"MagentaRT_CustomResourcesPath"];
    if (current.length > 0 && [self resourcesValidAtPath:current]) {
        return;
    }
    if (current.length > 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"MagentaRT_CustomResourcesPath"];
    }
    NSString* resolved = [self resolveResourcesPath];
    if ([self resourcesValidAtPath:resolved]) {
        [[NSUserDefaults standardUserDefaults] setObject:resolved forKey:@"MagentaRT_CustomResourcesPath"];
        NSLog(@"Jam_AU: using resources at %@", resolved);
    }
}

@end
