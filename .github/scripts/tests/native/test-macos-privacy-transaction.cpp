#include "macos_privacy_transaction.h"
#include <cassert>
#include <iostream>
#include <limits>

using namespace nikodesk_privacy;

static GammaTable normal(float high = 1.0f) {
    return {0.0f, high, 0.0f, high, 0.0f, high};
}

struct Displays {
    std::map<std::string, GammaTable> tables{{"a", normal()}, {"b", normal(0.8f)}};
    std::set<std::string> unreadable;
    std::set<size_t> failing_writes;
    std::set<size_t> ineffective_writes;
    size_t writes = 0;

    GammaReader reader() {
        return [this](const std::string& uuid, GammaTable& table) {
            if (unreadable.count(uuid) || !tables.count(uuid)) return false;
            table = tables.at(uuid);
            return true;
        };
    }
    GammaWriter writer() {
        return [this](const std::string& uuid, const GammaTable& table) {
            ++writes;
            if (ineffective_writes.count(writes)) return true;
            if (failing_writes.count(writes)) {
                // Simulate a native failure after a partial mutation.
                tables.at(uuid) = table;
                tables.at(uuid)[0] = 0.4f;
                return false;
            }
            tables.at(uuid) = table;
            return true;
        };
    }
};

static void all_displays_and_owned_restore() {
    Displays d;
    const auto initial = d.tables;
    GammaSession session;
    assert(session.start({"a", "b"}, d.reader(), d.writer()));
    assert(session.touched_count() == 2 && is_black(d.tables.at("a")) && is_black(d.tables.at("b")));
    d.tables.emplace("unrelated", normal(0.6f));
    assert(session.restore(d.reader(), d.writer()));
    assert(d.tables.at("a") == initial.at("a") && d.tables.at("b") == initial.at("b"));
    assert(d.tables.at("unrelated") == normal(0.6f));
}

static void mixed_unsupported_display_changes_nothing() {
    Displays d;
    d.tables.at("b").clear();
    const auto initial = d.tables;
    GammaSession session;
    assert(!session.start({"a", "b"}, d.reader(), d.writer()));
    assert(d.writes == 0 && d.tables == initial && !session.has_pending_restore());
}

static void unreadable_display_changes_nothing() {
    Displays d;
    d.unreadable.insert("b");
    GammaSession session;
    assert(!session.start({"a", "b"}, d.reader(), d.writer()));
    assert(d.writes == 0 && !session.has_pending_restore());
}

static void partial_write_failure_rolls_back_every_touch() {
    Displays d;
    const auto initial = d.tables;
    d.failing_writes.insert(2);
    GammaSession session;
    assert(!session.start({"a", "b"}, d.reader(), d.writer()));
    assert(d.tables == initial && !session.has_pending_restore() && d.writes == 4);
}

static void write_success_requires_black_readback() {
    Displays d;
    const auto initial = d.tables;
    d.ineffective_writes.insert(2);
    GammaSession session;
    assert(!session.start({"a", "b"}, d.reader(), d.writer()));
    assert(d.tables == initial && !session.has_pending_restore());
}

static void failed_restore_keeps_backup_for_retry() {
    Displays d;
    const auto initial = d.tables;
    GammaSession session;
    assert(session.start({"a"}, d.reader(), d.writer()));
    d.ineffective_writes.insert(2);
    assert(!session.restore(d.reader(), d.writer()) && session.has_pending_restore());
    const size_t before = d.writes;
    assert(!session.start({"b"}, d.reader(), d.writer()) && d.writes == before);
    assert(session.restore(d.reader(), d.writer()));
    assert(d.tables == initial && !session.has_pending_restore());
}

static void external_gamma_is_not_overwritten() {
    Displays d;
    GammaSession session;
    assert(session.start({"a"}, d.reader(), d.writer()));
    const GammaTable external = normal(0.3f);
    d.tables.at("a") = external;
    const size_t before = d.writes;
    assert(!session.restore(d.reader(), d.writer()));
    assert(d.writes == before && d.tables.at("a") == external);
}

static void partial_restore_failure_remains_retryable() {
    Displays d;
    const auto initial = d.tables;
    GammaSession session;
    assert(session.start({"a"}, d.reader(), d.writer()));
    d.failing_writes.insert(2);
    assert(!session.restore(d.reader(), d.writer()) && session.has_pending_restore());
    assert(session.restore(d.reader(), d.writer()));
    assert(d.tables == initial && !session.has_pending_restore());
}

static void unsupported_hotplug_causes_failure_and_owned_cleanup() {
    Displays d;
    const auto initial = d.tables;
    GammaSession session;
    assert(session.start({"a"}, d.reader(), d.writer()));
    d.tables.emplace("new", GammaTable{});
    assert(!session.enforce_all({"a", "new"}, d.reader(), d.writer()));
    assert(session.restore(d.reader(), d.writer()));
    assert(d.tables.at("a") == initial.at("a") && d.tables.at("new").empty());
}

static void successful_hotplug_joins_owned_restore() {
    Displays d;
    GammaSession session;
    assert(session.start({"a"}, d.reader(), d.writer()));
    const GammaTable hotplug = normal(0.6f);
    d.tables.emplace("new", hotplug);
    assert(session.enforce_all({"a", "new"}, d.reader(), d.writer()));
    assert(session.touched_count() == 2 && is_black(d.tables.at("new")));
    assert(session.restore(d.reader(), d.writer()));
    assert(d.tables.at("new") == hotplug);
}

static void detached_display_retains_backup_until_return() {
    Displays d;
    const GammaTable initial = d.tables.at("a");
    GammaSession session;
    assert(session.start({"a"}, d.reader(), d.writer()));
    const GammaTable black = d.tables.at("a");
    d.tables.erase("a");
    assert(!session.restore(d.reader(), d.writer()) && session.has_pending_restore());
    d.tables.emplace("a", black);
    assert(session.restore(d.reader(), d.writer()) && !session.has_pending_restore());
    assert(d.tables.at("a") == initial);
}

static void invalid_identity_and_preexisting_black_are_rejected() {
    Displays d;
    GammaSession session;
    assert(!session.start({}, d.reader(), d.writer()));
    assert(!session.start({""}, d.reader(), d.writer()));
    assert(!session.start({"a", "a"}, d.reader(), d.writer()));
    d.tables.at("a") = GammaTable(6, 0.0f);
    assert(!session.start({"a", "b"}, d.reader(), d.writer()));
    assert(d.writes == 0);
}

static void malformed_and_nonfinite_gamma_are_rejected() {
    assert(!valid_table({}) && !valid_table({0.0f, 1.0f}));
    assert(!valid_table({0.0f, 1.0f, std::numeric_limits<float>::quiet_NaN()}));
    assert(!valid_table({0.0f, 1.0f, std::numeric_limits<float>::infinity()}));
    assert(!is_black({}) && !equal_tables({}, {}));
}

static void validation_does_not_repaint_external_gamma() {
    Displays d;
    GammaSession session;
    assert(session.start({"a", "b"}, d.reader(), d.writer()));
    const size_t before = d.writes;
    assert(session.verify_all({"a", "b"}, d.reader()));
    const GammaTable external = normal(0.3f);
    d.tables.at("a") = external;
    assert(!session.verify_all({"a", "b"}, d.reader()));
    assert(d.writes == before && d.tables.at("a") == external);
    assert(!session.restore(d.reader(), d.writer()));
    assert(d.tables.at("a") == external && d.tables.at("b") == normal(0.8f));
}

static void validation_rejects_missing_unknown_and_invalid_displays() {
    Displays d;
    GammaSession session;
    assert(session.start({"a"}, d.reader(), d.writer()));
    assert(!session.verify_all({}, d.reader()));
    assert(!session.verify_all({""}, d.reader()));
    assert(!session.verify_all({"a", "a"}, d.reader()));
    assert(!session.verify_all({"a", "b"}, d.reader()));
    d.tables.at("b") = GammaTable(6, 0.0f);
    assert(!session.verify_all({"a", "b"}, d.reader()));
    d.unreadable.insert("a");
    assert(!session.verify_all({"a"}, d.reader()));
    d.unreadable.clear();
    d.tables.at("a") = {0, 0};
    assert(!session.verify_all({"a"}, d.reader()));
}

static void validation_tracks_restore_and_hotplug_ownership() {
    Displays d;
    GammaSession session;
    assert(!session.verify_all({"a"}, d.reader()));
    assert(session.start({"a"}, d.reader(), d.writer()));
    assert(session.enforce_all({"a", "b"}, d.reader(), d.writer()));
    assert(session.verify_all({"a", "b"}, d.reader()));
    assert(session.verify_all({"b"}, d.reader()));
    assert(session.restore(d.reader(), d.writer()));
    d.tables.at("a") = GammaTable(6, 0.0f);
    assert(!session.verify_all({"a"}, d.reader()));
}

static void emergency_shortcut_requires_local_physical_input() {
    const EmergencyReleaseKey local{true, false, true, true, true, true, true, false};
    assert(is_emergency_release(local));
    auto remote = local;
    remote.remote = true;
    assert(!is_emergency_release(remote));
    auto synthetic = local;
    synthetic.physical = false;
    assert(!is_emergency_release(synthetic));
    auto key_up = local;
    key_up.key_down = false;
    assert(!is_emergency_release(key_up));
    auto other_key = local;
    other_key.escape = false;
    assert(!is_emergency_release(other_key));
    auto command = local;
    command.command = true;
    assert(!is_emergency_release(command));
    // Every modifier subset except the complete shortcut is rejected.
    for (unsigned mask = 0; mask < 8; ++mask) {
        auto key = local;
        key.control = mask & 1;
        key.option = mask & 2;
        key.shift = mask & 4;
        assert(is_emergency_release(key) == (mask == 7));
    }
}

int main() {
    all_displays_and_owned_restore();
    mixed_unsupported_display_changes_nothing();
    unreadable_display_changes_nothing();
    partial_write_failure_rolls_back_every_touch();
    write_success_requires_black_readback();
    failed_restore_keeps_backup_for_retry();
    external_gamma_is_not_overwritten();
    partial_restore_failure_remains_retryable();
    unsupported_hotplug_causes_failure_and_owned_cleanup();
    successful_hotplug_joins_owned_restore();
    detached_display_retains_backup_until_return();
    invalid_identity_and_preexisting_black_are_rejected();
    malformed_and_nonfinite_gamma_are_rejected();
    validation_does_not_repaint_external_gamma();
    validation_rejects_missing_unknown_and_invalid_displays();
    validation_tracks_restore_and_hotplug_ownership();
    emergency_shortcut_requires_local_physical_input();
    std::cout << "17 privacy transaction tests passed; no macOS APIs called\n";
}
