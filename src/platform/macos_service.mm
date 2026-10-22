// Code-signature checks for the privileged service. A caller is identified
// by the audit token the kernel attached to its socket, never by process ID:
// an ID can be reused, or exec'd into another program after connecting.
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <bsm/libbsm.h>
#include <launch.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {
SecRequirementRef Requirement(const char *text) {
    if (!text) return nullptr;
    NSString *string = [NSString stringWithUTF8String:text];
    SecRequirementRef requirement = nullptr;
    if (!string || SecRequirementCreateWithString((__bridge CFStringRef)string, kSecCSDefaultFlags, &requirement) !=
                       errSecSuccess)
        return nullptr;
    return requirement;
}

void CopyPath(SecStaticCodeRef code, char *path, size_t length) {
    if (!path || !length) return;
    path[0] = 0;
    CFURLRef url = nullptr;
    if (SecCodeCopyPath(code, kSecCSDefaultFlags, &url) != errSecSuccess || !url) return;
    CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, (CFIndex)length);
    CFRelease(url);
}
}  // namespace

// 0 allowed; 1 no audit token; 2 no code for it; 3 bad requirement;
// 4 requirement not met. Writes the caller's effective uid and path.
extern "C" int NikoPeerAllowed(int fd, const char *requirementText, uid_t *euid, char *path, size_t length) {
    @autoreleasepool {
        if (path && length) path[0] = 0;
        audit_token_t token;
        socklen_t size = sizeof(token);
        if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) != 0 || size != sizeof(token)) return 1;
        if (euid) *euid = audit_token_to_euid(token);
        NSDictionary *attributes = @{
            (__bridge NSString *)kSecGuestAttributeAudit : [NSData dataWithBytes:&token length:sizeof(token)]
        };
        SecCodeRef code = nullptr;
        if (SecCodeCopyGuestWithAttributes(nullptr, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) !=
                errSecSuccess ||
            !code)
            return 2;
        CopyPath((SecStaticCodeRef)code, path, length);
        SecRequirementRef requirement = Requirement(requirementText);
        if (!requirement) {
            CFRelease(code);
            return 3;
        }
        OSStatus status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
        CFRelease(requirement);
        CFRelease(code);
        return status == errSecSuccess ? 0 : 4;
    }
}

// 0 allowed; 1 not found; 3 bad requirement; 4 signature invalid or
// requirement not met. Checks every nested executable too.
extern "C" int NikoBundleAllowed(const char *bundlePath, const char *requirementText) {
    @autoreleasepool {
        NSString *string = bundlePath ? [NSString stringWithUTF8String:bundlePath] : nil;
        if (!string) return 1;
        SecStaticCodeRef code = nullptr;
        if (SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:string], kSecCSDefaultFlags, &code) !=
                errSecSuccess ||
            !code)
            return 1;
        SecRequirementRef requirement = Requirement(requirementText);
        if (!requirement) {
            CFRelease(code);
            return 3;
        }
        OSStatus status = SecStaticCodeCheckValidity(
            code, kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate, requirement);
        CFRelease(requirement);
        CFRelease(code);
        return status == errSecSuccess ? 0 : 4;
    }
}

// The listening socket launchd created for this job, or -1.
extern "C" int NikoLaunchSocket(const char *name) {
    int *fds = nullptr;
    size_t count = 0;
    if (launch_activate_socket(name, &fds, &count) != 0 || !fds) return -1;
    int fd = count ? fds[0] : -1;
    for (size_t i = 1; i < count; ++i) close(fds[i]);
    free(fds);
    return fd;
}

// A requirement naming this process's own code directory hash, for tests.
extern "C" bool NikoSelfCdhashRequirement(char *out, size_t length) {
    @autoreleasepool {
        SecCodeRef code = nullptr;
        if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess || !code) return false;
        CFDictionaryRef info = nullptr;
        OSStatus status = SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSSigningInformation, &info);
        CFRelease(code);
        if (status != errSecSuccess || !info) return false;
        NSData *hash = (__bridge NSData *)CFDictionaryGetValue(info, kSecCodeInfoUnique);
        bool ok = false;
        if (hash.length) {
            NSMutableString *hex = [NSMutableString stringWithString:@"cdhash H\""];
            const uint8_t *bytes = (const uint8_t *)hash.bytes;
            for (NSUInteger i = 0; i < hash.length; ++i) [hex appendFormat:@"%02x", bytes[i]];
            [hex appendString:@"\""];
            ok = strlcpy(out, hex.UTF8String, length) < length;
        }
        CFRelease(info);
        return ok;
    }
}

// One-time feasibility probe for the login window session (phase 3): what a
// root agent there may do. Writes JSON; nothing is captured to disk and no
// input is injected (only the permission preflights are asked).
extern "C" bool NikoLoginWindowProbe(char *out, size_t length) {
    @autoreleasepool {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"euid"] = @(geteuid());
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();
        if (session) {
            NSDictionary *values = (__bridge NSDictionary *)session;
            for (NSString *key in @[@"kCGSSessionOnConsoleKey", @"kCGSSessionLoginDoneKey", @"CGSSessionScreenIsLocked",
                                    @"kCGSSessionUserNameKey"]) {
                id value = values[key];
                // The user name says only which account is shown; keep presence, not the name.
                if ([key isEqualToString:@"kCGSSessionUserNameKey"]) value = value ? @"present" : nil;
                if (value) result[key] = value;
            }
            CFRelease(session);
        } else {
            result[@"session"] = @"none";
        }
        result[@"screen_capture_preflight"] = @(CGPreflightScreenCaptureAccess());
        result[@"post_event_preflight"] = @(CGPreflightPostEventAccess());
        result[@"secure_input"] = @((bool)IsSecureEventInputEnabled());
        CGImageRef image = CGDisplayCreateImage(CGMainDisplayID());
        if (image) {
            result[@"cg_image"] = [NSString stringWithFormat:@"%zux%zu", CGImageGetWidth(image), CGImageGetHeight(image)];
            CGImageRelease(image);
        } else {
            result[@"cg_image"] = @"none";
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        if (!json || json.length + 1 > length) return false;
        memcpy(out, json.bytes, json.length);
        out[json.length] = 0;
        return true;
    }
}
