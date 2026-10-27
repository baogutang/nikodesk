// Counts display reconfigurations and screen lock changes as the window
// server reports them, so the video service can follow a change at once
// instead of at its next periodic display check. Both sources deliver on the
// main run loop; in a process that does not run one the counters stay put
// and the periodic check remains the only path. It also reads the lock state
// on demand and asks loginwindow to lock (src/nikodesk/screen_lock.rs).
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <dlfcn.h>
#include <initializer_list>

namespace {
std::atomic<uint64_t> gDisplayGeneration{0};
std::atomic<uint64_t> gLockGeneration{0};
// -1 unknown, 0 unlocked, 1 locked.
std::atomic<int> gLocked{-1};
std::atomic<bool> gStarted{false};
std::atomic<bool> gRegistered{false};

void Reconfigured(CGDirectDisplayID, CGDisplayChangeSummaryFlags flags, void *) {
    // Each change arrives twice: before (begin flag) and after. Only the
    // second one describes the new arrangement.
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    gDisplayGeneration.fetch_add(1, std::memory_order_acq_rel);
}

void LockChanged(CFNotificationCenterRef, void *, CFNotificationName name, const void *, CFDictionaryRef) {
    gLocked.store(CFEqual(name, CFSTR("com.apple.screenIsLocked")) ? 1 : 0, std::memory_order_release);
    gLockGeneration.fetch_add(1, std::memory_order_acq_rel);
}

// The session dictionary has the key only while the screen is locked; no
// session at all means the login window.
int SessionLocked() {
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return 1;
    CFTypeRef value = CFDictionaryGetValue(session, CFSTR("CGSSessionScreenIsLocked"));
    int locked = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
    CFRelease(session);
    return locked;
}
}  // namespace

extern "C" void NikoDisplayEventsStart() {
    bool expected = false;
    if (!gStarted.compare_exchange_strong(expected, true)) return;
    gLocked.store(SessionLocked(), std::memory_order_release);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (CGDisplayRegisterReconfigurationCallback(Reconfigured, nullptr) != kCGErrorSuccess) return;
        CFNotificationCenterRef center = CFNotificationCenterGetDistributedCenter();
        for (CFStringRef name : {CFSTR("com.apple.screenIsLocked"), CFSTR("com.apple.screenIsUnlocked")}) {
            CFNotificationCenterAddObserver(center, &gStarted, LockChanged, name, nullptr,
                CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        gRegistered.store(true, std::memory_order_release);
    });
}

extern "C" bool NikoDisplayEventsRegistered() { return gRegistered.load(std::memory_order_acquire); }
extern "C" uint64_t NikoDisplayEventsGeneration() { return gDisplayGeneration.load(std::memory_order_acquire); }
extern "C" uint64_t NikoLockEventsGeneration() { return gLockGeneration.load(std::memory_order_acquire); }
extern "C" int NikoScreenLockedState() { return gLocked.load(std::memory_order_acquire); }

// A fresh reading, for a caller that cannot wait for the notification.
extern "C" int NikoScreenLockedNow() { return SessionLocked(); }

// loginwindow's immediate lock, the one behind the Apple menu's Lock Screen.
// The function is private, so it is looked up at run time; -1 when missing.
extern "C" int NikoLockScreenImmediate() {
    static int (*lock)() = [] {
        void *login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY);
        return login ? (int (*)())dlsym(login, "SACLockScreenImmediate") : nullptr;
    }();
    return lock ? lock() : -1;
}
