#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <mutex>

// Output belongs to this state, not the parent UI. Removing the output breaks
// its retain cycle; completion blocks retain state until stop/start settles.
@interface NPSCaptureState : NSObject<SCStreamOutput,SCStreamDelegate> {
@public
    std::mutex lock;
    CVPixelBufferRef latest;
    bool ready,failed,cancelled;
    uint32_t width,height;
}
@property(strong) SCStream *stream;
@property(strong) dispatch_queue_t queue;
@end
@implementation NPSCaptureState
- (void)dealloc {if(latest) CFRelease(latest);}
- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    std::lock_guard<std::mutex> guard(lock); failed=true;
}
- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if(type!=SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments=(__bridge NSArray*)CMSampleBufferGetSampleAttachmentsArray(sample,false);
    NSNumber *status=attachments.firstObject[SCStreamFrameInfoStatus];
    if(!status || status.integerValue!=SCFrameStatusComplete) return;
    CVPixelBufferRef pixel=CMSampleBufferGetImageBuffer(sample);
    if(!pixel) return;
    std::lock_guard<std::mutex> guard(lock);
    if(cancelled) return;
    if(CVPixelBufferGetPixelFormatType(pixel)!=kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(pixel)!=width || CVPixelBufferGetHeight(pixel)!=height) {failed=true;return;}
    CFRetain(pixel); if(latest) CFRelease(latest); latest=pixel; ready=true;
}
@end

static void NPSStop(NPSCaptureState *state) {
    {std::lock_guard<std::mutex> guard(state->lock);state->cancelled=true;}
    NSError *error=nil;
    [state.stream removeStreamOutput:state type:SCStreamOutputTypeScreen error:&error];
    [state.stream stopCaptureWithCompletionHandler:^(NSError *error){(void)state;}];
}
extern "C" bool NPSCaptureSupported() {
    if(@available(macOS 12.3,*)) return CGPreflightScreenCaptureAccess();
    return false;
}
extern "C" void *NPSCaptureStart(uint32_t displayID,uint32_t pid,uint32_t width,uint32_t height) {
    @autoreleasepool {
        if(!NPSCaptureSupported() || !pid || !width || !height) return nullptr;
        if(@available(macOS 12.3,*)) {
            __block SCShareableContent *content=nil;
            dispatch_semaphore_t listed=dispatch_semaphore_create(0);
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
                completionHandler:^(SCShareableContent *value,NSError *error){content=value;dispatch_semaphore_signal(listed);}];
            if(dispatch_semaphore_wait(listed,dispatch_time(DISPATCH_TIME_NOW,1500*NSEC_PER_MSEC))) return nullptr;
            SCDisplay *display=nil; SCRunningApplication *helper=nil;
            for(SCDisplay *value in content.displays) if(value.displayID==displayID) display=value;
            for(SCRunningApplication *value in content.applications) if(value.processID==(pid_t)pid) helper=value;
            // Never silently start an unfiltered stream if discovery misses the
            // hidden child. Exclusion is explicit and scoped to its process ID.
            if(!display || !helper) return nullptr;
            SCContentFilter *filter=[[SCContentFilter alloc] initWithDisplay:display excludingApplications:@[helper] exceptingWindows:@[]];
            SCStreamConfiguration *config=[SCStreamConfiguration new];
            config.width=width; config.height=height; config.pixelFormat=kCVPixelFormatType_32BGRA;
            config.showsCursor=NO; config.queueDepth=3; config.minimumFrameInterval=kCMTimeZero;
            NPSCaptureState *state=[NPSCaptureState new]; state->width=width;state->height=height;
            state.queue=dispatch_queue_create("io.nikodesk.privacy.capture",DISPATCH_QUEUE_SERIAL);
            state.stream=[[SCStream alloc] initWithFilter:filter configuration:config delegate:state];
            NSError *error=nil;
            if(![state.stream addStreamOutput:state type:SCStreamOutputTypeScreen sampleHandlerQueue:state.queue error:&error]) return nullptr;
            dispatch_semaphore_t started=dispatch_semaphore_create(0);
            [state.stream startCaptureWithCompletionHandler:^(NSError *error){
                bool cancel;
                {std::lock_guard<std::mutex> guard(state->lock);state->failed=error!=nil;cancel=state->cancelled;}
                if(cancel) [state.stream stopCaptureWithCompletionHandler:^(NSError *error){(void)state;}];
                dispatch_semaphore_signal(started);
            }];
            if(dispatch_semaphore_wait(started,dispatch_time(DISPATCH_TIME_NOW,1500*NSEC_PER_MSEC))) {NPSStop(state);return nullptr;}
            {std::lock_guard<std::mutex> guard(state->lock);if(state->failed){state->cancelled=true;}}
            if(state->cancelled){NPSStop(state);return nullptr;}
            return (__bridge_retained void*)state;
        }
        return nullptr;
    }
}
extern "C" bool NPSCaptureReady(void *pointer) {
    if(!pointer)return false;NPSCaptureState *state=(__bridge NPSCaptureState*)pointer;
    std::lock_guard<std::mutex> guard(state->lock);return state->ready && !state->failed && !state->cancelled;
}
extern "C" bool NPSCaptureHealthy(void *pointer) {
    if(!pointer)return false;NPSCaptureState *state=(__bridge NPSCaptureState*)pointer;
    std::lock_guard<std::mutex> guard(state->lock);return !state->failed && !state->cancelled;
}
extern "C" bool NPSCapturePending(void *pointer) {
    if(!pointer)return false;NPSCaptureState *state=(__bridge NPSCaptureState*)pointer;
    std::lock_guard<std::mutex> guard(state->lock);return state->latest && !state->failed && !state->cancelled;
}
extern "C" int NPSCaptureTake(void *pointer,uint8_t *pixels,size_t length) {
    if(!pointer || !pixels)return -1;NPSCaptureState *state=(__bridge NPSCaptureState*)pointer;
    CVPixelBufferRef frame=nullptr;
    {
        std::lock_guard<std::mutex> guard(state->lock);
        if(state->failed || state->cancelled)return -1;
        if(!state->latest)return 0;
        frame=state->latest;state->latest=nullptr;
    }
    const size_t row=static_cast<size_t>(state->width)*4;
    bool valid=length==row*state->height && CVPixelBufferLockBaseAddress(frame,kCVPixelBufferLock_ReadOnly)==kCVReturnSuccess;
    if(valid){
        const size_t stride=CVPixelBufferGetBytesPerRow(frame);
        const uint8_t *source=(const uint8_t*)CVPixelBufferGetBaseAddress(frame);
        valid=source && stride>=row;
        if(valid)for(uint32_t y=0;y<state->height;++y)memcpy(pixels+y*row,source+y*stride,row);
        CVPixelBufferUnlockBaseAddress(frame,kCVPixelBufferLock_ReadOnly);
    }
    CFRelease(frame);return valid?1:-1;
}
extern "C" void NPSCaptureRelease(void *pointer) {
    if(!pointer)return;
    @autoreleasepool {NPSCaptureState *state=CFBridgingRelease(pointer);NPSStop(state);}
}
