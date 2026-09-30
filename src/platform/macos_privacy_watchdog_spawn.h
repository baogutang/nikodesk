#pragma once
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <Security/Security.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <vector>
#include <cstdint>

namespace nikodesk_privacy::watchdog {
using CodeHash = std::vector<uint8_t>;
inline bool signing_hash(SecStaticCodeRef code, CodeHash& hash) {
    CFDictionaryRef information = nullptr;
    bool ok = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information) == errSecSuccess;
    if (ok) {
        CFTypeRef value = CFDictionaryGetValue(information, kSecCodeInfoUnique);
        ok = value && CFGetTypeID(value) == CFDataGetTypeID() && CFDataGetLength(static_cast<CFDataRef>(value)) > 0;
        if (ok) {
            CFDataRef data = static_cast<CFDataRef>(value);
            hash.assign(CFDataGetBytePtr(data), CFDataGetBytePtr(data) + CFDataGetLength(data));
        }
    }
    if (information) CFRelease(information);
    return ok;
}
inline bool held_image_hash(int executable, CodeHash& hash) {
    char path[64]{};
    snprintf(path, sizeof(path), "/dev/fd/%d", executable);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(path), strlen(path), false);
    SecStaticCodeRef held = nullptr;
    SecRequirementRef requirement = nullptr;
    bool ok = url &&
        SecRequirementCreateWithString(CFSTR("identifier \"io.nikodesk.privacy-watchdog\""), kSecCSDefaultFlags, &requirement) == errSecSuccess &&
        SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &held) == errSecSuccess &&
        SecStaticCodeCheckValidity(held, kSecCSStrictValidate, requirement) == errSecSuccess && signing_hash(held, hash);
    if (held) CFRelease(held);
    if (requirement) CFRelease(requirement);
    if (url) CFRelease(url);
    return ok;
}
inline bool child_matches_held_image(pid_t pid, int executable, const CodeHash& approved) {
    SecCodeRef child = nullptr;
    SecRequirementRef requirement = nullptr;
    CFDictionaryRef child_info = nullptr;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
    if (!number) return false;
    const void* keys[]{kSecGuestAttributePid};
    const void* values[]{number};
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CodeHash current;
    bool ok = !approved.empty() && held_image_hash(executable, current) && current == approved && number && attributes &&
        SecRequirementCreateWithString(CFSTR("identifier \"io.nikodesk.privacy-watchdog\""), kSecCSDefaultFlags, &requirement) == errSecSuccess &&
        SecCodeCopyGuestWithAttributes(nullptr, attributes, kSecCSDefaultFlags, &child) == errSecSuccess &&
        SecCodeCheckValidity(child, kSecCSStrictValidate, requirement) == errSecSuccess &&
        SecCodeCopySigningInformation(child, kSecCSSigningInformation, &child_info) == errSecSuccess;
    if (ok) {
        CFTypeRef actual = CFDictionaryGetValue(child_info, kSecCodeInfoUnique);
        ok = actual && CFGetTypeID(actual) == CFDataGetTypeID();
        if (ok) {
            CFDataRef data = static_cast<CFDataRef>(actual);
            ok = static_cast<size_t>(CFDataGetLength(data)) == approved.size() &&
                std::memcmp(CFDataGetBytePtr(data), approved.data(), approved.size()) == 0;
        }
    }
    if (child_info) CFRelease(child_info);
    if (child) CFRelease(child);
    if (requirement) CFRelease(requirement);
    if (attributes) CFRelease(attributes);
    if (number) CFRelease(number);
    return ok;
}
inline int spawn_verified(pid_t* pid, const char* path, int executable,
                          posix_spawn_file_actions_t* actions, posix_spawnattr_t* attributes,
                          char* const argv[], char* const environment[], const CodeHash& approved) {
    struct sigaction disposition{};
    if (sigaction(SIGCHLD, nullptr, &disposition) != 0 || disposition.sa_handler != SIG_DFL ||
            (disposition.sa_flags & SA_NOCLDWAIT)) return EACCES;
    int result = posix_spawn(pid, path, actions, attributes, argv, environment);
    if (result) return result;
    // The initial thread is suspended: do not allow a replaced path's image to
    // execute before its dynamic code identity matches the initially approved
    // hash and the still-open file. Re-reading an unpinned hash is insufficient
    // if a same-user writer changed the original inode after static validation.
    if (child_matches_held_image(*pid, executable, approved) && kill(*pid, SIGCONT) == 0) return 0;
    int status = 0;
    pid_t state = waitpid(*pid, &status, WNOHANG);
    if (state == 0) {
        kill(*pid, SIGKILL);
        while (waitpid(*pid, &status, 0) < 0 && errno == EINTR) {}
    }
    return EACCES;
}
} // namespace nikodesk_privacy::watchdog
