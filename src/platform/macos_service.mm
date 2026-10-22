// The phase 3 login window feasibility probe. The signature checks of the
// privileged service live in libs/nikodesk_service/src/native.mm.
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <string.h>
#include <unistd.h>

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
