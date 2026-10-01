#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <unistd.h>

extern "C" bool NikoMacBackgroundEnvironment(void) {
    @autoreleasepool {
        if (geteuid() == 0 || ![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"io.nikodesk.macos"])
            return false;
        uid_t console = 0;
        CFStringRef name = SCDynamicStoreCopyConsoleUser(nullptr, &console, nullptr);
        if (!name) return false;
        const bool active = console != 0 && console == geteuid()
            && !CFEqual(name, CFSTR("loginwindow"));
        CFRelease(name);
        return active;
    }
}
extern "C" void NikoMacBackgroundRunLoop(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
}
