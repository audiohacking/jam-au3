// Copyright 2026 Google LLC
//
// Fork-owned HuggingFace downloader for sandboxed MRT2 AUv3.

#import "JamModelDownloader.h"
#import <stdlib.h>
#import <pwd.h>
#import <unistd.h>

static NSString *const kHfRepoId = @"google/magenta-realtime-2";
static NSString *const kHfModelsSubdir = @"models";
static NSString *const kHfResourcesSubdir = @"resources";
static const NSUInteger kMaxDownloadRetries = 3;

@interface NSString (MRT2Abbreviation)
- (NSString *)jam_stringByAbbreviatingWithMaxLength:(NSUInteger)maxLength;
@end

static dispatch_queue_t JamDownloadQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.audiohacking.jam.download", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSURLSession *JamDownloadSession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 300;
        config.timeoutIntervalForResource = 7200;
        config.waitsForConnectivity = YES;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

static void JamDispatchMain(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@implementation JamModelDownloader

+ (NSString *)magentaHomePath {
    const char *env = getenv("MAGENTA_HOME");
    if (env && env[0] != '\0') {
        return [[NSString stringWithUTF8String:env] stringByAppendingPathComponent:@"magenta-rt-v2"];
    }
    NSString *realHome = NSHomeDirectoryForUser(NSUserName());
    return [realHome stringByAppendingPathComponent:@"Documents/Magenta/magenta-rt-v2"];
}

+ (BOOL)ensureMagentaHomeReady:(NSError **)outError {
    NSString *home = [self magentaHomePath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *subdirs = @[ @"models", @"resources", @"banks" ];

    for (NSString *subdir in subdirs) {
        NSString *path = [home stringByAppendingPathComponent:subdir];
        if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:outError]) {
            NSLog(@"JamModelDownloader: failed to create %@: %@", path, *outError);
            return NO;
        }
    }

    NSString *probePath = [home stringByAppendingPathComponent:@".jam_write_probe"];
    NSError *writeError = nil;
    if (![@"ok" writeToFile:probePath atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        if (outError) *outError = writeError;
        NSLog(@"JamModelDownloader: not writable at %@: %@", home, writeError);
        return NO;
    }
    [fm removeItemAtPath:probePath error:nil];
    NSLog(@"JamModelDownloader: magenta home ready at %@", home);
    return YES;
}

+ (NSURL *)hfTreeURLForPath:(NSString *)path {
    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"https://huggingface.co/api/models/%@/tree/main/%@", kHfRepoId, encoded];
    return [NSURL URLWithString:urlString];
}

+ (NSURL *)hfResolveURLForPath:(NSString *)path {
    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"https://huggingface.co/%@/resolve/main/%@", kHfRepoId, encoded];
    return [NSURL URLWithString:urlString];
}

+ (void)listRemoteModelsWithCompletion:(void (^)(NSArray<NSString *> *models, NSError *error))completion {
    NSURL *url = [self hfTreeURLForPath:kHfModelsSubdir];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            JamDispatchMain(^{
                completion(nil, error);
            });
            return;
        }

        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (httpResp.statusCode != 200) {
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(empty)";
            NSError *apiError = [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:104 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HuggingFace API HTTP %ld: %@", (long)httpResp.statusCode, body]
            }];
            JamDispatchMain(^{
                completion(nil, apiError);
            });
            return;
        }

        NSArray *items = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSMutableArray *modelNames = [NSMutableArray array];
        if ([items isKindOfClass:[NSArray class]]) {
            for (NSDictionary *item in items) {
                if ([item[@"type"] isEqualToString:@"directory"]) {
                    NSString *path = item[@"path"];
                    NSString *name = [path lastPathComponent];
                    if (name.length > 0) {
                        [modelNames addObject:name];
                    }
                }
            }
        }

        NSArray *sorted = [modelNames sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        NSMutableArray *ordered = [sorted mutableCopy];
        NSUInteger smallIndex = [ordered indexOfObject:@"mrt2_small"];
        if (smallIndex != NSNotFound && smallIndex != 0) {
            [ordered removeObjectAtIndex:smallIndex];
            [ordered insertObject:@"mrt2_small" atIndex:0];
        }

        JamDispatchMain(^{
            completion(ordered, nil);
        });
    }] resume];
}

+ (void)downloadModel:(NSString *)modelName
             progress:(void (^)(double progress, NSString *status))progressBlock
           completion:(void (^)(BOOL success, NSError *error))completion {
    dispatch_async(JamDownloadQueue(), ^{
        NSError *readyError = nil;
        if (![self ensureMagentaHomeReady:&readyError]) {
            JamDispatchMain(^{
                completion(NO, readyError);
            });
            return;
        }

        NSString *treePath = [NSString stringWithFormat:@"%@/%@", kHfModelsSubdir, modelName];
        [self fetchFileListForTreePath:treePath code:105 label:@"model" completion:^(NSArray<NSDictionary *> *files, NSError *error) {
            if (error) {
                JamDispatchMain(^{
                    completion(NO, error);
                });
                return;
            }
            [self downloadFiles:files
                    targetIndex:0
                      modelName:modelName
                   isSharedInit:NO
                       progress:progressBlock
                     completion:completion];
        }];
    });
}

+ (void)initializeSharedResourcesWithProgress:(void (^)(double progress, NSString *status))progressBlock
                                   completion:(void (^)(BOOL success, NSError *error))completion {
    dispatch_async(JamDownloadQueue(), ^{
        NSError *readyError = nil;
        if (![self ensureMagentaHomeReady:&readyError]) {
            JamDispatchMain(^{
                completion(NO, readyError);
            });
            return;
        }

        NSString *urlString = [NSString stringWithFormat:@"https://huggingface.co/api/models/%@/tree/main/%@?recursive=true", kHfRepoId, kHfResourcesSubdir];
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]];

        progressBlock(0.01, @"Fetching resource metadata…");

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                JamDispatchMain(^{
                    completion(NO, error);
                });
                return;
            }

            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (httpResp.statusCode != 200) {
                NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                JamDispatchMain(^{
                    completion(NO, [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:107 userInfo:@{
                        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HF tree API HTTP %ld: %@", (long)httpResp.statusCode, body]
                    }]);
                });
                return;
            }

            NSArray *items = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![items isKindOfClass:[NSArray class]]) {
                JamDispatchMain(^{
                    completion(NO, [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:107 userInfo:@{
                        NSLocalizedDescriptionKey: @"Invalid HF tree response for resources."
                    }]);
                });
                return;
            }

            NSMutableArray *filesToDownload = [NSMutableArray array];
            for (NSDictionary *item in items) {
                if ([item[@"type"] isEqualToString:@"file"]) {
                    [filesToDownload addObject:@{
                        @"path": item[@"path"] ?: @"",
                        @"size": item[@"size"] ?: @0
                    }];
                }
            }

            if (filesToDownload.count == 0) {
                JamDispatchMain(^{
                    completion(NO, [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:108 userInfo:@{
                        NSLocalizedDescriptionKey: @"No base shared resources found on HuggingFace."
                    }]);
                });
                return;
            }

            dispatch_async(JamDownloadQueue(), ^{
                [self downloadFiles:filesToDownload
                        targetIndex:0
                          modelName:@""
                       isSharedInit:YES
                           progress:progressBlock
                         completion:completion];
            });
        }] resume];
    });
}

+ (void)fetchFileListForTreePath:(NSString *)treePath
                            code:(NSInteger)errorCode
                           label:(NSString *)label
                      completion:(void (^)(NSArray<NSDictionary *> *files, NSError *error))completion {
    NSURL *url = [self hfTreeURLForPath:treePath];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (httpResp.statusCode != 200) {
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            completion(nil, [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:errorCode userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HF %@ tree HTTP %ld: %@", label, (long)httpResp.statusCode, body]
            }]);
            return;
        }

        NSArray *items = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![items isKindOfClass:[NSArray class]]) {
            completion(nil, [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:errorCode userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid HF %@ tree response.", label]
            }]);
            return;
        }

        NSMutableArray *filesToDownload = [NSMutableArray array];
        for (NSDictionary *item in items) {
            if ([item[@"type"] isEqualToString:@"file"]) {
                [filesToDownload addObject:@{
                    @"path": item[@"path"] ?: @"",
                    @"size": item[@"size"] ?: @0
                }];
            }
        }

        if (filesToDownload.count == 0) {
            completion(nil, [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:errorCode + 1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No %@ files found on HuggingFace.", label]
            }]);
            return;
        }

        completion(filesToDownload, nil);
    }] resume];
}

+ (BOOL)fileAtPath:(NSString *)path matchesExpectedSize:(NSNumber *)expectedSize {
    if (expectedSize.longLongValue <= 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return NO;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    return attrs && [attrs fileSize] == (unsigned long long)expectedSize.longLongValue;
}

+ (BOOL)installDownloadedFileFromURL:(NSURL *)tempURL toPath:(NSString *)destPath error:(NSError **)outError {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parentDir = [destPath stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:outError]) {
        return NO;
    }

    NSURL *destURL = [NSURL fileURLWithPath:destPath];
    if ([fm fileExistsAtPath:destPath]) {
        [fm removeItemAtURL:destURL error:nil];
    }

    if ([fm moveItemAtURL:tempURL toURL:destURL error:outError]) {
        return YES;
    }

    NSError *copyError = nil;
    if ([fm copyItemAtURL:tempURL toURL:destURL error:&copyError]) {
        [fm removeItemAtURL:tempURL error:nil];
        return YES;
    }

    if (outError && !*outError) {
        *outError = copyError;
    }
    return NO;
}

+ (void)downloadFiles:(NSArray<NSDictionary *> *)files
          targetIndex:(NSUInteger)index
            modelName:(NSString *)modelName
         isSharedInit:(BOOL)isSharedInit
             progress:(void (^)(double progress, NSString *status))progressBlock
           completion:(void (^)(BOOL success, NSError *error))completion {
    [self downloadFiles:files
            targetIndex:index
              modelName:modelName
           isSharedInit:isSharedInit
             retryCount:0
               progress:progressBlock
             completion:completion];
}

+ (void)downloadFiles:(NSArray<NSDictionary *> *)files
          targetIndex:(NSUInteger)index
            modelName:(NSString *)modelName
         isSharedInit:(BOOL)isSharedInit
           retryCount:(NSUInteger)retryCount
             progress:(void (^)(double progress, NSString *status))progressBlock
           completion:(void (^)(BOOL success, NSError *error))completion {

    if (index >= files.count) {
        JamDispatchMain(^{
            progressBlock(1.0, @"Finished!");
            completion(YES, nil);
        });
        return;
    }

    NSDictionary *fileInfo = files[index];
    NSString *repoPath = fileInfo[@"path"];
    NSNumber *fileSize = fileInfo[@"size"];
    NSString *fileName = [repoPath lastPathComponent];

    NSString *homePath = [self magentaHomePath];
    NSString *localDestPath = [homePath stringByAppendingPathComponent:repoPath];

    if ([self fileAtPath:localDestPath matchesExpectedSize:fileSize]) {
        NSLog(@"JamModelDownloader: skip existing %@ (%@ bytes)", fileName, fileSize);
        [self downloadFiles:files
                targetIndex:index + 1
                  modelName:modelName
               isSharedInit:isSharedInit
                 retryCount:0
                   progress:progressBlock
                 completion:completion];
        return;
    }

    NSString *shortFileName = [fileName jam_stringByAbbreviatingWithMaxLength:25];
    NSString *friendlySize = [NSByteCountFormatter stringFromByteCount:fileSize.longLongValue countStyle:NSByteCountFormatterCountStyleFile];
    NSString *label = nil;
    if (isSharedInit) {
        label = [NSString stringWithFormat:@"Installing Resources: (%lu/%lu) %@ (%@)", index + 1, (unsigned long)files.count, shortFileName, friendlySize];
    } else {
        label = [NSString stringWithFormat:@"Installing Model: (%lu/%lu) %@ (%@)", index + 1, (unsigned long)files.count, shortFileName, friendlySize];
    }

    double fraction = files.count > 0 ? (double)index / (double)files.count : 0.0;
    JamDispatchMain(^{
        progressBlock(fraction, label);
    });

    NSURL *downloadURL = [self hfResolveURLForPath:repoPath];
    NSURLRequest *request = [NSURLRequest requestWithURL:downloadURL];

    NSURLSessionDownloadTask *task = [JamDownloadSession() downloadTaskWithRequest:request
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *netError) {
            dispatch_async(JamDownloadQueue(), ^{
                if (netError) {
                    if (retryCount + 1 < kMaxDownloadRetries) {
                        NSLog(@"JamModelDownloader: retry %lu/%lu for %@ (%@)",
                              (unsigned long)(retryCount + 1), (unsigned long)kMaxDownloadRetries, fileName, netError.localizedDescription);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((retryCount + 1) * NSEC_PER_SEC)), JamDownloadQueue(), ^{
                            [self downloadFiles:files
                                    targetIndex:index
                                      modelName:modelName
                                   isSharedInit:isSharedInit
                                     retryCount:retryCount + 1
                                       progress:progressBlock
                                     completion:completion];
                        });
                        return;
                    }
                    JamDispatchMain(^{
                        completion(NO, netError);
                    });
                    return;
                }

                if (!location) {
                    NSError *missing = [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:109 userInfo:@{
                        NSLocalizedDescriptionKey: @"Download temp file missing."
                    }];
                    JamDispatchMain(^{
                        completion(NO, missing);
                    });
                    return;
                }

                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                if (httpResp.statusCode != 200) {
                    if (retryCount + 1 < kMaxDownloadRetries) {
                        NSLog(@"JamModelDownloader: HTTP %ld retry %lu for %@",
                              (long)httpResp.statusCode, (unsigned long)(retryCount + 1), fileName);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((retryCount + 1) * NSEC_PER_SEC)), JamDownloadQueue(), ^{
                            [self downloadFiles:files
                                    targetIndex:index
                                      modelName:modelName
                                   isSharedInit:isSharedInit
                                     retryCount:retryCount + 1
                                       progress:progressBlock
                                     completion:completion];
                        });
                        return;
                    }
                    NSError *httpError = [NSError errorWithDomain:@"com.audiohacking.jam.downloader" code:109 userInfo:@{
                        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HF download HTTP %ld for %@", (long)httpResp.statusCode, fileName]
                    }];
                    JamDispatchMain(^{
                        completion(NO, httpError);
                    });
                    return;
                }

                NSError *installError = nil;
                if (![self installDownloadedFileFromURL:location toPath:localDestPath error:&installError]) {
                    NSLog(@"JamModelDownloader: install failed %@ -> %@: %@", location.path, localDestPath, installError);
                    if (retryCount + 1 < kMaxDownloadRetries) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((retryCount + 1) * NSEC_PER_SEC)), JamDownloadQueue(), ^{
                            [self downloadFiles:files
                                    targetIndex:index
                                      modelName:modelName
                                   isSharedInit:isSharedInit
                                     retryCount:retryCount + 1
                                       progress:progressBlock
                                     completion:completion];
                        });
                        return;
                    }
                    JamDispatchMain(^{
                        completion(NO, installError);
                    });
                    return;
                }

                NSLog(@"JamModelDownloader: installed %@", localDestPath);
                [self downloadFiles:files
                        targetIndex:index + 1
                          modelName:modelName
                       isSharedInit:isSharedInit
                         retryCount:0
                           progress:progressBlock
                         completion:completion];
            });
        }];
    [task resume];
}

@end

@implementation NSString (MRT2Abbreviation)
- (NSString *)jam_stringByAbbreviatingWithMaxLength:(NSUInteger)maxLength {
    if (self.length <= maxLength) return self;
    NSUInteger half = maxLength / 2 - 2;
    return [NSString stringWithFormat:@"%@...%@", [self substringToIndex:half], [self substringFromIndex:self.length - half]];
}
@end
