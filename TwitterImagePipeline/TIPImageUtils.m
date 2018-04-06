//
//  TIPImageUtils.m
//  TwitterImagePipeline
//
//  Created on 2/18/15.
//  Copyright (c) 2015 Twitter, Inc. All rights reserved.
//

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>

#import "TIP_Project.h"
#import "TIPError.h"
#import "TIPGlobalConfiguration+Project.h"
#import "TIPImageUtils.h"
#import "TIPTiming.h"
#import "UIImage+TIPAdditions.h"

NS_ASSUME_NONNULL_BEGIN

static CGSize TIPSizeAlignToPixelEx(CGSize size, CGFloat scale);

#pragma mark - Functions

BOOL TIPSizeMatchesTargetSizing(const CGSize size, CGSize targetSize, const UIViewContentMode targetContentMode, const CGFloat scale)
{
    if (!TIPSizeGreaterThanZero(targetSize)) {
        return NO;
    }

    switch (targetContentMode) {
        case UIViewContentModeScaleAspectFit:
        {
            targetSize = TIPScaleToFitKeepingAspectRatio(size, targetSize, scale);
            break;
        }
        case UIViewContentModeScaleAspectFill:
        {
            targetSize = TIPScaleToFillKeepingAspectRatio(size, targetSize, scale);
            break;
        }
        case UIViewContentModeScaleToFill:
        default:
        {
            break;
        }
    }

    // Keep the target dimensions pixel aligned by rounding up partial pixels
    targetSize = TIPSizeAlignToPixelEx(targetSize, scale);

    return CGSizeEqualToSize(targetSize, size);
}

CGSize TIPDimensionsScaledToTargetSizing(CGSize dimensionsToScale, CGSize targetDimensionsOrZero, UIViewContentMode targetContentMode)
{
    return TIPSizeScaledToTargetSizing(dimensionsToScale, targetDimensionsOrZero, targetContentMode, 1);
}

CGSize TIPSizeScaledToTargetSizing(CGSize sizeToScale, CGSize targetSizeOrZero, UIViewContentMode targetContentMode, CGFloat scale)
{
    if (!TIPSizeGreaterThanZero(targetSizeOrZero)) {
        // no target dimensions, use the source dimensions
        targetSizeOrZero = sizeToScale;
    } else {
        switch (targetContentMode) {
            case UIViewContentModeScaleToFill:
                // leave target size
                break;
            case UIViewContentModeScaleAspectFit:
                targetSizeOrZero = TIPScaleToFitKeepingAspectRatio(sizeToScale, targetSizeOrZero, scale);
                break;
            case UIViewContentModeScaleAspectFill:
                targetSizeOrZero = TIPScaleToFillKeepingAspectRatio(sizeToScale, targetSizeOrZero, scale);
                break;
            default:
                targetSizeOrZero = sizeToScale;
                break;
        }
    }

    return targetSizeOrZero;
}

CGImagePropertyOrientation TIPCGImageOrientationFromUIImageOrientation(UIImageOrientation orientation)
{
    switch (orientation) {
        case UIImageOrientationUp:
            return kCGImagePropertyOrientationUp;
        case UIImageOrientationUpMirrored:
            return kCGImagePropertyOrientationUpMirrored;
        case UIImageOrientationDown:
            return kCGImagePropertyOrientationDown;
        case UIImageOrientationDownMirrored:
            return kCGImagePropertyOrientationDownMirrored;
        case UIImageOrientationLeftMirrored:
            return kCGImagePropertyOrientationLeftMirrored;
        case UIImageOrientationRight:
            return kCGImagePropertyOrientationRight;
        case UIImageOrientationRightMirrored:
            return kCGImagePropertyOrientationRightMirrored;
        case UIImageOrientationLeft:
            return kCGImagePropertyOrientationLeft;
    }

    return kCGImagePropertyOrientationUp;
}

UIImageOrientation TIPUIImageOrientationFromCGImageOrientation(CGImagePropertyOrientation cgOrientation)
{
    switch (cgOrientation) {
        case kCGImagePropertyOrientationUp:
            return UIImageOrientationUp;
        case kCGImagePropertyOrientationUpMirrored:
            return UIImageOrientationUpMirrored;
        case kCGImagePropertyOrientationDown:
            return UIImageOrientationDown;
        case kCGImagePropertyOrientationDownMirrored:
            return UIImageOrientationDownMirrored;
        case kCGImagePropertyOrientationLeftMirrored:
            return UIImageOrientationLeftMirrored;
        case kCGImagePropertyOrientationRight:
            return UIImageOrientationRight;
        case kCGImagePropertyOrientationRightMirrored:
            return UIImageOrientationRightMirrored;
        case kCGImagePropertyOrientationLeft:
            return UIImageOrientationLeft;
    }

    return UIImageOrientationUp;
}

NSUInteger TIPEstimateMemorySizeOfImageWithSettings(CGSize size, CGFloat scale, NSUInteger componentsPerPixel, NSUInteger frameCount)
{
    const NSUInteger pixels = (NSUInteger)(size.width * scale * size.height * scale);
    return pixels * componentsPerPixel * MAX((NSUInteger)1, frameCount);
}

static int _TIPImageByteIndexOfAlphaComponent(CGBitmapInfo bitmapInfo, size_t numberOfComponents, BOOL isLeadingByteAlpha);
static int _TIPImageByteIndexOfAlphaComponent(CGBitmapInfo bitmapInfo, size_t numberOfComponents, BOOL isLeadingByteAlpha)
{
    int alphaByteIndex = -1;
    const uint32_t byteOrderInfo = bitmapInfo & kCGBitmapByteOrderMask;
    switch (byteOrderInfo) {
        case kCGBitmapByteOrder16Little:

            if (/* DISABLES CODE */ (YES)) {
                break; // bail: this code path has not been tested
            }

            // A R G B -> R A B G
            // R G B A -> G R A B
            if (isLeadingByteAlpha) {
                alphaByteIndex = (numberOfComponents % 2);
            } else {
                alphaByteIndex = (int)(((numberOfComponents / 2) * 2) + ((2 - 1) - (numberOfComponents % 2)));
            }
            break;
        case kCGBitmapByteOrder32Little:
            if (isLeadingByteAlpha) {
                alphaByteIndex = (numberOfComponents % 4);
            } else {
                alphaByteIndex = (int)(((numberOfComponents / 4) * 4) + ((4 - 1) - (numberOfComponents % 4)));
            }
            break;
        case kCGBitmapByteOrder16Big:
        case kCGBitmapByteOrder32Big:
        default:
            alphaByteIndex = isLeadingByteAlpha ? 0 : (int)numberOfComponents;
            break;
    }

    return alphaByteIndex;
}

BOOL TIPCGImageHasAlpha(CGImageRef imageRef, BOOL inspectPixels)
{
    BOOL isLeadingByteAlpha = YES;
    const CGBitmapInfo bmpInfo = CGImageGetBitmapInfo(imageRef);
    const CGImageAlphaInfo alphaInfo = bmpInfo & kCGBitmapAlphaInfoMask;
    switch (alphaInfo) {
        case kCGImageAlphaNone:
            if (CGImageIsMask(imageRef)) {
                if (inspectPixels) {
                    break;
                }
                return YES; // alpha mask
            }
        case kCGImageAlphaNoneSkipLast:
        case kCGImageAlphaNoneSkipFirst:
            return NO;
        case kCGImageAlphaPremultipliedLast:
        case kCGImageAlphaLast:
            isLeadingByteAlpha = NO;
        case kCGImageAlphaPremultipliedFirst:
        case kCGImageAlphaFirst:
            if (inspectPixels) {
                break;
            }
        case kCGImageAlphaOnly:
            return YES;
    }

    if (TIP_BITMASK_HAS_SUBSET_FLAGS(bmpInfo, kCGBitmapFloatComponents)) {
        return YES; // bail, only tested with 8-bit components
    }

    const size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
    if (bitsPerComponent != 8) {
        return YES; // bail
    }

    CGColorSpaceRef const colorSpace = CGImageGetColorSpace(imageRef);
    const size_t numberOfComponents = colorSpace ? CGColorSpaceGetNumberOfComponents(colorSpace) : 0;
    const CGSize size = CGSizeMake(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));
    const size_t expectedBytesPerRow = (numberOfComponents + 1) * (size_t)size.width * (bitsPerComponent / 8);
    const size_t byteSluffPerRow = CGImageGetBytesPerRow(imageRef) - expectedBytesPerRow;
    if (byteSluffPerRow > CGImageGetBytesPerRow(imageRef)) {
        return YES; // bail - underflow
    }

    const int alphaByteIndex = _TIPImageByteIndexOfAlphaComponent(bmpInfo, numberOfComponents, isLeadingByteAlpha);
    if (alphaByteIndex < 0) {
        return YES; // bail
    }

    CGDataProviderRef const dataProvider = CGImageGetDataProvider(imageRef);
    CFRetain(dataProvider);
    TIPDeferRelease(dataProvider);
    CFDataRef const data = CGDataProviderCopyData(dataProvider);
    TIPDeferRelease(data);

    const UInt8 *byteComponent = CFDataGetBytePtr(data);
    for (size_t iRow = 0; iRow < (size_t)size.height; iRow++) {
        const UInt8 * const endRowByte = byteComponent + expectedBytesPerRow;
        while (byteComponent < endRowByte) {
            if (0xFF != byteComponent[alphaByteIndex]) {
                return YES;
            }
            byteComponent += numberOfComponents + 1;
        }
        byteComponent += byteSluffPerRow;
    }

    return NO;
}

BOOL TIPCIImageHasAlpha(CIImage *image, BOOL inspectPixels)
{
    // TODO: implement this function
    return YES;
}

BOOL TIPMainScreenSupportsWideColorGamut()
{
    static BOOL sScreenIsWideGamut = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sScreenIsWideGamut = TIPScreenSupportsWideColorGamut([UIScreen mainScreen]);
    });

    return sScreenIsWideGamut;
}

BOOL TIPScreenSupportsWideColorGamut(UIScreen *screen)
{
    if (![screen respondsToSelector:@selector(traitCollection)]) {
        return NO;
    }

    UITraitCollection *traits = [screen traitCollection];
    if (![traits respondsToSelector:@selector(displayGamut)]) {
        return NO;
    }

    switch ([traits displayGamut]) {
        case UIDisplayGamutP3:
            return YES;
        default:
            break;
    }

    return NO;
}

void TIPExecuteCGContextBlock(dispatch_block_t block)
{
    /*

     There are not-infrequent crashes when there are multiple accesses to CGContext based functions
     at the same time from different threads.   We cannot determine exactly what is happening, but
     have a few theories:

         1. it appears that we can crash within a CGSImageDataLock and suspect another thread has
            simultaneous access to the same image data without holding the lock.  We also see
            cases where the context based image generations are yielding `nil` images, which could
            be the same issue but with the fortune of not crashing.

         2. we also see an elevated level of FOOMs (Foreground Out Of Memory crashes) which could
            indicate we do not have a race condition with code/memory access, but concurrent access
            to the CGContext increases memory pressure beyond a device's limits.  Additionally,
            we do see that the addition of this serialization does not eliminate the issue, just
            dramatically curb it - which seems to align with memory constraints that get
            exacerbated by have multiple accesses to CGContext that lead to expensive uses of
            memory.

     To ameliorate these race conditions (either of code/memory access or sheer memory consumed),
     we will guard CGContext based operations on a serial queue (when opted into with
     `serializeCGContextAccess`).

     */

    static dispatch_queue_t sContextQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sContextQueue = dispatch_queue_create("tip.CGContext.queue", DISPATCH_QUEUE_SERIAL);
    });

    @autoreleasepool {
        TIPGlobalConfiguration *config = [TIPGlobalConfiguration sharedInstance];
        const uint64_t startTime = mach_absolute_time();
        const BOOL serialize = config.serializeCGContextAccess;

        if (serialize) {
            tip_dispatch_sync_autoreleasing(sContextQueue, block);
        } else {
            block();
        }

        const NSTimeInterval elapsedTime = TIPComputeDuration(startTime, mach_absolute_time());
        [config accessedCGContext:serialize duration:elapsedTime];
    }
}

#pragma mark - Statics

static CGSize TIPSizeAlignToPixelEx(CGSize size, CGFloat scale)
{
    return CGSizeMake(__tg_ceil(size.width * scale) / scale, __tg_ceil(size.height * scale) / scale);
}

NS_ASSUME_NONNULL_END
