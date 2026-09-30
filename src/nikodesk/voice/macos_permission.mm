#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <cstring>
#include <unistd.h>
#include "macos_permission.h"

int NKVoiceMicrophoneAuthorization(void) {
    @autoreleasepool {
        if (getuid() == 0 || geteuid() != getuid()) return -2;
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle.bundleIdentifier isEqualToString:@"io.nikodesk.macos"]) return -2;
        id purpose = [bundle objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"];
        if (![purpose isKindOfClass:NSString.class] || [(NSString *)purpose length] == 0) return -2;
        switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
            case AVAuthorizationStatusAuthorized: return 1;
            case AVAuthorizationStatusNotDetermined: return 0;
            case AVAuthorizationStatusDenied:
            case AVAuthorizationStatusRestricted: return -1;
        }
        return -2;
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
