// A display stream that hands its IOSurfaces to the encoder instead of
// copying and comparing every picture on the CPU. Only pictures the window
// server reports as changed (dirty rectangles) are kept.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <atomic>
#include <mutex>

namespace {
struct Capture {
    CGDisplayStreamRef stream = nullptr;
    dispatch_queue_t queue = nullptr;
    std::mutex lock;
    IOSurfaceRef latest = nullptr;  // retained, use count held
    std::atomic<bool> stopped{false};
};

void Keep(IOSurfaceRef surface) {
    CFRetain(surface);
    IOSurfaceIncrementUseCount(surface);
}

void Drop(IOSurfaceRef surface) {
    if (!surface) return;
    IOSurfaceDecrementUseCount(surface);
    CFRelease(surface);
}
}  // namespace

extern "C" void *NTCStart(uint32_t display, uint32_t width, uint32_t height) {
    @autoreleasepool {
        if (!width || !height) return nullptr;
        Capture *c = new Capture();
        c->queue = dispatch_queue_create("io.nikodesk.texture.capture", DISPATCH_QUEUE_SERIAL);
        // A deeper queue than the CPU path: the encoder holds a surface while
        // it works on it, and the stream must still have one to draw into.
        NSDictionary *properties = @{(__bridge NSString *)kCGDisplayStreamShowCursor: @NO,
            (__bridge NSString *)kCGDisplayStreamPreserveAspectRatio: @YES,
            (__bridge NSString *)kCGDisplayStreamMinimumFrameTime: @0,
            (__bridge NSString *)kCGDisplayStreamQueueDepth: @6};
        c->stream = CGDisplayStreamCreateWithDispatchQueue(display, width, height, 'BGRA',
            (__bridge CFDictionaryRef)properties, c->queue,
            ^(CGDisplayStreamFrameStatus status, uint64_t, IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
                if (status == kCGDisplayStreamFrameStatusStopped) {
                    c->stopped = true;
                    return;
                }
                if (status != kCGDisplayStreamFrameStatusFrameComplete || !surface || !update) return;
                size_t dirty = 0;
                CGDisplayStreamUpdateGetRects(update, kCGDisplayStreamUpdateDirtyRects, &dirty);
                if (!dirty) return;
                Keep(surface);
                IOSurfaceRef previous;
                {
                    std::lock_guard<std::mutex> guard(c->lock);
                    previous = c->latest;
                    c->latest = surface;
                }
                Drop(previous);
            });
        if (!c->stream || CGDisplayStreamStart(c->stream) != kCGErrorSuccess) {
            if (c->stream) CFRelease(c->stream);
            delete c;
            return nullptr;
        }
        return c;
    }
}

// The newest changed picture since the last call, retained for the caller
// (release with NTCRelease), or null when nothing changed.
extern "C" void *NTCTake(void *capture) {
    Capture *c = static_cast<Capture *>(capture);
    if (!c) return nullptr;
    std::lock_guard<std::mutex> guard(c->lock);
    IOSurfaceRef surface = c->latest;
    c->latest = nullptr;
    return surface;
}

extern "C" void NTCRelease(void *surface) {
    Drop(static_cast<IOSurfaceRef>(surface));
}

extern "C" bool NTCRunning(void *capture) {
    Capture *c = static_cast<Capture *>(capture);
    return c && !c->stopped;
}

// Stops the stream. Its references are kept, not released, if the stop is
// not confirmed: releasing them could invalidate a callback still running.
extern "C" void NTCStop(void *capture) {
    Capture *c = static_cast<Capture *>(capture);
    if (!c) return;
    CGDisplayStreamStop(c->stream);
    for (int i = 0; i < 200 && !c->stopped; ++i) usleep(10000);
    if (!c->stopped) return;
    CFRelease(c->stream);
    {
        std::lock_guard<std::mutex> guard(c->lock);
        Drop(c->latest);
        c->latest = nullptr;
    }
    delete c;
}
