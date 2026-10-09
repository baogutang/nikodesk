// Exercise the production bridge callbacks with an in-memory display/input/
// helper provider. This executable never starts the application or a watchdog,
// creates an event tap, or reads/writes a physical display's gamma table.
#import <AppKit/AppKit.h>
#include "macos_privacy_gamma.h"
#include "macos_privacy_watchdog_client.h"
#include <cassert>
#include <deque>
#include <iostream>

namespace fixture {
using nikodesk_privacy::GammaTable;
std::map<std::string, GammaTable> tables;
std::vector<std::string> online;
bool input_enabled = true;
size_t reads = 0, writes = 0, stops = 0;
struct Pending { dispatch_time_t delay; dispatch_block_t block; };
std::deque<Pending> pending;
const GammaTable normal{0, 1, 0, 1, 0, 1};
dispatch_time_t time(dispatch_time_t, int64_t delay) { return delay; }
void after(dispatch_time_t delay, dispatch_queue_t, dispatch_block_t block) {
    pending.push_back({delay, [block copy]});
}
bool input_active(CFMachPortRef) { return input_enabled; }
void input_enable(CFMachPortRef, bool enabled) { input_enabled = enabled; }
void release(CFTypeRef) {}
CGError remove_callback(CGDisplayReconfigurationCallBack, void*) { return kCGErrorSuccess; }
void tick() {
    assert(!pending.empty());
    Pending next = pending.front();
    pending.pop_front();
    next.block();
}
} // namespace fixture

namespace nikodesk_privacy::test_gamma {
bool displays(std::vector<std::string>& ids) { ids = fixture::online; return !ids.empty(); }
bool read(const std::string& uuid, GammaTable& result) {
    ++fixture::reads;
    auto it = fixture::tables.find(uuid);
    if (it == fixture::tables.end()) return false;
    result = it->second;
    return true;
}
} // namespace nikodesk_privacy::test_gamma

namespace nikodesk_privacy::test_watchdog {
struct Client {
    bool start() { assert(false && "test never starts a native session"); return false; }
    bool prepare(const std::map<std::string, GammaTable>&) { return true; }
    bool write(const std::string& uuid, const GammaTable& value) {
        ++fixture::writes;
        fixture::tables.at(uuid) = value;
        return true;
    }
    bool heartbeat() { return true; }
    bool stop() { ++fixture::stops; return true; }
};
} // namespace nikodesk_privacy::test_watchdog

// Dependency headers were already included, so substitutions affect only the
// production bridge below. No test-provider switch enters the product build.
#define gamma test_gamma
#define watchdog test_watchdog
#define dispatch_time fixture::time
#define dispatch_after fixture::after
#define CGEventTapIsEnabled fixture::input_active
#define CGEventTapEnable fixture::input_enable
#define CGDisplayRemoveReconfigurationCallback fixture::remove_callback
#define CFRelease fixture::release
#include "macos_privacy_bridge.h"
#undef gamma
#undef watchdog
#undef dispatch_time
#undef dispatch_after
#undef CGEventTapIsEnabled
#undef CGEventTapEnable
#undef CGDisplayRemoveReconfigurationCallback
#undef CFRelease

static void start_fixture() {
    fixture::pending.clear();
    fixture::tables = {{"a", fixture::normal}, {"b", fixture::normal}};
    fixture::online = {"a", "b"};
    fixture::reads = fixture::writes = fixture::stops = 0;
    fixture::input_enabled = true;
    nikoPrivacyGammas = nikodesk_privacy::GammaSession{};
    nikoPrivacyCallbackRegistered = false;
    nikoStyledPrivacyInput=false;nikoStyledPrivacyHelper=0;nikoStyledUnlockRequested=false;
    nikoPrivacyRunLoopSource = nullptr;
    nikoPrivacyEventTap = reinterpret_cast<CFMachPortRef>(1);
    ++nikoPrivacySessionToken;
    ++nikoPrivacyMonitorToken;
    assert(nikoPrivacyGammas.start(fixture::online, NikoPrivacyReadGamma, NikoPrivacyWriteGamma));
    nikoPrivacyActive = true;
}

static void continues_past_initial_window_without_repainting() {
    start_fixture();
    const size_t writes = fixture::writes;
    NikoPrivacyMonitor(nikoPrivacyMonitorToken, std::chrono::steady_clock::now());
    // The deadline has passed before the first callback. The old bridge stopped
    // after that callback; the fixed bridge keeps scheduling low-frequency checks.
    for (unsigned i = 0; i < 20; ++i) {
        assert(fixture::pending.size() == 1);
        fixture::tick();
    }
    assert(fixture::pending.size() == 1);
    assert(fixture::pending.front().delay == 1000 * NSEC_PER_MSEC);
    assert(nikoPrivacyActive && fixture::writes == writes);
    assert(fixture::reads >= 40);
}

static void late_external_gamma_change_releases_without_overwrite() {
    start_fixture();
    NikoPrivacyMonitor(nikoPrivacyMonitorToken, std::chrono::steady_clock::now());
    for (unsigned i = 0; i < 6; ++i) fixture::tick();
    const nikodesk_privacy::GammaTable external{0, .4f, 0, .4f, 0, .4f};
    fixture::tables["a"] = external;
    fixture::tick();
    assert(!nikoPrivacyActive && !fixture::input_enabled && fixture::stops == 1);
    assert(fixture::tables.at("a") == external);
    assert(fixture::tables.at("b") == fixture::normal);
    assert(nikoPrivacyGammas.has_pending_restore());
    assert(fixture::pending.empty());
}

static void disabled_input_filter_releases_the_mode() {
    start_fixture();
    NikoPrivacyStartMonitor();
    assert(fixture::pending.front().delay == 200 * NSEC_PER_MSEC);
    fixture::input_enabled = false;
    fixture::tick();
    assert(!nikoPrivacyActive && fixture::stops == 1 && fixture::pending.empty());
    assert(fixture::tables.at("a") == fixture::normal);
}

static void local_off_cancels_pending_checks_and_does_not_redarken() {
    start_fixture();
    NikoPrivacyStartMonitor();
    assert(NikoPrivacyTurnOff());
    const size_t writes = fixture::writes;
    fixture::tick();
    assert(!nikoPrivacyActive && fixture::pending.empty() && fixture::writes == writes);
    assert(fixture::tables.at("a") == fixture::normal);
}

static void stale_monitor_cannot_stop_a_new_session() {
    start_fixture();
    NikoPrivacyStartMonitor();
    ++nikoPrivacyMonitorToken;
    const size_t reads = fixture::reads;
    fixture::tick();
    assert(nikoPrivacyActive && fixture::pending.empty() && fixture::reads == reads);
}

static void hotplug_without_callback_never_reports_protected() {
    start_fixture();
    NikoPrivacyStartMonitor();
    fixture::tables["new"] = fixture::normal;
    fixture::online.push_back("new");
    fixture::tick();
    assert(!nikoPrivacyActive && fixture::pending.empty());
    assert(fixture::tables.at("new") == fixture::normal);
}

static void styled_shortcut_requests_password_without_releasing_cover() {
    start_fixture();nikoStyledPrivacyInput=true;nikoStyledPrivacyHelper=77;
    CGEventRef event=CGEventCreateKeyboardEvent(nullptr,53,true);
    CGEventSetIntegerValueField(event,kCGEventSourceStateID,kCGEventSourceStateHIDSystemState);
    CGEventSetFlags(event,kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskShift);
    assert(NikoPrivacyInputCallback(nullptr,kCGEventKeyDown,event,nullptr)==nullptr);
    assert(nikoStyledUnlockRequested && nikoStyledPrivacyInput && nikoPrivacyActive && fixture::input_enabled);
    ::CFRelease(event);
}
static void password_input_stays_scoped_to_the_excluded_helper() {
    start_fixture();nikoStyledPrivacyInput=true;nikoStyledPrivacyHelper=77;
    CGEventRef event=CGEventCreateKeyboardEvent(nullptr,0,true);
    CGEventSetIntegerValueField(event,kCGEventSourceStateID,kCGEventSourceStateHIDSystemState);
    CGEventSetIntegerValueField(event,kCGEventTargetUnixProcessID,77);
    assert(NikoPrivacyInputCallback(nullptr,kCGEventKeyDown,event,nullptr)==event);
    CGEventSetIntegerValueField(event,kCGEventTargetUnixProcessID,88);
    assert(NikoPrivacyInputCallback(nullptr,kCGEventKeyDown,event,nullptr)==nullptr);
    ::CFRelease(event);
}
int main() {
    @autoreleasepool {
        continues_past_initial_window_without_repainting();
        late_external_gamma_change_releases_without_overwrite();
        disabled_input_filter_releases_the_mode();
        local_off_cancels_pending_checks_and_does_not_redarken();
        stale_monitor_cannot_stop_a_new_session();
        hotplug_without_callback_never_reports_protected();
        styled_shortcut_requests_password_without_releasing_cover();
        password_input_stays_scoped_to_the_excluded_helper();
    }
    std::cout << "8 production privacy monitor/input callback tests passed; simulated providers only\n";
}
