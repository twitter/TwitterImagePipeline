//
//  TIPImageStoreOperation.m
//  TwitterImagePipeline
//
//  Created on 1/13/16.
//  Copyright © 2016 Twitter. All rights reserved.
//

#import "TIP_Project.h"
#import "TIPError.h"
#import "TIPGlobalConfiguration+Project.h"
#import "TIPImageDiskCache.h"
#import "TIPImageFetchRequest.h"
#import "TIPImageMemoryCache.h"
#import "TIPImagePipeline+Project.h"
#import "TIPImageRenderedCache.h"
#import "TIPImageStoreOperation.h"
#import "UIImage+TIPAdditions.h"

// Static asserts to ensure the Fetch/Store options are 1:1 matching

TIPStaticAssert(TIPImageFetchNoOptions == TIPImageStoreNoOptions, NoOptionsMissmatch);
TIPStaticAssert(TIPImageFetchDoNotResetExpiryOnAccess == TIPImageStoreDoNotResetExpiryOnAccess, DoNotResetExpiryOnAccessMissmatch);
TIPStaticAssert(TIPImageFetchTreatAsPlaceholder == TIPImageStoreTreatAsPlaceholder, TreatAsPlaceholderMissmatch);

NS_ASSUME_NONNULL_BEGIN

@interface TIPImageStoreOperation ()
@property (nonatomic, readonly) id<TIPImageStoreRequest> request;
@property (nonatomic, readonly) TIPImagePipeline *pipeline;
@property (nonatomic, copy, readonly, nullable) TIPImagePipelineStoreCompletionBlock storeCompletionBlock;
@end

@interface TIPImageStoreOperation (Private)
- (nullable NSData *)_tip_imageData;
- (nullable NSString *)_tip_imageFilePath;
- (nullable TIPImageContainer *)_tip_imageContainer;
- (TIPCompleteImageEntryContext *)_tip_entryContext:(NSURL *)imageURL imageContainer:(nullable TIPImageContainer *)imageContainer;
- (void)_tip_asyncStoreMemoryEntry:(TIPImageCacheEntry *)memoryEntry completion:(void(^)(BOOL))complete;
@end

NS_ASSUME_NONNULL_END

@implementation TIPDisabledExternalMutabilityOperation

- (void)_tip_addDependency:(NSOperation *)op
{
    [super addDependency:op];
}

- (void)makeDependencyOfTargetOperation:(NSOperation *)op
{
    [op addDependency:self];
}

- (void)cancel
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)addDependency:(NSOperation *)op
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)removeDependency:(NSOperation *)op
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)setQueuePriority:(NSOperationQueuePriority)queuePriority
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)setCompletionBlock:(void (^)(void))completionBlock
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)setThreadPriority:(double)threadPriority
{
    [super doesNotRecognizeSelector:_cmd];
}

- (void)setQualityOfService:(NSQualityOfService)qualityOfService
{
    [super doesNotRecognizeSelector:_cmd];
}

@end

@implementation TIPImageStoreOperation
{
    TIPImageStoreHydrationOperation *_hydrationOperation;
}

- (instancetype)initWithRequest:(id<TIPImageStoreRequest>)request pipeline:(TIPImagePipeline *)pipeline completion:(TIPImagePipelineStoreCompletionBlock)completion
{
    if (self = [super init]) {
        _request = request;
        _pipeline = pipeline;
        _storeCompletionBlock = [completion copy];
    }
    return self;
}

- (void)setHydrationDependency:(TIPImageStoreHydrationOperation *)dependency
{
    if (_hydrationOperation) {
        return;
    }

    _hydrationOperation = dependency;
    [super _tip_addDependency:dependency];
}

- (void)main
{
    void (^completion)(TIPImageCacheEntry *, NSError *) = ^(TIPImageCacheEntry *completedEntry, NSError *completedError) {
        TIPAssert((completedEntry != nil) ^ (completedError != nil));

        if (completedEntry) {
            [self.pipeline postCompletedEntry:completedEntry manual:YES];
        }

        if (self.storeCompletionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.storeCompletionBlock(completedEntry != nil, completedError);
            });
        }
    };

    // Check hydration
    if (_hydrationOperation) {
        NSError *hydrationError = _hydrationOperation.error;
        if (hydrationError) {
            completion(nil, hydrationError);
            return;
        } else if (_hydrationOperation.hydratedRequest) {
            _request = _hydrationOperation.hydratedRequest;
        }
    }

    // Confirm Caches
    if (!_pipeline.diskCache && !_pipeline.memoryCache) {
        completion(nil, [NSError errorWithDomain:TIPImageStoreErrorDomain code:TIPImageStoreErrorCodeNoCacheForStoring userInfo:nil]);
        return;
    }

    // Pull out image info
    NSData *imageData = [self _tip_imageData];
    NSString *imageFilePath = [self _tip_imageFilePath];
    TIPImageContainer *imageContainer = [self _tip_imageContainer];

    // Validate image info
    TIPAssertMessage(imageContainer != nil || imageData != nil || imageFilePath != nil, @"%@ didn't have any image info", NSStringFromClass([_request class]));
    if (!imageContainer && !imageData && !imageFilePath) {
        completion(nil, [NSError errorWithDomain:TIPImageStoreErrorDomain code:TIPImageStoreErrorCodeImageNotProvided userInfo:nil]);
        return;
    }

    // Pull out and validate URL
    NSURL *imageURL = _request.imageURL;
    TIPAssert(imageURL != nil);
    if (!imageURL) {
        completion(nil, [NSError errorWithDomain:TIPImageStoreErrorDomain code:TIPImageStoreErrorCodeImageURLNotProvided userInfo:nil]);
        return;
    }

    // Create context
    TIPCompleteImageEntryContext *context = [self _tip_entryContext:imageURL imageContainer:imageContainer];

    // Create Memory Entry
    TIPImageCacheEntry *memoryEntry = nil;
    if (_pipeline.memoryCache) {
        memoryEntry = [[TIPImageCacheEntry alloc] init];
        if (imageContainer) {
            memoryEntry.completeImage = imageContainer;
            TIPAssert(memoryEntry.completeImage);
        } else if (imageData) {
            memoryEntry.completeImageData = imageData;
        } else {
            TIPAssert(imageFilePath);
            memoryEntry.completeImageFilePath = imageFilePath;
        }
    }

    // Create Disk Entry
    TIPImageCacheEntry *diskEntry = nil;
    if (_pipeline.diskCache) {
        diskEntry = [[TIPImageCacheEntry alloc] init];
        if (imageFilePath && ([[NSFileManager defaultManager] fileExistsAtPath:imageFilePath] || (!imageData && !imageContainer))) {
            diskEntry.completeImageFilePath = imageFilePath;
        } else if (imageData) {
            diskEntry.completeImageData = imageData;
        } else {
            TIPAssert(imageContainer);
            diskEntry.completeImage = imageContainer;
            TIPAssert(diskEntry.completeImage);
        }
    }

    // Finish hydrating entries
    NSString *identifier = [_request respondsToSelector:@selector(imageIdentifier)] ? [[_request imageIdentifier] copy] : nil;
    if (!identifier) {
        identifier = [imageURL absoluteString];
    }
    if (memoryEntry) {
        memoryEntry.completeImageContext = [context copy];
        memoryEntry.identifier = identifier;
    }
    if (diskEntry) {
        diskEntry.completeImageContext = [context copy];
        diskEntry.identifier = identifier;
    }

    // Update caches
    [_pipeline.renderedCache clearImagesWithIdentifier:identifier];

    if (diskEntry) {
        [_pipeline.diskCache updateImageEntry:diskEntry forciblyReplaceExisting:!context.treatAsPlaceholder];
    }

    if (memoryEntry) {
        if (memoryEntry.completeImage != nil) {
            [_pipeline.memoryCache updateImageEntry:memoryEntry forciblyReplaceExisting:!context.treatAsPlaceholder];
        } else {
            if (diskEntry) {
                // clear memory cache first, in case actual store fails we'll want to fall back to the disk cache for loading
                [_pipeline.memoryCache clearImageWithIdentifier:identifier];
            }
            [self _tip_asyncStoreMemoryEntry:memoryEntry completion:^(BOOL success) {
                if (success) {
                    completion(memoryEntry, nil);
                } else if (diskEntry) {
                    completion(diskEntry, nil);
                } else {
                    completion(nil, [NSError errorWithDomain:TIPImageStoreErrorDomain code:TIPImageStoreErrorCodeStorageFailed userInfo:nil]);
                }
            }];
            return; // async completion
        }
    }

    completion(memoryEntry ?: diskEntry, nil);
}

@end

@implementation TIPImageStoreOperation (Private)

- (NSData *)_tip_imageData
{
    return [_request respondsToSelector:@selector(imageData)] ? _request.imageData : nil;
}

- (NSString *)_tip_imageFilePath
{
    return [_request respondsToSelector:@selector(imageFilePath)] ? _request.imageFilePath : nil;
}

- (TIPImageContainer *)_tip_imageContainer
{
    TIPImageContainer *imageContainer = nil;
    if ([_request respondsToSelector:@selector(image)]) {
        UIImage *image = _request.image;
        if (image.CIImage) {
            image = [image tip_CGImageBackedImageAndReturnError:NULL];
        }

        if (image) {
            if (image.images.count > 0) {
                NSUInteger loopCount = [_request respondsToSelector:@selector(animationLoopCount)] ? _request.animationLoopCount : 0;
                NSArray<NSNumber *> *durations = [_request respondsToSelector:@selector(animationFrameDurations)] ? _request.animationFrameDurations : nil;
                imageContainer = [[TIPImageContainer alloc] initWithAnimatedImage:image loopCount:loopCount frameDurations:durations];
            } else {
                imageContainer = [[TIPImageContainer alloc] initWithImage:image];
            }
            TIPAssert(imageContainer != nil);
        }
    }
    return imageContainer;
}

- (TIPCompleteImageEntryContext *)_tip_entryContext:(NSURL *)imageURL imageContainer:(TIPImageContainer *)imageContainer
{
    TIPCompleteImageEntryContext *context = [[TIPCompleteImageEntryContext alloc] init];
    const TIPImageStoreOptions options = [_request respondsToSelector:@selector(options)] ? [_request options] : TIPImageStoreNoOptions;
    context.updateExpiryOnAccess = TIP_BITMASK_EXCLUDES_FLAGS(options, TIPImageStoreDoNotResetExpiryOnAccess);
    context.treatAsPlaceholder = TIP_BITMASK_HAS_SUBSET_FLAGS(options, TIPImageStoreTreatAsPlaceholder);
    context.TTL = [_request respondsToSelector:@selector(timeToLive)] ? [_request timeToLive] : -1.0;
    if (context.TTL <= 0.0) {
        context.TTL = TIPTimeToLiveDefault;
    }
    context.URL = imageURL;
    if (imageContainer) {
        context.dimensions = imageContainer.dimensions;
    } else if ([_request respondsToSelector:@selector(imageDimensions)]) {
        context.dimensions = _request.imageDimensions;
    }
    if ([_request respondsToSelector:@selector(imageType)]) {
        context.imageType = [_request imageType];
    }
    if (imageContainer) {
        context.animated = imageContainer.isAnimated;
    } else {
        if ([context.imageType isEqualToString:TIPImageTypeGIF]) {
            context.animated = YES;
        }
    }
    return context;
}

- (void)_tip_asyncStoreMemoryEntry:(TIPImageCacheEntry *)memoryEntry completion:(void(^)(BOOL))complete
{
    TIPImageMemoryCache *memoryCache = self.pipeline.memoryCache;
    NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        TIPImageContainer *container = nil;
        if (memoryEntry.completeImageData) {
            container = [TIPImageContainer imageContainerWithData:memoryEntry.completeImageData codecCatalogue:nil];
        } else if (memoryEntry.completeImageFilePath) {
            container = [TIPImageContainer imageContainerWithFilePath:memoryEntry.completeImageFilePath codecCatalogue:nil];
        } else {
            container = memoryEntry.completeImage;
        }

        memoryEntry.completeImageFilePath = nil;
        memoryEntry.completeImageData = nil;

        if (container) {
            [container decode];
            memoryEntry.completeImageContext.dimensions = container.dimensions;
            memoryEntry.completeImage = container;

            [memoryCache updateImageEntry:memoryEntry forciblyReplaceExisting:YES];
        }

        complete(container != nil);
    }];
    [[TIPGlobalConfiguration sharedInstance] enqueueImagePipelineOperation:op];
}

@end

@implementation TIPImageStoreHydrationOperation
{
    id<TIPImageStoreRequest> _request;
    TIPImagePipeline *_pipeline;
    id<TIPImageStoreRequestHydrater> _hydrater;

    struct {
        BOOL isExecuting:1;
        BOOL isFinished:1;
        BOOL didExitStart:1;
    } _flags;
}

- (instancetype)initWithRequest:(id<TIPImageStoreRequest>)request pipeline:(TIPImagePipeline *)pipeline hydrater:(id<TIPImageStoreRequestHydrater>)hydrater
{
    TIPAssert(request);
    TIPAssert(pipeline);
    TIPAssert(hydrater);

    if (!request || !pipeline || !hydrater) {
        return nil;
    }

    if (self = [super init]) {
        _request = request;
        _pipeline = pipeline;
        _hydrater = hydrater;
    }
    return self;
}

- (BOOL)isAsynchronous
{
    return YES;
}

- (BOOL)isConcurrent
{
    return YES;
}

- (BOOL)isExecuting
{
    return _flags.isExecuting;
}

- (BOOL)isFinished
{
    return _flags.isFinished;
}

- (void)start
{
    tip_defer(^{
        self->_flags.didExitStart = 1;
    });

    [self willChangeValueForKey:@"isExecuting"];
    _flags.isExecuting = 1;
    [self didChangeValueForKey:@"isExecuting"];

    [_hydrater tip_hydrateImageStoreRequest:_request imagePipeline:_pipeline completion:^(id<TIPImageStoreRequest> newRequest, NSError *error) {
        [self _tip_complete:newRequest error:error];
    }];
}

- (void)_tip_complete:(id<TIPImageStoreRequest>)request error:(NSError *)error
{
    if (!self->_flags.didExitStart) {
        // Completed synchronously, don't want to mess up "isAsynchronous" behavior
        [[TIPGlobalConfiguration sharedInstance] enqueueImagePipelineOperation:[NSBlockOperation blockOperationWithBlock:^{
            [self _tip_complete:request error:error];
        }]];
        return;
    }

    if (error) {
        _error = error;
    } else {
        _hydratedRequest = request;
    }

    [self willChangeValueForKey:@"isFinished"];
    [self willChangeValueForKey:@"isExecuting"];
    _flags.isExecuting = 0;
    _flags.isFinished = 1;
    [self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

@end
