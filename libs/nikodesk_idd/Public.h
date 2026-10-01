#pragma once
#include <cstdint>
#include <cstddef>

// NikoDesk owns the hardware/interface identity and this versioned ABI.
// Every software-device instance exposes exactly one screen. The application
// retains its exclusive handle and SwDeviceLifetimeHandle until cleanup.
constexpr std::uint32_t NIKO_IDD_MAGIC = 0x44564b4e;
constexpr std::uint32_t NIKO_IDD_PROTOCOL = 1;
constexpr std::uint32_t NikoIoctl(std::uint32_t function) {
    return (0x8337u << 16) | (3u << 14) | (function << 2);
}
constexpr auto IOCTL_NIKO_QUERY = NikoIoctl(0x800);
constexpr auto IOCTL_NIKO_PLUG_IN = NikoIoctl(0x801);
constexpr auto IOCTL_NIKO_PLUG_OUT = NikoIoctl(0x802);

struct CtlQuery {
    std::uint32_t Magic, Protocol, MaxMonitors, ModeFlags, Ready;
};
struct CtlPlugIn {
    std::uint32_t Protocol, ConnectorIndex;
    std::uint8_t ContainerId[16];
};
struct CtlPlugOut { std::uint32_t Protocol, ConnectorIndex; };

inline bool NikoValidPlugIn(const CtlPlugIn& input) {
    std::uint8_t any = 0;
    for (auto value : input.ContainerId) any |= value;
    return input.Protocol == NIKO_IDD_PROTOCOL && input.ConnectorIndex == 0 && any != 0;
}
inline bool NikoValidPlugOut(const CtlPlugOut& input) {
    return input.Protocol == NIKO_IDD_PROTOCOL && input.ConnectorIndex == 0;
}
static_assert(sizeof(CtlQuery) == 20 && sizeof(CtlPlugIn) == 24 && sizeof(CtlPlugOut) == 8,
    "NikoDesk IOCTL ABI changed");
static_assert(offsetof(CtlPlugIn, ContainerId) == 8, "NikoDesk container ABI changed");
