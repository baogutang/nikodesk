#pragma once

#include "macos_privacy_transaction.h"
#include "macos_privacy_gamma.h"
#include "macos_privacy_watchdog_client.h"
#include <chrono>

// NikoDesk-only bridge. All state and event-tap operations run on the main
// queue; callers never hold a native mutex while synchronously waiting for it.
namespace {
nikodesk_privacy::GammaSession nikoPrivacyGammas;
nikodesk_privacy::watchdog::Client nikoPrivacyWatchdog;
CFMachPortRef nikoPrivacyEventTap = nullptr;
CFRunLoopSourceRef nikoPrivacyRunLoopSource = nullptr;
bool nikoPrivacyActive = false;
bool nikoPrivacyCallbackRegistered = false;
uint64_t nikoPrivacyMonitorToken = 0;
uint64_t nikoPrivacySessionToken = 0;
void* nikoPrivacyCallbackContext = nullptr;
constexpr int64_t nikoRemoteInputMarker = 100; // Matches the existing enigo ABI.

bool NikoPrivacyDisplayUUIDs(std::vector<std::string>& uuids) {
    return nikodesk_privacy::gamma::displays(uuids);
}

bool NikoPrivacyReadGamma(const std::string& uuid, nikodesk_privacy::GammaTable& table) {
    return nikodesk_privacy::gamma::read(uuid, table);
}

bool NikoPrivacyWriteGamma(const std::string& uuid, const nikodesk_privacy::GammaTable& table) {
    // Only the independent helper writes gamma. A resumed parent can never
    // darken displays after the helper has revoked an expired session lease.
    return nikoPrivacyWatchdog.write(uuid, table);
}

bool NikoPrivacyCheckpoint(const std::map<std::string, nikodesk_privacy::GammaTable>& originals) {
    return nikoPrivacyWatchdog.prepare(originals);
}

void NikoPrivacyTeardownInput() {
    if (nikoPrivacyEventTap) {
        CGEventTapEnable(nikoPrivacyEventTap, false);
        if (nikoPrivacyRunLoopSource) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), nikoPrivacyRunLoopSource, kCFRunLoopCommonModes);
            CFRelease(nikoPrivacyRunLoopSource);
            nikoPrivacyRunLoopSource = nullptr;
        }
        CFRelease(nikoPrivacyEventTap);
        nikoPrivacyEventTap = nullptr;
    }
}

void NikoPrivacyReconfigured(CGDirectDisplayID, CGDisplayChangeSummaryFlags, void*);

bool NikoPrivacyTurnOff() {
    nikoPrivacyActive = false;
    ++nikoPrivacyMonitorToken;
    ++nikoPrivacySessionToken;
    bool callbackRemoved = true;
    if (nikoPrivacyCallbackRegistered) {
        CGError error = CGDisplayRemoveReconfigurationCallback(NikoPrivacyReconfigured, nikoPrivacyCallbackContext);
        callbackRemoved = error == kCGErrorSuccess;
        if (!callbackRemoved) NSLog(@"Niko privacy callback removal failed: %d", error);
        else nikoPrivacyCallbackRegistered = false;
    }
    NikoPrivacyTeardownInput();
    // Restore only tables this session saved and actually attempted to change.
    // No global ColorSync reset: it would overwrite another application's state.
    bool success = nikoPrivacyGammas.restore(NikoPrivacyReadGamma, NikoPrivacyWriteGamma);
    if (!success) NSLog(@"Niko privacy gamma restore incomplete; saved tables retained for retry");
    bool helperStopped = nikoPrivacyWatchdog.stop();
    return success && callbackRemoved && helperStopped;
}

CGEventRef NikoPrivacyInputCallback(CGEventTapProxy, CGEventType type, CGEventRef event, void* context) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // Losing the input filter invalidates the mode. Defer releasing the tap
        // until the callback has returned, rather than claiming protection.
        uint64_t token = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(context));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token == nikoPrivacySessionToken) NikoPrivacyTurnOff();
        });
        return event;
    }
    bool remote = CGEventGetIntegerValueField(event, kCGEventSourceUserData) == nikoRemoteInputMarker;
    bool physical = CGEventGetIntegerValueField(event, kCGEventSourceStateID) == kCGEventSourceStateHIDSystemState;
    CGEventFlags flags = CGEventGetFlags(event);
    // macOS virtual key code 53 is Escape. This local shortcut is passed on
    // while cleanup is queued, so privacy never consumes its emergency exit.
    nikodesk_privacy::EmergencyReleaseKey emergency{
        physical, remote, type == kCGEventKeyDown,
        CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == 53,
        (flags & kCGEventFlagMaskControl) != 0, (flags & kCGEventFlagMaskAlternate) != 0,
        (flags & kCGEventFlagMaskShift) != 0, (flags & kCGEventFlagMaskCommand) != 0,
    };
    if (nikodesk_privacy::is_emergency_release(emergency)) {
        uint64_t token = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(context));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token == nikoPrivacySessionToken) NikoPrivacyTurnOff();
        });
        return event;
    }
    if (remote) return event;
    if (physical) {
        return nullptr;
    }
    return event;
}

bool NikoPrivacySetupInput() {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) | CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) | CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventScrollWheel);
    // Session tap avoids relying on the documented root-only HID tap location.
    // Creation still requires the user's input/accessibility authorization.
    nikoPrivacyEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, NikoPrivacyInputCallback,
        reinterpret_cast<void*>(static_cast<uintptr_t>(nikoPrivacySessionToken)));
    if (!nikoPrivacyEventTap) return false;
    nikoPrivacyRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, nikoPrivacyEventTap, 0);
    if (!nikoPrivacyRunLoopSource) {
        NikoPrivacyTeardownInput();
        return false;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), nikoPrivacyRunLoopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(nikoPrivacyEventTap, true);
    return CGEventTapIsEnabled(nikoPrivacyEventTap);
}

bool NikoPrivacyEnforceAll() {
    if (!nikoPrivacyEventTap || !CGEventTapIsEnabled(nikoPrivacyEventTap)) return false;
    std::vector<std::string> uuids;
    return NikoPrivacyDisplayUUIDs(uuids) &&
        nikoPrivacyGammas.enforce_all(uuids, NikoPrivacyReadGamma, NikoPrivacyWriteGamma, NikoPrivacyCheckpoint);
}

void NikoPrivacyHeartbeat(uint64_t token) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!nikoPrivacyActive || token != nikoPrivacySessionToken) return;
        if (!nikoPrivacyWatchdog.heartbeat()) {
            NSLog(@"Niko privacy watchdog lease lost; releasing input and owned state");
            NikoPrivacyTurnOff();
            return;
        }
        NikoPrivacyHeartbeat(token);
    });
}

void NikoPrivacyMonitor(uint64_t token, std::chrono::steady_clock::time_point deadline) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!nikoPrivacyActive || token != nikoPrivacyMonitorToken) return;
        if (!NikoPrivacyEnforceAll()) {
            NSLog(@"Niko privacy all-display validation failed; restoring owned displays");
            NikoPrivacyTurnOff();
            return;
        }
        if (std::chrono::steady_clock::now() < deadline) NikoPrivacyMonitor(token, deadline);
    });
}

void NikoPrivacyStartMonitor() {
    uint64_t token = ++nikoPrivacyMonitorToken;
    NikoPrivacyMonitor(token, std::chrono::steady_clock::now() + std::chrono::seconds(5));
}

void NikoPrivacyReconfigured(CGDirectDisplayID, CGDisplayChangeSummaryFlags flags, void* context) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    uint64_t token = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(context));
    // The callback may arrive on another thread. State is inspected only after
    // dispatching to the same queue as turn-on/off and event-tap cleanup.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!nikoPrivacyActive || token != nikoPrivacySessionToken) return;
        if (!NikoPrivacyEnforceAll()) {
            NSLog(@"Niko privacy display reconfiguration unsupported; restoring owned displays");
            NikoPrivacyTurnOff();
            return;
        }
        NikoPrivacyStartMonitor();
    });
}

bool NikoPrivacySetOnMain(bool on) {
    if (!on) return NikoPrivacyTurnOff();
    if (nikoPrivacyActive) {
        if (NikoPrivacyEnforceAll()) return true;
        NikoPrivacyTurnOff();
        return false;
    }
    if ((nikoPrivacyCallbackRegistered || nikoPrivacyGammas.has_pending_restore()) &&
        !NikoPrivacyTurnOff()) return false;
    ++nikoPrivacySessionToken;
    std::vector<std::string> uuids;
    if (!NikoPrivacyDisplayUUIDs(uuids) || !nikoPrivacyWatchdog.start() || !NikoPrivacySetupInput()) {
        NikoPrivacyTeardownInput();
        nikoPrivacyWatchdog.stop();
        return false;
    }
    nikoPrivacyCallbackContext = reinterpret_cast<void*>(static_cast<uintptr_t>(nikoPrivacySessionToken));
    if (CGDisplayRegisterReconfigurationCallback(NikoPrivacyReconfigured, nikoPrivacyCallbackContext) !=
            kCGErrorSuccess) {
        NikoPrivacyTeardownInput();
        nikoPrivacyWatchdog.stop();
        return false;
    }
    nikoPrivacyCallbackRegistered = true;
    if (!nikoPrivacyGammas.start(uuids, NikoPrivacyReadGamma, NikoPrivacyWriteGamma, NikoPrivacyCheckpoint)) {
        NikoPrivacyTurnOff();
        return false;
    }
    nikoPrivacyActive = true;
    NikoPrivacyHeartbeat(nikoPrivacySessionToken);
    NikoPrivacyStartMonitor();
    return true;
}
} // namespace

extern "C" bool MacSetPrivacyMode(bool on) {
    if ([NSThread isMainThread]) return NikoPrivacySetOnMain(on);
    __block bool result = false;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = NikoPrivacySetOnMain(on); });
    return result;
}
