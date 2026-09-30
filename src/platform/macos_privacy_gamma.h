#pragma once
#include "macos_privacy_transaction.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ColorSync/ColorSync.h>

namespace nikodesk_privacy::gamma {
inline std::string uuid(CGDirectDisplayID display) {
    CFUUIDRef value = CGDisplayCreateUUIDFromDisplayID(display);
    if (!value) return {};
    CFStringRef text = CFUUIDCreateString(kCFAllocatorDefault, value);
    CFRelease(value);
    if (!text) return {};
    char buffer[128] = {};
    bool ok = CFStringGetCString(text, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(text);
    return ok ? std::string(buffer) : std::string();
}
inline bool displays(std::vector<std::string>& result) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, nullptr, &count) != kCGErrorSuccess || count == 0 || count > 128) return false;
    std::vector<CGDirectDisplayID> ids(count);
    const uint32_t capacity = count;
    if (CGGetOnlineDisplayList(capacity, ids.data(), &count) != kCGErrorSuccess || !count || count > capacity) return false;
    for (uint32_t i = 0; i < count; ++i) {
        std::string id = uuid(ids[i]);
        if (id.empty()) return false;
        result.push_back(std::move(id));
    }
    return true;
}
inline CGDirectDisplayID find(const std::string& id) {
    std::vector<std::string> values;
    if (!displays(values)) return kCGNullDirectDisplay;
    for (const auto& value : values) {
        if (value != id) continue;
        CFStringRef text = CFStringCreateWithCString(kCFAllocatorDefault, id.c_str(), kCFStringEncodingUTF8);
        if (!text) return kCGNullDirectDisplay;
        CFUUIDRef value_uuid = CFUUIDCreateFromString(kCFAllocatorDefault, text);
        CFRelease(text);
        if (!value_uuid) return kCGNullDirectDisplay;
        auto display = CGDisplayGetDisplayIDFromUUID(value_uuid);
        CFRelease(value_uuid);
        return display;
    }
    return kCGNullDirectDisplay;
}
inline bool read(const std::string& id, GammaTable& result) {
    auto display = find(id);
    if (display == kCGNullDirectDisplay) return false;
    uint32_t capacity = CGDisplayGammaTableCapacity(display), count = 0;
    if (!capacity || capacity > 65536) return false;
    std::vector<CGGammaValue> red(capacity), green(capacity), blue(capacity);
    if (CGGetDisplayTransferByTable(display, capacity, red.data(), green.data(), blue.data(), &count) !=
            kCGErrorSuccess || !count || count > capacity) return false;
    result.assign(red.begin(), red.begin() + count);
    result.insert(result.end(), green.begin(), green.begin() + count);
    result.insert(result.end(), blue.begin(), blue.begin() + count);
    return valid_table(result);
}
inline bool write(const std::string& id, const GammaTable& value) {
    auto display = find(id);
    if (display == kCGNullDirectDisplay || !valid_table(value)) return false;
    uint32_t count = static_cast<uint32_t>(value.size() / 3);
    return CGSetDisplayTransferByTable(display, count, value.data(), value.data() + count,
                                      value.data() + count * 2) == kCGErrorSuccess;
}
} // namespace nikodesk_privacy::gamma
