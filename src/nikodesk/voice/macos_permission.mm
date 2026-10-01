#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <cstring>
#include <vector>
#include <cmath>
#include <memory>
#include <atomic>
#include <unistd.h>
#include "macos_permission.h"

static bool validVoiceProcess() {
    if (getuid() == 0 || geteuid() != getuid()) return false;
    NSBundle *bundle = NSBundle.mainBundle;
    if (![bundle.bundleIdentifier isEqualToString:@"io.nikodesk.macos"]) return false;
    id purpose = [bundle objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"];
    return [purpose isKindOfClass:NSString.class] && [(NSString *)purpose length] != 0;
}

int NKVoiceMicrophoneAuthorization(void) {
    @autoreleasepool {
        if (!validVoiceProcess()) return -2;
        switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
            case AVAuthorizationStatusAuthorized: return 1;
            case AVAuthorizationStatusNotDetermined: return 0;
            case AVAuthorizationStatusDenied: return -1;
            case AVAuthorizationStatusRestricted: return -3;
        }
        return -2;
    }
}

int NKVoiceCompleteMicrophoneAuthorization(NKVoicePermissionCompletion completion, void *context, int status) {
    if (completion == nullptr || context == nullptr) return -2;
    if (status != 1 && status != 0 && status != -1 && status != -3 && status != -2) status = -2;
    completion(context, status);
    return 1;
}

int NKVoiceRequestMicrophoneAuthorization(NKVoicePermissionCompletion completion, void *context) {
    @autoreleasepool {
        if (completion == nullptr || context == nullptr || !validVoiceProcess()) return -2;
        const int current = NKVoiceMicrophoneAuthorization();
        if (current != 0) {
            // An accepted context always completes; no second prompt for a
            // decision already made by the user or system administrator.
            NKVoiceCompleteMicrophoneAuthorization(completion, context, current);
            return 1;
        }
        // Both the native block and an exceptional return may observe the
        // accepted context. Only one is allowed to call (and free) it.
        std::shared_ptr<std::atomic<bool>> completed;
        try {
            completed = std::make_shared<std::atomic<bool>>(false);
            @try {
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                    @autoreleasepool {
                        (void)granted;
                        if (!completed->exchange(true)) {
                            NKVoiceCompleteMicrophoneAuthorization(completion, context, NKVoiceMicrophoneAuthorization());
                        }
                    }
                }];
            } @catch (NSException *exception) {
                (void)exception;
                if (!completed->exchange(true)) NKVoiceCompleteMicrophoneAuthorization(completion, context, -2);
            }
        } catch (...) {
            // No C++ exception may cross this C ABI. Even if registration
            // partially retained the block, it shares the one-shot fence.
            if (!completed || !completed->exchange(true))
                NKVoiceCompleteMicrophoneAuthorization(completion, context, -2);
        }
        return 1;
    }
}

static bool deviceAlive(uint32_t device) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 alive = 0, size = sizeof(alive);
    return device != kAudioObjectUnknown && AudioObjectGetPropertyData(device,
        &address, 0, nullptr, &size, &alive) == noErr && size == sizeof(alive) && alive == 1;
}

int NKVoiceReadDeviceUID(uint32_t device, char *output, uint32_t capacity) {
    if (output == nullptr || capacity < 2 || capacity > 8192) return 0;
    output[0] = '\0';
    if (!deviceAlive(device)) return 0;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef uid = nullptr;
    UInt32 size = sizeof(uid);
    OSStatus status = AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &uid);
    bool valid = status == noErr && size == sizeof(uid) && uid != nullptr;
    if (valid) {
        valid = CFGetTypeID(uid) == CFStringGetTypeID()
            && CFStringGetCString(uid, output, capacity, kCFStringEncodingUTF8)
            && output[0] != '\0';
    }
    // Apple's property contract transfers ownership of the returned CFObject.
    if (uid != nullptr) CFRelease(uid);
    if (!valid || !deviceAlive(device)) { output[0] = '\0'; return 0; }
    return 1;
}

int NKVoiceDeviceMatches(uint32_t device, const char *expected_uid) {
    if (expected_uid == nullptr || expected_uid[0] == '\0') return 0;
    char actual[8192];
    return NKVoiceReadDeviceUID(device, actual, sizeof(actual)) == 1
        && NKVoiceUIDEquals(expected_uid, actual) == 1;
}

int NKVoiceUIDEquals(const char *expected_uid, const char *actual_uid) {
    return expected_uid != nullptr && actual_uid != nullptr && expected_uid[0] != '\0'
        && actual_uid[0] != '\0' && std::strcmp(expected_uid, actual_uid) == 0;
}

static bool channelCount(uint32_t device, AudioObjectPropertyScope scope, uint32_t *channels) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration, scope,
        kAudioObjectPropertyElementMain};
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &bytes) != noErr
        || bytes < offsetof(AudioBufferList, mBuffers) || bytes > 65536) return false;
    // u64 alignment also satisfies the native AudioBuffer pointer alignment.
    std::vector<uint64_t> storage;
    try {
        storage.resize((bytes + sizeof(uint64_t) - 1) / sizeof(uint64_t), 0);
    } catch (...) {
        return false;
    }
    UInt32 actual = bytes;
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &actual, storage.data()) != noErr
        || actual != bytes) return false;
    const auto *list = reinterpret_cast<const AudioBufferList *>(storage.data());
    if (list->mNumberBuffers > 128 || list->mNumberBuffers >
        (bytes - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer)) return false;
    uint32_t count = 0;
    for (uint32_t index = 0; index < list->mNumberBuffers; ++index) {
        if (list->mBuffers[index].mNumberChannels > 256 - count) return false;
        count += list->mBuffers[index].mNumberChannels;
    }
    *channels = count;
    return true;
}

int NKVoiceReadDeviceMetadata(uint32_t device, uint32_t *capture_channels,
                             uint32_t *playback_channels, double *nominal_rate) {
    if (capture_channels == nullptr || playback_channels == nullptr || nominal_rate == nullptr) return 0;
    *capture_channels = 0; *playback_channels = 0; *nominal_rate = 0;
    if (!deviceAlive(device)) return 0;
    uint32_t input = 0, output = 0;
    if (!channelCount(device, kAudioObjectPropertyScopeInput, &input)
        || !channelCount(device, kAudioObjectPropertyScopeOutput, &output)) return 0;
    AudioObjectPropertyAddress rateAddress = {kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Float64 rate = 0; UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(device, &rateAddress, 0, nullptr, &size, &rate) != noErr
        || size != sizeof(rate) || !std::isfinite(rate) || rate <= 0 || !deviceAlive(device)) return 0;
    *capture_channels = input; *playback_channels = output; *nominal_rate = rate;
    return 1;
}
