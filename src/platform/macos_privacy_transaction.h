#pragma once

// Pure state and gamma-table transactions. This file does not call macOS APIs.
#include <cmath>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace nikodesk_privacy {

using GammaTable = std::vector<float>;
using GammaReader = std::function<bool(const std::string&, GammaTable&)>;
using GammaWriter = std::function<bool(const std::string&, const GammaTable&)>;
using GammaCheckpoint = std::function<bool(const std::map<std::string, GammaTable>&)>;

struct EmergencyReleaseKey {
    bool physical;
    bool remote;
    bool key_down;
    bool escape;
    bool control;
    bool option;
    bool shift;
    bool command;
};

// Local emergency exit: Control + Option + Shift + Escape. A remote marker,
// synthetic source, key-up, or extra Command modifier must not trigger it.
inline bool is_emergency_release(const EmergencyReleaseKey& key) {
    return key.physical && !key.remote && key.key_down && key.escape &&
           key.control && key.option && key.shift && !key.command;
}

inline bool valid_table(const GammaTable& table) {
    if (table.empty() || table.size() % 3 != 0 || table.size() / 3 > 65536) {
        return false;
    }
    for (float value : table) {
        if (!std::isfinite(value)) return false;
    }
    return true;
}

inline bool is_black(const GammaTable& table) {
    if (!valid_table(table)) return false;
    for (float value : table) {
        if (std::fabs(value) > 0.01f) return false;
    }
    return true;
}

inline bool equal_tables(const GammaTable& a, const GammaTable& b) {
    if (!valid_table(a) || !valid_table(b) || a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (std::fabs(a[i] - b[i]) > 0.001f) return false;
    }
    return true;
}

class GammaSession {
public:
    bool has_pending_restore() const { return !touched_.empty(); }
    size_t touched_count() const { return touched_.size(); }

    bool start(const std::vector<std::string>& displays,
               const GammaReader& read, const GammaWriter& write, const GammaCheckpoint& checkpoint = {}) {
        // A failed restore is never silently discarded by starting another mode.
        if (has_pending_restore()) return false;
        originals_.clear();
        if (!enforce_all(displays, read, write, checkpoint)) {
            restore(read, write);
            return false;
        }
        return true;
    }

    bool enforce_all(const std::vector<std::string>& displays,
                     const GammaReader& read, const GammaWriter& write, const GammaCheckpoint& checkpoint = {}) {
        if (displays.empty()) return false;
        std::set<std::string> unique;
        std::map<std::string, GammaTable> current;
        std::map<std::string, GammaTable> additions;
        // Capture and validate every display before changing any new display.
        for (const auto& uuid : displays) {
            if (uuid.empty() || !unique.insert(uuid).second) return false;
            GammaTable table;
            if (!read(uuid, table) || !valid_table(table)) return false;
            if (!originals_.count(uuid)) {
                // An already black display could belong to another application.
                if (is_black(table)) return false;
                additions.emplace(uuid, table);
            }
            current.emplace(uuid, std::move(table));
        }
        auto snapshot = originals_;
        snapshot.insert(additions.begin(), additions.end());
        if (checkpoint && !checkpoint(snapshot)) return false;
        originals_.insert(additions.begin(), additions.end());
        for (const auto& uuid : displays) {
            if (touched_.count(uuid) && is_black(current.at(uuid))) continue;
            const GammaTable black(originals_.at(uuid).size(), 0.0f);
            touched_.insert(uuid);
            // A failing native write may have partially changed the table.
            uncertain_.insert(uuid);
            if (!write(uuid, black)) return false;
            GammaTable observed;
            if (!read(uuid, observed) || !is_black(observed)) return false;
            uncertain_.erase(uuid);
        }
        return true;
    }

    bool restore(const GammaReader& read, const GammaWriter& write) {
        bool success = true;
        for (auto it = touched_.begin(); it != touched_.end();) {
            const auto& uuid = *it;
            const auto& original = originals_.at(uuid);
            GammaTable current;
            if (!read(uuid, current) || !valid_table(current)) {
                success = false;
                ++it;
                continue;
            }
            bool restored = equal_tables(current, original);
            if (!restored) {
                // Ordinary shutdown does not overwrite another application's
                // non-black gamma update. An incomplete write of our own is
                // rolled back to its saved table instead.
                if (!uncertain_.count(uuid) && !is_black(current)) {
                    success = false;
                    ++it;
                    continue;
                }
                GammaTable observed;
                uncertain_.insert(uuid);
                restored = write(uuid, original) && read(uuid, observed) &&
                           equal_tables(observed, original);
            }
            if (restored) {
                uncertain_.erase(uuid);
                originals_.erase(uuid);
                it = touched_.erase(it);
            } else {
                success = false;
                ++it;
            }
        }
        // A display whose table was only read needs no restoration.
        for (auto it = originals_.begin(); it != originals_.end();) {
            if (!touched_.count(it->first)) it = originals_.erase(it);
            else ++it;
        }
        return success && !has_pending_restore();
    }

private:
    std::map<std::string, GammaTable> originals_;
    std::set<std::string> touched_;
    std::set<std::string> uncertain_;
};

} // namespace nikodesk_privacy
