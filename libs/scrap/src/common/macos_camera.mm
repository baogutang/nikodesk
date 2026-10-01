#include "macos_camera_state.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
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
constexpr size_t max_format_description_bytes = 64 * 1024;
bool append_bytes(std::vector<uint8_t>& bytes, const void* value, size_t size) {
    if (size > max_format_description_bytes - bytes.size() || (size && !value)) return false;
    if (size) {
        const auto* data = static_cast<const uint8_t*>(value);
        bytes.insert(bytes.end(), data, data + size);
    }
    return true;
}
bool append_u64(std::vector<uint8_t>& bytes, uint64_t value) {
    uint8_t encoded[8];
    for (int i = 7; i >= 0; --i) { encoded[i] = static_cast<uint8_t>(value); value >>= 8; }
    return append_bytes(bytes, encoded, sizeof(encoded));
}
bool utf8(CFStringRef value, std::string& output) {
    CFIndex length = CFStringGetLength(value);
    if (length < 0 || length > 4096) return false;
    CFIndex size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    if (size <= 0 || size > 16385) return false;
    std::vector<char> data(static_cast<size_t>(size));
    if (!CFStringGetCString(value, data.data(), size, kCFStringEncodingUTF8)) return false;
    // CFString may contain embedded NUL; such an extension is deliberately unsupported.
    CFIndex used = 0;
    if (CFStringGetBytes(value, CFRangeMake(0, length), kCFStringEncodingUTF8, 0, false,
        nullptr, 0, &used) != length || used != static_cast<CFIndex>(strlen(data.data()))) return false;
    output.assign(data.data(), static_cast<size_t>(used));
    return true;
}
// Hash typed extension values, never an NSDictionary's process-specific order
// or a lossy object description. Unsupported/deep/large metadata fails closed.
bool canonical(CFTypeRef value, std::vector<uint8_t>& bytes, size_t depth, size_t& nodes) {
    if (++nodes > 4096 || depth > 16) return false;
    uint8_t tag = 0;
    if (!value || value == kCFNull) return append_bytes(bytes, &tag, 1);
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) {
        tag = 1; std::string text;
        return utf8(static_cast<CFStringRef>(value), text) && append_bytes(bytes, &tag, 1) &&
            append_u64(bytes, text.size()) && append_bytes(bytes, text.data(), text.size());
    }
    if (type == CFDataGetTypeID()) {
        tag = 2; auto data = static_cast<CFDataRef>(value); CFIndex length = CFDataGetLength(data);
        return length >= 0 && append_bytes(bytes, &tag, 1) && append_u64(bytes, static_cast<uint64_t>(length)) &&
            append_bytes(bytes, CFDataGetBytePtr(data), static_cast<size_t>(length));
    }
    if (type == CFBooleanGetTypeID()) {
        tag = CFBooleanGetValue(static_cast<CFBooleanRef>(value)) ? 4 : 3;
        return append_bytes(bytes, &tag, 1);
    }
    if (type == CFNumberGetTypeID()) {
        auto number = static_cast<CFNumberRef>(value);
        if (CFNumberIsFloatType(number)) {
            double real = 0; uint64_t bits = 0; tag = 5;
            if (!CFNumberGetValue(number, kCFNumberFloat64Type, &real) || !std::isfinite(real)) return false;
            if (real == 0) real = 0; // Normalize IEEE negative zero.
            static_assert(sizeof(bits) == sizeof(real)); memcpy(&bits, &real, sizeof(bits));
            return append_bytes(bytes, &tag, 1) && append_u64(bytes, bits);
        }
        int64_t integer = 0; tag = 6;
        return CFNumberGetValue(number, kCFNumberSInt64Type, &integer) && append_bytes(bytes, &tag, 1) &&
            append_u64(bytes, static_cast<uint64_t>(integer));
    }
    if (type == CFArrayGetTypeID()) {
        tag = 7; auto array = static_cast<CFArrayRef>(value); CFIndex count = CFArrayGetCount(array);
        if (count < 0 || count > 4096 || !append_bytes(bytes, &tag, 1) || !append_u64(bytes, count)) return false;
        for (CFIndex i = 0; i < count; ++i)
            if (!canonical(CFArrayGetValueAtIndex(array, i), bytes, depth + 1, nodes)) return false;
        return true;
    }
    if (type == CFDictionaryGetTypeID()) {
        tag = 8; auto dictionary = static_cast<CFDictionaryRef>(value); CFIndex count = CFDictionaryGetCount(dictionary);
        if (count < 0 || count > 4096) return false;
        std::vector<const void*> keys(static_cast<size_t>(count)), values(static_cast<size_t>(count));
        CFDictionaryGetKeysAndValues(dictionary, keys.data(), values.data());
        std::vector<std::pair<std::string, CFTypeRef>> sorted;
        for (CFIndex i = 0; i < count; ++i) {
            if (!keys[i] || CFGetTypeID(keys[i]) != CFStringGetTypeID()) return false;
            std::string key; if (!utf8(static_cast<CFStringRef>(keys[i]), key)) return false;
            sorted.emplace_back(std::move(key), values[i]);
        }
        std::sort(sorted.begin(), sorted.end(), [](const auto& a, const auto& b){return a.first < b.first;});
        if (!append_bytes(bytes, &tag, 1) || !append_u64(bytes, count)) return false;
        for (const auto& item : sorted)
            if (!append_u64(bytes, item.first.size()) || !append_bytes(bytes, item.first.data(), item.first.size()) ||
                !canonical(item.second, bytes, depth + 1, nodes)) return false;
        return true;
    }
    return false;
}
struct NativeRate { double minimum, maximum; CMTime minimum_duration, maximum_duration; };
bool append_time(std::vector<uint8_t>& bytes, CMTime time) {
    return CMTIME_IS_NUMERIC(time) && time.timescale > 0 && append_u64(bytes, time.value) &&
        append_u64(bytes, time.timescale) && append_u64(bytes, time.flags) && append_u64(bytes, time.epoch);
}
bool describe_format(CMFormatDescriptionRef description, CFDictionaryRef extensions,
    const std::vector<NativeRate>& rates, uint32_t index, uint32_t range_index, NKCameraFormat& output) {
    if (!description || index > 4095 || rates.empty() || rates.size() > 128 || range_index >= rates.size() ||
        CMFormatDescriptionGetMediaType(description) != kCMMediaType_Video) return false;
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(description);
    if (size.width <= 0 || size.height <= 0 || !nikodesk_camera::valid_selection(
        {static_cast<uint32_t>(size.width), static_cast<uint32_t>(size.height), 1, 1})) return false;
    std::vector<uint8_t> bytes;
    const char domain[] = "nikodesk-avfoundation-native-format-v2";
    if (!append_bytes(bytes, domain, sizeof(domain)) || !append_u64(bytes, index) ||
        !append_u64(bytes, CMFormatDescriptionGetMediaType(description)) ||
        !append_u64(bytes, CMFormatDescriptionGetMediaSubType(description)) ||
        !append_u64(bytes, size.width) || !append_u64(bytes, size.height) || !append_u64(bytes, rates.size())) return false;
    for (const auto& rate : rates) {
        if (!std::isfinite(rate.minimum) || !std::isfinite(rate.maximum) || rate.minimum <= 0 || rate.maximum < rate.minimum) return false;
        uint64_t minimum_bits = 0, maximum_bits = 0;
        memcpy(&minimum_bits, &rate.minimum, sizeof(minimum_bits)); memcpy(&maximum_bits, &rate.maximum, sizeof(maximum_bits));
        if (!append_u64(bytes, minimum_bits) || !append_u64(bytes, maximum_bits) ||
            !append_time(bytes, rate.minimum_duration) || !append_time(bytes, rate.maximum_duration)) return false;
    }
    size_t nodes = 0;
    if (!canonical(CMFormatDescriptionGetExtensions(description), bytes, 0, nodes) ||
        !canonical(extensions, bytes, 0, nodes)) return false;
    const auto& rate = rates[range_index];
    double minimum = std::ceil(std::max(1.0, rate.minimum) * 1000.0);
    double maximum = std::floor(std::min(double(nikodesk_camera::max_fps), rate.maximum) * 1000.0);
    if (minimum > maximum || minimum > 60000) return false;
    output = {}; output.width = size.width; output.height = size.height;
    output.min_fps_milli = minimum; output.max_fps_milli = maximum;
    output.native_index = index; output.range_index = range_index;
    return CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), output.native_fingerprint) != nullptr;
}
bool describe_format(AVCaptureDeviceFormat* format, uint32_t index, uint32_t range_index, NKCameraFormat& output) {
    std::vector<NativeRate> rates;
    for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges) {
        if (rates.size() >= 128) return false;
        rates.push_back({range.minFrameRate, range.maxFrameRate, range.minFrameDuration, range.maxFrameDuration});
    }
    return describe_format(format.formatDescription, nullptr, rates, index, range_index, output);
}
bool same_format(const NKCameraFormat& a, const NKCameraFormat& b) {
    return a.width == b.width && a.height == b.height && a.min_fps_milli == b.min_fps_milli &&
        a.max_fps_milli == b.max_fps_milli && a.native_index == b.native_index && a.range_index == b.range_index &&
        memcmp(a.native_fingerprint, b.native_fingerprint, sizeof(a.native_fingerprint)) == 0;
}
bool valid_format_key(const NKCameraFormat& f, NKCameraSelection s) {
    return f.native_index <= 4095 && f.range_index <= 127 && f.width == s.width && f.height == s.height &&
        f.min_fps_milli <= static_cast<uint64_t>(s.fps) * 1000 && f.max_fps_milli >= static_cast<uint64_t>(s.fps) * 1000 &&
        std::any_of(std::begin(f.native_fingerprint), std::end(f.native_fingerprint), [](uint8_t value){return value != 0;});
}
char session_queue_key;
struct Owner;
std::mutex leases_mutex;
std::map<std::string, std::weak_ptr<State>> leases;
std::map<uint64_t, std::weak_ptr<State>> capture_leases;
bool reserve(const std::string& id, const std::shared_ptr<State>& state) {
    std::lock_guard<std::mutex> lock(leases_mutex);
    for (auto it = leases.begin(); it != leases.end();)
        if (it->second.expired()) it = leases.erase(it); else ++it;
    for (auto it = capture_leases.begin(); it != capture_leases.end();)
        if (it->second.expired()) it = capture_leases.erase(it); else ++it;
    if (!state->selection.epoch || leases.size() >= 4 ||
        (leases.count(id) && !leases.at(id).expired()) || capture_leases.count(state->selection.epoch)) return false;
    leases[id] = state;
    capture_leases[state->selection.epoch] = state;
    return true;
}
void unreserve(const std::string& id, const std::shared_ptr<State>& state) {
    std::lock_guard<std::mutex> lock(leases_mutex);
    auto it = leases.find(id);
    if (it != leases.end() && it->second.lock() == state) leases.erase(it);
    auto epoch = capture_leases.find(state->selection.epoch);
    if (epoch != capture_leases.end() && epoch->second.lock() == state) capture_leases.erase(epoch);
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
    bool lease_reserved = false;
#ifdef NIKODESK_CAMERA_TEST_HOOKS
    std::atomic<uint32_t> test_stop_failures{0};
#endif
    NKCameraFormat approved_format{};
    Owner(std::string unique, NKCameraSelection selection): state(std::make_shared<State>(selection)), unique_id(std::move(unique)) {
        session_queue = dispatch_queue_create("io.nikodesk.camera.session", DISPATCH_QUEUE_SERIAL);
        delegate_queue = dispatch_queue_create("io.nikodesk.camera.frames", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(session_queue, &session_queue_key, this, nullptr);
    }
    int stop_on_queue() {
#ifdef NIKODESK_CAMERA_TEST_HOOKS
        if (synthetic && test_stop_failures.load() > 0) {
            --test_stop_failures; state->revoke(NKCAM_ERROR); return NKCAM_FAILED;
        }
#endif
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
                if (lease_reserved) { unreserve(unique_id, state); lease_reserved = false; }
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
                NKCameraFormat current{};
                if (device && approved_format.native_index < device.formats.count) {
                    AVCaptureDeviceFormat* exact = device.formats[approved_format.native_index];
                    if (describe_format(exact, approved_format.native_index, approved_format.range_index, current) &&
                        same_format(current, approved_format) && supports(exact, state->selection)) selected = exact;
                }
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
                NKCameraFormat active{};
                bool exact = device.activeFormat == selected &&
                    describe_format(device.activeFormat, approved_format.native_index, approved_format.range_index, active) &&
                    same_format(active, approved_format) && actual.width == static_cast<int32_t>(state->selection.width) &&
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
namespace {
std::mutex pending_mutex;
std::map<uint64_t, std::shared_ptr<NKCameraSession>> pending_sessions;
}

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
            if (device.formats.count > 4096) continue;
            for (NSUInteger index = 0; index < device.formats.count; ++index) {
                AVCaptureDeviceFormat* format = device.formats[index];
                if (format.videoSupportedFrameRateRanges.count > 128) continue;
                for (NSUInteger range = 0; range < format.videoSupportedFrameRateRanges.count; ++range) {
                    if (entry.formats.size() >= 512) break;
                    NKCameraFormat exact{};
                    if (describe_format(format, static_cast<uint32_t>(index), static_cast<uint32_t>(range), exact))
                        entry.formats.push_back(exact);
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
extern "C" NKCameraSession* NKCameraStart(const char* unique, NKCameraSelection selection,
    const NKCameraFormat* approved_format, int* result) {
    if (!result) return nullptr;
    *result = NKCAM_INVALID;
    if (!unique || !strlen(unique) || strlen(unique) > 1024 || !nikodesk_camera::valid_selection(selection) ||
        !approved_format || !valid_format_key(*approved_format, selection)) return nullptr;
    @autoreleasepool {
        *result = NKCAM_PERMISSION;
        if (!niko_camera_bundle() || NKCameraAuthorizationStatus() != AVAuthorizationStatusAuthorized) return nullptr;
        auto owner = std::make_shared<Owner>(unique, selection);
        owner->approved_format = *approved_format;
        if (!reserve(unique, owner->state)) { *result = NKCAM_BUSY; return nullptr; }
        owner->lease_reserved = true;
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
    if (result == NKCAM_OK) delete p;
    else {
        // Ownership is reachable for explicit retry, rather than leaking the
        // only handle after a failed Rust constructor drops its local session.
        std::lock_guard<std::mutex> lock(pending_mutex);
        auto found = pending_sessions.find(p->owner->state->selection.epoch);
        if (found == pending_sessions.end())
            pending_sessions.emplace(p->owner->state->selection.epoch, std::shared_ptr<NKCameraSession>(p));
        else if (found->second.get() != p) return NKCAM_BUSY;
    }
    return result;
}
extern "C" int NKCameraStopPending(uint64_t capture_lease) {
    if (!capture_lease) return NKCAM_INVALID;
    std::shared_ptr<NKCameraSession> pending;
    {
        std::lock_guard<std::mutex> lock(pending_mutex);
        auto found = pending_sessions.find(capture_lease);
        if (found == pending_sessions.end()) {
            std::lock_guard<std::mutex> leases_lock(leases_mutex);
            auto active = capture_leases.find(capture_lease);
            return active != capture_leases.end() && !active->second.expired() ? NKCAM_BUSY : NKCAM_OK;
        }
        pending = found->second;
    }
    int result = NKCameraStop(pending.get());
    if (result == NKCAM_OK) {
        std::lock_guard<std::mutex> lock(pending_mutex);
        auto found = pending_sessions.find(capture_lease);
        if (found != pending_sessions.end() && found->second == pending) pending_sessions.erase(found);
    }
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
extern "C" int NKCameraTestReserve(NKCameraSession* p) {
    if (!p || !p->owner->synthetic || p->owner->lease_reserved) return NKCAM_INVALID;
    if (!reserve(p->owner->unique_id, p->owner->state)) return NKCAM_BUSY;
    p->owner->lease_reserved = true; return NKCAM_OK;
}
extern "C" void NKCameraTestStopFailures(NKCameraSession* p, uint32_t failures) {
    if (p && p->owner->synthetic) p->owner->test_stop_failures.store(failures);
}
extern "C" int NKCameraTestFormat(const void* description, const void* extensions, uint32_t index,
    double minimum, double maximum, NKCameraFormat* output) {
    if (!output || !std::isfinite(minimum) || !std::isfinite(maximum) || minimum <= 0 || maximum < minimum) return NKCAM_INVALID;
    std::vector<NativeRate> rates{{minimum, maximum, CMTimeMakeWithSeconds(1.0/maximum, 1000000),
        CMTimeMakeWithSeconds(1.0/minimum, 1000000)}};
    return describe_format(static_cast<CMFormatDescriptionRef>(description), static_cast<CFDictionaryRef>(extensions),
        rates, index, 0, *output) ? NKCAM_OK : NKCAM_INVALID;
}
extern "C" int NKCameraTestFormatMatches(const NKCameraFormat* a, const NKCameraFormat* b) {
    return a && b && same_format(*a, *b);
}
#endif
