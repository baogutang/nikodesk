// The main display capture on ScreenCaptureKit (option nikodesk-sck-capture),
// in place of CGDisplayStream. Only complete pictures the system marks as
// changed are kept, so nothing has to compare whole frames. Each stream owns
// its state; callbacks of a stopped stream never touch a newer one. Every
// asynchronous call is bounded, and any failure leaves the caller to fall
// back to CGDisplayStream.
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <mutex>

API_AVAILABLE(macos(12.3))
@interface NSCState : NSObject<SCStreamOutput, SCStreamDelegate> {
@public
    std::mutex lock;
    CVPixelBufferRef latest;  // retained
    bool failed, cancelled;
    uint32_t width, height;
}
@property(strong) SCStream *stream;
@property(strong) dispatch_queue_t queue;
@end

@implementation NSCState
- (void)dealloc {
    if (latest) CFRelease(latest);
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    std::lock_guard<std::mutex> guard(lock);
    failed = true;
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    NSDictionary *info = attachments.firstObject;
    NSNumber *status = info[SCStreamFrameInfoStatus];
    // Idle frames repeat the last picture; blank, suspended and stopped ones
    // carry none.
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    NSArray *dirty = info[SCStreamFrameInfoDirtyRects];
    if (dirty && dirty.count == 0) return;
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
    if (!pixel) return;
    std::lock_guard<std::mutex> guard(lock);
    if (cancelled) return;
    if (CVPixelBufferGetPixelFormatType(pixel) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(pixel) != width || CVPixelBufferGetHeight(pixel) != height) {
        failed = true;
        return;
    }
    CFRetain(pixel);
    if (latest) CFRelease(latest);
    latest = pixel;
}
@end

API_AVAILABLE(macos(12.3))
static void NSCStopStream(NSCState *state) {
    {
        std::lock_guard<std::mutex> guard(state->lock);
        state->cancelled = true;
    }
    NSError *error = nil;
    [state.stream removeStreamOutput:state type:SCStreamOutputTypeScreen error:&error];
    [state.stream stopCaptureWithCompletionHandler:^(NSError *) { (void)state; }];
}

// failure: 1 unsupported or no permission, 2 listing timed out, 3 listing
// failed, 4 display not listed, 5 output not added, 6 start timed out,
// 7 start failed.
extern "C" void *NSCStart(uint32_t displayID, uint32_t width, uint32_t height, uint32_t queueDepth,
                          uint32_t timeoutMS, uint32_t *failure) {
    @autoreleasepool {
        *failure = 1;
        if (!width || !height) return nullptr;
        if (@available(macOS 12.3, *)) {
            if (!CGPreflightScreenCaptureAccess()) return nullptr;
            const dispatch_time_t deadline =
                dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeoutMS) * NSEC_PER_MSEC);
            __block SCShareableContent *content = nil;
            __block bool listingFailed = false;
            dispatch_semaphore_t listed = dispatch_semaphore_create(0);
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                completionHandler:^(SCShareableContent *value, NSError *error) {
                    content = value;
                    listingFailed = error != nil;
                    dispatch_semaphore_signal(listed);
                }];
            if (dispatch_semaphore_wait(listed, deadline)) { *failure = 2; return nullptr; }
            if (listingFailed || !content) { *failure = 3; return nullptr; }
            SCDisplay *display = nil;
            for (SCDisplay *value in content.displays)
                if (value.displayID == displayID) display = value;
            if (!display) { *failure = 4; return nullptr; }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            config.width = width;
            config.height = height;
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.showsCursor = NO;
            config.queueDepth = queueDepth;
            config.minimumFrameInterval = kCMTimeZero;
            NSCState *state = [NSCState new];
            state->width = width;
            state->height = height;
            state.queue = dispatch_queue_create("io.nikodesk.sck.capture", DISPATCH_QUEUE_SERIAL);
            state.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:state];
            NSError *error = nil;
            if (![state.stream addStreamOutput:state type:SCStreamOutputTypeScreen
                            sampleHandlerQueue:state.queue error:&error]) {
                *failure = 5;
                return nullptr;
            }
            dispatch_semaphore_t started = dispatch_semaphore_create(0);
            [state.stream startCaptureWithCompletionHandler:^(NSError *startError) {
                bool cancel;
                {
                    std::lock_guard<std::mutex> guard(state->lock);
                    state->failed = state->failed || startError != nil;
                    cancel = state->cancelled;
                }
                if (cancel) [state.stream stopCaptureWithCompletionHandler:^(NSError *) { (void)state; }];
                dispatch_semaphore_signal(started);
            }];
            if (dispatch_semaphore_wait(started, deadline)) { *failure = 6; NSCStopStream(state); return nullptr; }
            bool failed;
            {
                std::lock_guard<std::mutex> guard(state->lock);
                failed = state->failed;
            }
            if (failed) { *failure = 7; NSCStopStream(state); return nullptr; }
            *failure = 0;
            return (__bridge_retained void *)state;
        }
        return nullptr;
    }
}

extern "C" bool NSCHealthy(void *pointer) {
    if (!pointer) return false;
    if (@available(macOS 12.3, *)) {
        NSCState *state = (__bridge NSCState *)pointer;
        std::lock_guard<std::mutex> guard(state->lock);
        return !state->failed && !state->cancelled;
    }
    return false;
}

// The newest changed picture since the last call, retained for the caller
// (NSCReleaseBuffer), or null when nothing changed.
extern "C" void *NSCTake(void *pointer) {
    if (!pointer) return nullptr;
    if (@available(macOS 12.3, *)) {
        NSCState *state = (__bridge NSCState *)pointer;
        std::lock_guard<std::mutex> guard(state->lock);
        CVPixelBufferRef frame = state->latest;
        state->latest = nullptr;
        return frame;
    }
    return nullptr;
}

extern "C" void *NSCSurface(void *buffer) {
    return buffer ? CVPixelBufferGetIOSurface((CVPixelBufferRef)buffer) : nullptr;
}

extern "C" bool NSCLock(void *buffer, const uint8_t **base, size_t *stride) {
    if (!buffer) return false;
    CVPixelBufferRef pixel = (CVPixelBufferRef)buffer;
    if (CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return false;
    *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pixel);
    *stride = CVPixelBufferGetBytesPerRow(pixel);
    if (!*base) {
        CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
        return false;
    }
    return true;
}

extern "C" void NSCUnlock(void *buffer) {
    if (buffer) CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)buffer, kCVPixelBufferLock_ReadOnly);
}

extern "C" void NSCRetainBuffer(void *buffer) {
    if (buffer) CFRetain(buffer);
}

extern "C" void NSCReleaseBuffer(void *buffer) {
    if (buffer) CFRelease(buffer);
}

extern "C" void NSCStop(void *pointer) {
    if (!pointer) return;
    if (@available(macOS 12.3, *)) {
        @autoreleasepool {
            NSCState *state = CFBridgingRelease(pointer);
            NSCStopStream(state);
        }
    }
}
