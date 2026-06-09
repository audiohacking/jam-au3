// Copyright 2026 Google LLC
//
// Fork-owned HuggingFace downloader for sandboxed MRT2 AUv3.
// Replaces upstream MagentaModelDownloader.mm with resilient path handling.

#pragma once

#import <Foundation/Foundation.h>

@interface JamModelDownloader : NSObject

/// ~/Documents/Magenta/magenta-rt-v2 (or MAGENTA_HOME/magenta-rt-v2), never the sandbox container.
+ (NSString *)magentaHomePath;

/// Creates models/, resources/, and banks/ under magenta home; verifies write access.
+ (BOOL)ensureMagentaHomeReady:(NSError **)error;

+ (void)listRemoteModelsWithCompletion:(void (^)(NSArray<NSString *> *models, NSError *error))completion;

+ (void)downloadModel:(NSString *)modelName
             progress:(void (^)(double progress, NSString *status))progressBlock
           completion:(void (^)(BOOL success, NSError *error))completion;

+ (void)initializeSharedResourcesWithProgress:(void (^)(double progress, NSString *status))progressBlock
                                   completion:(void (^)(BOOL success, NSError *error))completion;

@end
