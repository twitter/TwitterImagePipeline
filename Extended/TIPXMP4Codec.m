//
//  TIPXMP4Codec.m
//  TwitterImagePipeline
//
//  Created by Nolan O'Brien on 3/16/17.
//  Copyright © 2017 Twitter. All rights reserved.
//

#import <TwitterImagePipeline/TwitterImagePipeline.h>
#import "TIPXMP4Codec.h"

@import AVFoundation;

#pragma mark - Defer support

typedef void(^tipx_defer_block_t)(void);
NS_INLINE void tipx_deferFunc(__strong tipx_defer_block_t __nonnull * __nonnull blockRef)
{
    tipx_defer_block_t actualBlock = *blockRef;
    actualBlock();
}

#define _tipx_macro_concat(a, b) a##b
#define tipx_macro_concat(a, b) _tipx_macro_concat(a, b)

#pragma twitter startignorestylecheck

#define tipx_defer(deferBlock) \
__strong tipx_defer_block_t tipx_macro_concat(tipx_stack_defer_block_, __LINE__) __attribute__((cleanup(tipx_deferFunc), unused)) = deferBlock

#define TIPXDeferRelease(ref) tipx_defer(^{ if (ref) { CFRelease(ref); } })

#pragma twitter stopignorestylecheck

#pragma mark - Constants

NSString * const TIPXImageTypeMP4 = @"public.mp4";

typedef struct _TIPXMP4Signature {
    const size_t offset;
    const size_t length;
    const char *signature;
} TIPXMP4Signature;

/* ftypMSNV.).FMSNVmp42 */
static const char kComplexSignature1[] = { 0x66, 0x74, 0x79, 0x70, 0x4D, 0x53, 0x4E, 0x56, 0x01, 0x29, 0x00, 0x46, 0x4D, 0x53, 0x4E, 0x56, 0x6D, 0x70, 0x34, 0x32 };

static const TIPXMP4Signature kSignatures[] = {
    { .offset = 4, .length = sizeof(kComplexSignature1), .signature = kComplexSignature1 },
    { .offset = 4, .length = 8, .signature = "ftypisom" },
    { .offset = 4, .length = 8, .signature = "ftyp3gp5" },
    { .offset = 4, .length = 8, .signature = "ftypMSNV" },
    { .offset = 4, .length = 8, .signature = "ftypmp42" },
    { .offset = 4, .length = 6, .signature = "ftypqt" },

};
static const size_t kSignatureDataRequiredToCheck = sizeof(kComplexSignature1) + 4;

#pragma mark - Declarations

static CGImageRef TIPX_CGImageCreateFromCMSampleBuffer(CMSampleBufferRef sample) CF_RETURNS_RETAINED;

@interface TIPXMP4DecoderConfigInternal : NSObject <TIPXMP4DecoderConfig>
- (instancetype)initWithMaxDecodableFramesCount:(NSUInteger)max;
@end

@interface TIPXMP4DecoderContext : NSObject <TIPImageDecoderContext>

- (instancetype)initWithBuffer:(nonnull NSMutableData *)buffer config:(nullable id<TIPXMP4DecoderConfig>)config;

- (TIPImageDecoderAppendResult)appendData:(nonnull NSData *)data;
- (nullable TIPImageContainer *)renderImageWithMode:(TIPImageDecoderRenderMode)mode;
- (TIPImageDecoderAppendResult)finalizeDecoding;

@end

@interface TIPXMP4Decoder : NSObject <TIPImageDecoder>
@property (nonatomic, readonly, nullable) id<TIPXMP4DecoderConfig> defaultDecoderConfig;
- (instancetype)initWithDefaultDecoderConfig:(nullable id<TIPXMP4DecoderConfig>)decoderConfig NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#pragma mark - Codec

@implementation TIPXMP4Codec

- (instancetype)init
{
    return [self initWithDefaultDecoderConfig:nil];
}

- (instancetype)initWithDefaultDecoderConfig:(id<TIPXMP4DecoderConfig>)decoderConfig
{
    if (self = [super init]) {
        _tip_decoder = [[TIPXMP4Decoder alloc] initWithDefaultDecoderConfig:decoderConfig];
    }
    return self;
}

- (id<TIPXMP4DecoderConfig>)defaultDecoderConfig
{
    return [(TIPXMP4Decoder *)_tip_decoder defaultDecoderConfig];
}

+ (id<TIPXMP4DecoderConfig>)decoderConfigWithMaxDecodableFramesCount:(NSUInteger)max
{
    return [[TIPXMP4DecoderConfigInternal alloc] initWithMaxDecodableFramesCount:max];
}

@end

#pragma mark - Decoder Context

@implementation TIPXMP4DecoderContext
{
    id<TIPXMP4DecoderConfig> _config;
    NSMutableData *_data;
    FILE *_temporaryFile;
    NSString *_temporaryFilePath;
    AVAsset *_avAsset;
    AVAssetTrack *_avTrack;
    TIPImageContainer *_cachedContainer;
    UIImage *_firstFrame;
    NSUInteger _frameCount;
    NSUInteger _maxFrameCount;
    BOOL _finalized;
}

@synthesize tip_data = _data;
@synthesize tip_dimensions = _dimensions;
@synthesize tip_config = _config;

- (BOOL)tip_isAnimated
{
    return YES;
}

- (NSUInteger)tip_frameCount
{
    return _frameCount;
}

- (instancetype)initWithBuffer:(NSMutableData *)buffer config:(id<TIPXMP4DecoderConfig>)config
{
    if (self = [super init]) {
        _data = buffer;
        _config = config;
        _maxFrameCount = (config) ? [config maxDecodableFramesCount] : 0;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tmpDir = [fm respondsToSelector:@selector(temporaryDirectory)] ? fm.temporaryDirectory.path : NSTemporaryDirectory();
        [fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:NULL];

        _temporaryFilePath = [[tmpDir stringByAppendingPathComponent:[NSUUID UUID].UUIDString] stringByAppendingPathExtension:@"mp4"];
        _temporaryFile = fopen(_temporaryFilePath.UTF8String, "w");
        [self _tipx_writeDataToTemporaryFile:_data];
    }
    return self;
}

- (void)dealloc
{
    [self _tipx_clear];
}

- (BOOL)_tipx_writeDataToTemporaryFile:(NSData *)data
{
    if (_temporaryFile) {
        const size_t byteCount = data.length;
        if (byteCount) {
            const size_t byteOut = fwrite(data.bytes, sizeof(char), byteCount, _temporaryFile);
            if (byteCount == byteOut) {
                return YES;
            } else {
                fclose(_temporaryFile);
                _temporaryFile = NULL;
                [[NSFileManager defaultManager] removeItemAtPath:_temporaryFilePath error:NULL];
            }
        }
    }

    return NO;
}

- (TIPImageDecoderAppendResult)appendData:(NSData *)data
{
    if (!_finalized) {
        if (!_frameCount) {
            _frameCount = 1; // seed the frames
        }
        [_data appendData:data];
        [self _tipx_writeDataToTemporaryFile:data];
    }

    return TIPImageDecoderAppendResultDidProgress;
}

- (TIPImageContainer *)_tipx_firstFrameImageContainer
{
    if (!_firstFrame) {
        if (_temporaryFile || _finalized) {
            @autoreleasepool {
                AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:self->_temporaryFilePath]];
                AVAssetImageGenerator* imageGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
                CGImageRef imageRef = [imageGenerator copyCGImageAtTime:CMTimeMake(0, 1) actualTime:nil error:nil];
                if (imageRef) {
                    UIImage* image = [UIImage imageWithCGImage:imageRef scale:[UIScreen mainScreen].scale orientation:UIImageOrientationUp];
                    CFRelease(imageRef);
                    if (image) {
                        self->_firstFrame = image;
                    }
                }
            }
        }
    }

    return _firstFrame ? [[TIPImageContainer alloc] initWithImage:_firstFrame] : nil;
}

- (TIPImageContainer *)renderImageWithMode:(TIPImageDecoderRenderMode)mode
{
    if (_cachedContainer) {
        return _cachedContainer;
    }

    if (mode != TIPImageDecoderRenderModeCompleteImage && !_finalized) {
        return [self _tipx_firstFrameImageContainer];
    }

    if (!_finalized || !_avTrack || !_avAsset) {
        return nil;
    }

    const NSTimeInterval duration = CMTimeGetSeconds(self->_avAsset.duration);

    if (duration <= 0.0 || _avTrack.nominalFrameRate <= 0.0f) {
        // defensive programming: state is not viable for decoding, just treat as a 1 frame image
        self->_cachedContainer = [self _tipx_firstFrameImageContainer];
        return self->_cachedContainer;
    }

    TIPExecuteCGContextBlock(^{
        NSError *error = nil;
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:self->_avAsset error:&error];
        if (!reader) {
            [[TIPGlobalConfiguration sharedInstance].logger tip_logWithLevel:TIPLogLevelWarning
                                                                        file:@(__FILE__)
                                                                    function:@(__FUNCTION__)
                                                                        line:__LINE__
                                                                     message:error.description];
            return;
        }

        NSDictionary *outputSettings = @{
                                         (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
                                         };
        AVAssetReaderTrackOutput *output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:self->_avTrack
                                                   outputSettings:outputSettings];
        [reader addOutput:output];
        [reader startReading];

        const NSUInteger expectedFrameCount = (NSUInteger)(duration / (1. / self->_avTrack.nominalFrameRate));
        const NSUInteger maxFrameCount = self->_maxFrameCount ?: NSUIntegerMax;

        NSMutableArray<UIImage *> *images = [[NSMutableArray alloc] init];

        NSUInteger count = 0;
        NSUInteger mod = 1;
        while ((expectedFrameCount / mod) > maxFrameCount) {
            mod++;
        }

        CMSampleBufferRef sample = NULL;
        do {
            sample = [output copyNextSampleBuffer];
            TIPXDeferRelease(sample);

            if (mod > 1 && ((++count % mod) != 1)) {
                continue;
            }

            CGImageRef imageRef = TIPX_CGImageCreateFromCMSampleBuffer(sample);
            TIPXDeferRelease(imageRef);

            if (imageRef) {
                UIImage *image = [UIImage imageWithCGImage:imageRef];
                if (image) {
                    [images addObject:image];
                }
            }
        } while (sample != NULL);

        self->_frameCount = images.count;

        TIPImageContainer *container = nil;
        if (self->_frameCount > 1) {
            UIImage *animatedImage = [UIImage animatedImageWithImages:images duration:CMTimeGetSeconds(self->_avAsset.duration)];
            container = [[TIPImageContainer alloc] initWithImage:animatedImage];
        } else if (self->_frameCount == 1) {
            container = [[TIPImageContainer alloc] initWithImage:images.firstObject];
        }

        self->_cachedContainer = container;
    });

    [self _tipx_clear];
    return _cachedContainer;
}

- (TIPImageDecoderAppendResult)finalizeDecoding
{
    if (_finalized) {
        return  TIPImageDecoderAppendResultDidCompleteLoading;
    }

    @autoreleasepool {

        _finalized = YES;
        _firstFrame = nil;

        if (_temporaryFile) {
            fflush(_temporaryFile);
            fclose(_temporaryFile);
            _temporaryFile = NULL;
        } else {
            [_data writeToFile:_temporaryFilePath atomically:NO];
        }

        tipx_defer(^{
            if (!self->_avTrack) {
                self->_avAsset = nil;
            }
            if (!self->_avAsset) {
                self->_temporaryFilePath = nil;
            }
        });
        _avAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:_temporaryFilePath]];
        _avTrack = [_avAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        _frameCount = (NSUInteger)(_avTrack.nominalFrameRate * CMTimeGetSeconds(_avAsset.duration)); // guesstimate

        return TIPImageDecoderAppendResultDidCompleteLoading;
    }
}

- (void)_tipx_clear
{
    _avTrack = nil;
    _avAsset = nil;
    if (_temporaryFile) {
        fflush(_temporaryFile);
        fclose(_temporaryFile);
        _temporaryFile = NULL;
    }
    if (_temporaryFilePath) {
        [[NSFileManager defaultManager] removeItemAtPath:_temporaryFilePath error:NULL];
        _temporaryFilePath = nil;
    }
}

@end

#pragma mark - Decoder

@implementation TIPXMP4Decoder

- (instancetype)initWithDefaultDecoderConfig:(nullable id<TIPXMP4DecoderConfig>)decoderConfig
{
    if (self = [super init]) {
        _defaultDecoderConfig = decoderConfig;
    }
    return self;
}

- (TIPImageDecoderDetectionResult)tip_detectDecodableData:(NSData *)data earlyGuessImageType:(NSString *)imageType
{
    if (data.length < kSignatureDataRequiredToCheck) {
        return TIPImageDecoderDetectionResultNeedMoreData;
    }

    for (size_t i = 0; i < (sizeof(kSignatures) / sizeof(kSignatures[0])); i++) {
        const TIPXMP4Signature sig = kSignatures[i];
        if (0 == memcmp(data.bytes + sig.offset, sig.signature, sig.length)) {
            return TIPImageDecoderDetectionResultMatch;
        }
    }

    return TIPImageDecoderDetectionResultNoMatch;
}

- (TIPXMP4DecoderContext *)tip_initiateDecoding:(nullable id)config expectedDataLength:(NSUInteger)expectedDataLength buffer:(nullable NSMutableData *)buffer
{
    id<TIPXMP4DecoderConfig> decoderConfig = nil;
    if ([config respondsToSelector:@selector(maxDecodableFramesCount)]) {
        decoderConfig = config;
    }
    if (!decoderConfig) {
        decoderConfig = self.defaultDecoderConfig;
    }
    return [[TIPXMP4DecoderContext alloc] initWithBuffer:buffer ?: [[NSMutableData alloc] initWithCapacity:expectedDataLength] config:decoderConfig];
}

- (TIPImageDecoderAppendResult)tip_append:(TIPXMP4DecoderContext *)context data:(NSData *)data
{
    return [context appendData:data];
}

- (TIPImageContainer *)tip_renderImage:(TIPXMP4DecoderContext *)context mode:(TIPImageDecoderRenderMode)mode
{
    return [context renderImageWithMode:mode];
}

- (TIPImageDecoderAppendResult)tip_finalizeDecoding:(TIPXMP4DecoderContext *)context
{
    return [context finalizeDecoding];
}

@end

@implementation TIPXMP4DecoderConfigInternal

@synthesize maxDecodableFramesCount = _maxDecodableFramesCount;

- (instancetype)initWithMaxDecodableFramesCount:(NSUInteger)max
{
    if (self = [super init]) {
        _maxDecodableFramesCount = max;
    }
    return self;
}

@end

static CGImageRef TIPX_CGImageCreateFromCMSampleBuffer(CMSampleBufferRef sampleBuffer)
{
    CVImageBufferRef imageBuffer = sampleBuffer ? CMSampleBufferGetImageBuffer(sampleBuffer) : NULL;
    if (!imageBuffer) {
        return NULL;
    }

    // Lock the image buffer
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    tipx_defer(^{
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    });

    uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0); // Get information of the image
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    const size_t width = CVPixelBufferGetWidth(imageBuffer);
    const size_t height = CVPixelBufferGetHeight(imageBuffer);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    tipx_defer(^{
        CGColorSpaceRelease(colorSpace);
    });

    CGContextRef newContext = CGBitmapContextCreate(baseAddress,
                                                    width,
                                                    height,
                                                    8,
                                                    bytesPerRow,
                                                    colorSpace,
                                                    kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    tipx_defer(^{
        CGContextRelease(newContext);
    });

    return CGBitmapContextCreateImage(newContext);
}
