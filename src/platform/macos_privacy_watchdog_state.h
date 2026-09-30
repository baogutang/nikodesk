#pragma once
#include "macos_privacy_watchdog_protocol.h"

namespace nikodesk_privacy::watchdog {
struct OwnedGamma { GammaTable original; GammaTable expected; bool touched = false; };
class RecoveryState {
public:
    std::map<std::string, OwnedGamma> displays;
    bool prepare(const Snapshot& values, const GammaReader& read) {
        if (values.empty() || values.size() > max_displays) return false;
        for (const auto& item : displays) {
            auto next = values.find(item.first);
            if (next == values.end() || next->second != item.second.original) return false;
        }
        for (const auto& item : values) {
            if (!valid_table(item.second) || is_black(item.second)) return false;
            if (displays.count(item.first)) continue;
            GammaTable current;
            if (!read(item.first, current) || is_black(current) || !equal_tables(current, item.second)) return false;
        }
        for (const auto& item : values) displays.emplace(item.first, OwnedGamma{item.second, {}, false});
        return true;
    }
    bool mutate(const std::string& uuid, const GammaTable& target,
                const GammaReader& read, const GammaWriter& write,
                const std::function<bool()>& persist) {
        auto it = displays.find(uuid);
        if (it == displays.end() || !valid_table(target)) return false;
        auto& state = it->second;
        const GammaTable black(state.original.size(), 0.0f);
        const bool darken = target == black;
        if (!darken && target != state.original) return false;
        GammaTable current;
        if (!read(uuid, current)) return false;
        if (equal_tables(current, target)) {
            if (darken && (!state.touched || current != state.expected)) return false;
            if (!darken) state.touched = false;
            return persist();
        }
        if (state.touched ? current != state.expected : !equal_tables(current, state.original)) return false;
        const OwnedGamma before = state;
        state.touched = true;
        state.expected = target;
        // Persist the intent before the first native mutation. The caller does
        // not ACK a snapshot unless this same journal has already been fsynced.
        if (!persist()) { state = before; return false; }
        const bool written = write(uuid, target);
        GammaTable observed;
        const bool sampled = read(uuid, observed) && valid_table(observed);
        if (sampled) state.expected = observed;
        const bool success = written && sampled && equal_tables(observed, target);
        if (success && !darken) state.touched = false;
        return persist() && success;
    }
    bool recover(const GammaReader& read, const GammaWriter& write, const std::function<bool()>& persist) {
        bool success = true;
        for (auto& item : displays) {
            auto& state = item.second;
            if (!state.touched) continue;
            GammaTable current;
            if (!read(item.first, current)) { success = false; continue; }
            if (equal_tables(current, state.original)) { state.touched = false; continue; }
            // Gamma has no public cross-application owner tag. Match the exact
            // table observed after our write; never use is_black alone as proof.
            if (!is_black(current) || current != state.expected) { success = false; continue; }
            const bool written = write(item.first, state.original);
            GammaTable observed;
            if (read(item.first, observed) && valid_table(observed)) state.expected = observed;
            if (written && equal_tables(observed, state.original)) state.touched = false;
            else success = false;
        }
        return persist() && success;
    }
    bool touched() const {
        for (const auto& item : displays) if (item.second.touched) return true;
        return false;
    }
    Bytes journal(const Nonce& nonce) const {
        Bytes b{'N','K','J','O','U','R','1',0};
        integer(b, protocol_version);
        b.insert(b.end(), nonce.begin(), nonce.end());
        integer(b, static_cast<uint32_t>(displays.size()));
        for (const auto& item : displays) {
            text(b, item.first); integer(b, item.second.touched ? 1 : 0);
            table(b, item.second.original); table(b, item.second.expected);
        }
        return b;
    }
};
} // namespace nikodesk_privacy::watchdog
