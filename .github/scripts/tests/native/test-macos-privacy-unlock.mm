#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include "macos_privacy_unlock.h"
#include <cassert>
#include <cstdio>

int main() {
    @autoreleasepool {
        NPSUnlockController *empty=[NPSUnlockController new];
        [empty verify:nil];
        assert(!empty.busy && !empty.verified);
        NPSUnlockController *wrong=[NPSUnlockController new];wrong.busy=true;
        [wrong completed:false available:true];
        assert(!wrong.verified && !wrong.busy && wrong.retryAfter>NSProcessInfo.processInfo.systemUptime);
        NPSUnlockController *unavailable=[NPSUnlockController new];
        [unavailable completed:false available:false];assert(!unavailable.verified);
        NPSUnlockController *cancelled=[NPSUnlockController new];cancelled.busy=true;
        [cancelled cancel:nil];[cancelled completed:true available:true];
        assert(!cancelled.verified && !cancelled.busy);
        NPSUnlockController *correct=[NPSUnlockController new];
        [correct completed:true available:true];assert(correct.verified);
    }
    std::puts("5 local privacy exit state checks passed; no system password or physical display used");
    return 0;
}
