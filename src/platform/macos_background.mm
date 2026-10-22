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
// LaunchServices treats the agent as a running instance of the bundle, so
// opening NikoDesk from Finder, the Dock or Spotlight reopens the agent rather
// than starting the window app.
@interface NikoBackgroundDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) void (*reopen)(void);
@end
@implementation NikoBackgroundDelegate
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    self.reopen();
    return NO;
}
@end

static NikoBackgroundDelegate *backgroundDelegate;

extern "C" void NikoMacBackgroundRunLoop(void (*reopen)(void)) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        backgroundDelegate = [NikoBackgroundDelegate new];
        backgroundDelegate.reopen = reopen;
        application.delegate = backgroundDelegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
}
