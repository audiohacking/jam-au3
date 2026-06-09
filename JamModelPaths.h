// Copyright 2026 Google LLC
//
// Fork-owned sandbox path discovery for MRT2 AUv3.
// Keeps model-loading policy out of the magenta-realtime submodule.

#pragma once

#import <Foundation/Foundation.h>

@interface JamModelPaths : NSObject

/// Candidate resource directories (custom path, then standard Magenta layouts).
+ (NSArray<NSString *> *)defaultResourceSearchPaths;

/// True when musiccoca (*.tflite) and spectrostream (*.mlxfn) exist under `resourcesDir`.
+ (BOOL)resourcesValidAtPath:(NSString *)resourcesDir;

/// True if any default resource search path validates on disk.
+ (BOOL)sharedResourcesAvailableOnDisk;

/// Standard locations to scan for installed models (saved folder, then ~/Documents/Magenta layouts).
+ (NSArray<NSString *> *)defaultModelsSearchPaths;

/// First valid resources directory from default search paths.
+ (NSString *)resolveResourcesPath;

/// Persist MagentaRT_CustomResourcesPath when a valid resources tree is found on disk.
+ (void)ensureCustomResourcesPath;

@end
