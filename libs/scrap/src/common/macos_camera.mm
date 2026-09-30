#include "macos_camera_state.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <atomic>
#include <cmath>
#include <map>
#include <string>
#include <vector>
#include <algorithm>
#include <cstring>

using nikodesk_camera::State;
namespace {
bool ordinary_user() { return getuid() != 0 && geteuid() == getuid() && getegid() == getgid(); }
bool niko_camera_bundle() {
    NSBundle* bundle = [NSBundle mainBundle];
    id purpose = [bundle objectForInfoDictionaryKey:@"NSCameraUsageDescription"];
    return ordinary_user() && [[bundle bundleIdentifier] isEqualToString:@"io.nikodesk.macos"] &&
        [purpose isKindOfClass:[NSString class]] && [purpose length] > 0;
}
NSArray<AVCaptureDevice*>* devices() {
    NSMutableArray<AVCaptureDeviceType>* types = [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
    if (@available(macOS 14.0, *)) [types addObject:AVCaptureDeviceTypeExternal];
    else [types addObject:AVCaptureDeviceTypeExternalUnknown];
    return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
        mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified].devices;
}
bool supports(AVCaptureDeviceFormat* format, NKCameraSelection s) {
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    if (size.width != static_cast<int32_t>(s.width) || size.height != static_cast<int32_t>(s.height)) return false;
    for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges)
        if (s.fps >= range.minFrameRate && s.fps <= range.maxFrameRate) return true;
    return false;
}
char session_queue_key;
struct Owner;
std::mutex leases_mutex;
std::map<std::string, std::weak_ptr<State>> leases;
bool reserve(const std::string& id, const std::shared_ptr<State>& state) {
    std::lock_guard<std::mutex> lock(leases_mutex);
    for (auto it = leases.begin(); it != leases.end();)
        if (it->second.expired()) it = leases.erase(it); else ++it;
    if (leases.size() >= 4 || (leases.count(id) && !leases.at(id).expired())) return false;
    leases[id] = state;
    return true;
}
void unreserve(const std::string& id, const std::shared_ptr<State>& state) {
    std::lock_guard<std::mutex> lock(leases_mutex);
    auto it = leases.find(id);
    if (it != leases.end() && it->second.lock() == state) leases.erase(it);
}
} // namespace

@interface NKCameraDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
@public
    std::shared_ptr<State> state;
}
@end
@implementation NKCameraDelegate
- (void)captureOutput:(AVCaptureOutput*)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection*)connection {
    @autoreleasepool {
        CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
        int result = state->publish(buffer, state->selection.epoch);
        if (result == NKCAM_INVALID) state->revoke(NKCAM_ERROR);
    }
}
@end

namespace {
struct Owner {
    std::shared_ptr<State> state;
    std::string unique_id;
    dispatch_queue_t session_queue;
    dispatch_queue_t delegate_queue;
    AVCaptureSession* session = nil;
    AVCaptureVideoDataOutput* output = nil;
    AVCaptureDeviceInput* input = nil;
    NKCameraDelegate* delegate = nil;
    id error_observer = nil;
    bool closed = false;
    bool configuring = false;
    bool synthetic = false;
    Owner(std::string unique, NKCameraSelection selection): state(std::make_shared<State>(selection)), unique_id(std::move(unique)) {
        session_queue = dispatch_queue_create("io.nikodesk.camera.session", DISPATCH_QUEUE_SERIAL);
        delegate_queue = dispatch_queue_create("io.nikodesk.camera.frames", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(session_queue, &session_queue_key, this, nullptr);
    }
    int stop_on_queue() {
        if (closed) { state->revoke(NKCAM_ENDED); return NKCAM_OK; }
        bool stopped = false;
        @try {
            [output setSampleBufferDelegate:nil queue:nil];
            dispatch_sync(delegate_queue, ^{});
            if (configuring) { [session commitConfiguration]; configuring = false; }
            [session stopRunning];
            stopped = !session || !session.isRunning;
            if (stopped) {
                if (error_observer) [[NSNotificationCenter defaultCenter] removeObserver:error_observer];
                error_observer = nil;
                if (session) {
                    [session beginConfiguration];
                    for (AVCaptureInput* item in session.inputs) [session removeInput:item];
                    for (AVCaptureOutput* item in session.outputs) [session removeOutput:item];
                    [session commitConfiguration];
                }
                delegate = nil; output = nil; input = nil; session = nil;
                closed = true;
                if (!synthetic) unreserve(unique_id, state);
            }
        } @catch (NSException*) { stopped = false; }
        state->revoke(stopped ? NKCAM_ENDED : NKCAM_ERROR);
        return stopped ? NKCAM_OK : NKCAM_FAILED;
    }
    void start_on_queue() {
        @autoreleasepool {
            bool cancelled = false;
            { std::lock_guard<std::mutex> lock(state->mutex); cancelled = state->revoked; }
            if (cancelled) { stop_on_queue(); return; }
            @try {
                // NotDetermined is refused before creating Input, which would
                // otherwise trigger an implicit system authorization dialog.
                if (!niko_camera_bundle() || NKCameraAuthorizationStatus() != AVAuthorizationStatusAuthorized) {
                    state->revoke(NKCAM_ERROR); stop_on_queue(); return;
                }
                AVCaptureDevice* device = nil;
                for (AVCaptureDevice* candidate in devices())
                    if ([candidate.uniqueID isEqualToString:[NSString stringWithUTF8String:unique_id.c_str()]]) { device = candidate; break; }
                AVCaptureDeviceFormat* selected = nil;
                for (AVCaptureDeviceFormat* format in device.formats)
                    if (supports(format, state->selection)) { selected = format; break; }
                if (!device || !selected) { state->revoke(NKCAM_ERROR); stop_on_queue(); return; }
                if (NKCameraAuthorizationStatus() != AVAuthorizationStatusAuthorized) {
                    state->revoke(NKCAM_ERROR); stop_on_queue(); return;
                }
                NSError* error = nil;
                input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
                if (!input || error) { state->revoke(NKCAM_ERROR); stop_on_queue(); return; }
                session = [[AVCaptureSession alloc] init];
                output = [[AVCaptureVideoDataOutput alloc] init];
                output.alwaysDiscardsLateVideoFrames = YES;
                output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
                delegate = [[NKCameraDelegate alloc] init]; delegate->state = state;
                [output setSampleBufferDelegate:delegate queue:delegate_queue];
                [session beginConfiguration];
                configuring = true;
                // InputPriority is iOS-only. On macOS use the exact device
                // activeFormat, then verify it and the first output dimensions.
                if (![session canAddInput:input] || ![session canAddOutput:output]) {
                    [session commitConfiguration]; configuring = false; state->revoke(NKCAM_ERROR); stop_on_queue(); return;
                }
                [session addInput:input]; [session addOutput:output];
                if (![device lockForConfiguration:&error]) {
                    [session commitConfiguration]; configuring = false; state->revoke(NKCAM_ERROR); stop_on_queue(); return;
                }
                @try {
                    device.activeFormat = selected;
                    device.activeVideoMinFrameDuration = CMTimeMake(1, state->selection.fps);
                    device.activeVideoMaxFrameDuration = CMTimeMake(1, state->selection.fps);
                } @finally { [device unlockForConfiguration]; }
                [session commitConfiguration];
                configuring = false;
                auto snapshot = state;
                error_observer = [[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification
                    object:session queue:nil usingBlock:^(NSNotification*) { snapshot->revoke(NKCAM_ERROR); }];
                { std::lock_guard<std::mutex> lock(state->mutex); cancelled = state->revoked; }
                if (cancelled) { stop_on_queue(); return; }
                [session startRunning]; // Own queue; Running requires a validated first frame.
                { std::lock_guard<std::mutex> lock(state->mutex); cancelled = state->revoked; }
                CMVideoDimensions actual = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
                bool exact = actual.width == static_cast<int32_t>(state->selection.width) &&
                    actual.height == static_cast<int32_t>(state->selection.height) &&
                    CMTimeCompare(device.activeVideoMinFrameDuration, CMTimeMake(1, state->selection.fps)) == 0 &&
                    CMTimeCompare(device.activeVideoMaxFrameDuration, CMTimeMake(1, state->selection.fps)) == 0;
                if (!session.isRunning || cancelled || !exact) { state->revoke(NKCAM_ERROR); stop_on_queue(); }
                else state->started();
            } @catch (NSException*) { state->revoke(NKCAM_ERROR); stop_on_queue(); }
        }
    }
};
struct PermissionState { std::atomic<int> status{-1}; std::atomic<bool> cancelled{false}; uint64_t id; };
struct Device { std::string id, name; std::vector<NKCameraFormat> formats; };
} // namespace

struct NKCameraPermission { std::shared_ptr<PermissionState> state; };
struct NKCameraDevices { std::vector<Device> devices; };
struct NKCameraSession { std::shared_ptr<Owner> owner; };

extern "C" int NKCameraAuthorizationStatus() {
    @autoreleasepool { return ordinary_user() ? static_cast<int>([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) : -1; }
}
extern "C" NKCameraPermission* NKCameraRequestAccess(uint64_t request_id) {
    @autoreleasepool {
        if (!request_id || !niko_camera_bundle()) return nullptr;
        auto request = std::make_shared<PermissionState>(); request->id = request_id;
        int status = NKCameraAuthorizationStatus();
        if (status < 0) return nullptr;
        if (status != AVAuthorizationStatusNotDetermined) request->status = status;
        else dispatch_async(dispatch_get_main_queue(), ^{
            if (request->cancelled) return;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                if (!request->cancelled) request->status = granted ? AVAuthorizationStatusAuthorized : AVAuthorizationStatusDenied;
            }];
        });
        return new NKCameraPermission{request};
    }
}
extern "C" int NKCameraPermissionPoll(NKCameraPermission* p, int* status) {
    if (!p || !status) return NKCAM_INVALID;
    if (p->state->cancelled) return NKCAM_STALE;
    int value = p->state->status;
    if (value < 0) return NKCAM_WOULD_BLOCK;
    *status = value; return NKCAM_OK;
}
extern "C" void NKCameraPermissionCancel(NKCameraPermission* p) { if (p) p->state->cancelled = true; }
extern "C" void NKCameraPermissionRelease(NKCameraPermission* p) { NKCameraPermissionCancel(p); delete p; }
extern "C" NKCameraDevices* NKCameraEnumerate(int* result) {
    if (!result) return nullptr;
    *result = NKCAM_PERMISSION;
    if (!ordinary_user()) return nullptr;
    @autoreleasepool { @try {
        auto list = std::make_unique<NKCameraDevices>();
        for (AVCaptureDevice* device in devices()) {
            if (list->devices.size() >= 64) break;
            const char* unique = device.uniqueID.UTF8String; const char* name = device.localizedName.UTF8String;
            if (!unique || !name || !strlen(unique) || strlen(unique) > 1024 || strlen(name) > 512) continue;
            Device entry{unique, name, {}};
            for (AVCaptureDeviceFormat* format in device.formats) {
                CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
                if (!nikodesk_camera::valid_selection({static_cast<uint32_t>(size.width), static_cast<uint32_t>(size.height), 1, 1})) continue;
                for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges) {
                    if (!std::isfinite(range.minFrameRate) || !std::isfinite(range.maxFrameRate)) continue;
                    double minimum = std::ceil(std::max(1.0, range.minFrameRate) * 1000.0);
                    double maximum = std::floor(std::min(double(nikodesk_camera::max_fps), range.maxFrameRate) * 1000.0);
                    if (minimum > maximum || minimum > 60000 || entry.formats.size() >= 512) continue;
                    entry.formats.push_back({static_cast<uint32_t>(size.width), static_cast<uint32_t>(size.height),
                        static_cast<uint32_t>(minimum), static_cast<uint32_t>(maximum)});
                }
            }
            list->devices.push_back(std::move(entry));
        }
        std::sort(list->devices.begin(), list->devices.end(), [](const Device& a, const Device& b){ return a.id < b.id; });
        *result = NKCAM_OK; return list.release();
    } @catch (NSException*) { *result = NKCAM_FAILED; return nullptr; } }
}
extern "C" size_t NKCameraDeviceCount(const NKCameraDevices* p) { return p ? p->devices.size() : 0; }
extern "C" int NKCameraDeviceAt(const NKCameraDevices* p, size_t i, NKCameraDevice* output) {
    if (!p || !output || i >= p->devices.size()) return NKCAM_INVALID;
    const auto& device = p->devices[i]; *output = {device.id.c_str(), device.name.c_str(), device.formats.size()}; return NKCAM_OK;
}
extern "C" int NKCameraFormatAt(const NKCameraDevices* p, size_t i, size_t f, NKCameraFormat* output) {
    if (!p || !output || i >= p->devices.size() || f >= p->devices[i].formats.size()) return NKCAM_INVALID;
    *output = p->devices[i].formats[f]; return NKCAM_OK;
}
extern "C" void NKCameraDevicesRelease(NKCameraDevices* p) { delete p; }
extern "C" NKCameraSession* NKCameraStart(const char* unique, NKCameraSelection selection, int* result) {
    if (!result) return nullptr;
    *result = NKCAM_INVALID;
    if (!unique || !strlen(unique) || strlen(unique) > 1024 || !nikodesk_camera::valid_selection(selection)) return nullptr;
    @autoreleasepool {
        *result = NKCAM_PERMISSION;
        if (!niko_camera_bundle() || NKCameraAuthorizationStatus() != AVAuthorizationStatusAuthorized) return nullptr;
        auto owner = std::make_shared<Owner>(unique, selection);
        if (!reserve(unique, owner->state)) { *result = NKCAM_BUSY; return nullptr; }
        dispatch_async(owner->session_queue, ^{ owner->start_on_queue(); });
        *result = NKCAM_OK; return new NKCameraSession{owner};
    }
}
extern "C" int NKCameraWaitRunning(NKCameraSession* p, uint32_t timeout) {
    if (!p || timeout > 30000) return NKCAM_INVALID;
    auto state = p->owner->state;
    std::unique_lock<std::mutex> lock(state->mutex);
    if (!state->changed.wait_for(lock, std::chrono::milliseconds(timeout), [&]{return state->phase == NKCAM_RUNNING || state->revoked;})) return NKCAM_TIMEOUT;
    return state->terminal_result();
}
extern "C" int NKCameraTakeLatest(NKCameraSession* p, uint64_t epoch, uint32_t timeout, NKCameraFrame** output) {
    if (!p || !output || timeout > 30000) return NKCAM_INVALID;
    *output = nullptr;
    auto state = p->owner->state;
    if (epoch != state->selection.epoch) return NKCAM_STALE;
    if (!p->owner->synthetic && NKCameraAuthorizationStatus() != AVAuthorizationStatusAuthorized) {
        state->revoke(NKCAM_ERROR);
        return NKCameraStop(p) == NKCAM_OK ? NKCAM_PERMISSION : NKCAM_FAILED;
    }
    std::unique_lock<std::mutex> lock(state->mutex);
    if (!state->changed.wait_for(lock, std::chrono::milliseconds(timeout), [&]{return (state->phase == NKCAM_RUNNING && bool(state->latest)) || state->revoked;})) return NKCAM_WOULD_BLOCK;
    int result = state->terminal_result();
    if (result != NKCAM_OK) return result;
    *output = state->latest.release(); return NKCAM_OK;
}
extern "C" int NKCameraSessionStatus(NKCameraSession* p, int* phase) {
    if (!p || !phase) return NKCAM_INVALID;
    auto state = p->owner->state; std::lock_guard<std::mutex> lock(state->mutex); *phase = state->phase; return NKCAM_OK;
}
extern "C" int NKCameraStop(NKCameraSession* p) {
    if (!p) return NKCAM_INVALID;
    auto owner = p->owner;
    owner->state->revoke();
    if (dispatch_get_specific(&session_queue_key) == owner.get()) return NKCAM_BUSY;
    __block int result = NKCAM_FAILED;
    dispatch_sync(owner->session_queue, ^{ result = owner->stop_on_queue(); });
    return result;
}
extern "C" int NKCameraSessionRelease(NKCameraSession* p) {
    if (!p) return NKCAM_INVALID;
    int result = NKCameraStop(p);
    if (result == NKCAM_OK) delete p; // Failed native stop retains ownership and its lease.
    return result;
}
extern "C" int NKCameraFrameDescribe(const NKCameraFrame* p, NKCameraFrameView* output) {
    if (!p || !output) return NKCAM_INVALID;
    *output = p->view; return NKCAM_OK;
}
extern "C" void NKCameraFrameRelease(NKCameraFrame* p) { delete p; }
#ifdef NIKODESK_CAMERA_TEST_HOOKS
extern "C" NKCameraSession* NKCameraTestCreate(NKCameraSelection selection) {
    if (!nikodesk_camera::valid_selection(selection)) return nullptr;
    auto owner = std::make_shared<Owner>("in-memory-buffer-test", selection); owner->synthetic = true;
    return new NKCameraSession{owner};
}
extern "C" void NKCameraTestStarted(NKCameraSession* p) { if (p) p->owner->state->started(); }
extern "C" int NKCameraTestPublish(NKCameraSession* p, void* buffer, uint64_t epoch) {
    return p ? p->owner->state->publish(static_cast<CVPixelBufferRef>(buffer), epoch) : NKCAM_INVALID;
}
extern "C" void NKCameraTestFail(NKCameraSession* p) { if (p) p->owner->state->revoke(NKCAM_ERROR); }
#endif
