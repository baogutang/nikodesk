#pragma once
#include "macos_privacy_transaction.h"
#include <array>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace nikodesk_privacy::watchdog {
constexpr uint32_t protocol_version = 1;
constexpr size_t max_frame = 128 * 1024 * 1024;
constexpr size_t max_journal = 256 * 1024 * 1024;
constexpr uint32_t max_displays = 128;
constexpr auto lease = std::chrono::seconds(2);
using Bytes = std::vector<uint8_t>;
using Nonce = std::array<uint8_t, 16>;
using Snapshot = std::map<std::string, GammaTable>;
enum class Op : uint32_t { ready = 1, snapshot, write, heartbeat, stop, ack, reject };
enum class Receive { ok, timeout, closed, invalid };

inline void integer(Bytes& b, uint32_t v) {
    for (unsigned i = 0; i < 4; ++i) b.push_back(static_cast<uint8_t>(v >> (i * 8)));
}
inline bool integer(const Bytes& b, size_t& at, uint32_t& v) {
    if (at + 4 > b.size()) return false;
    v = 0;
    for (unsigned i = 0; i < 4; ++i) v |= uint32_t(b[at++]) << (i * 8);
    return true;
}
inline void text(Bytes& b, const std::string& s) {
    integer(b, static_cast<uint32_t>(s.size()));
    b.insert(b.end(), s.begin(), s.end());
}
inline bool text(const Bytes& b, size_t& at, std::string& s) {
    uint32_t count = 0;
    if (!integer(b, at, count) || count == 0 || count > 128 || at + count > b.size()) return false;
    s.assign(reinterpret_cast<const char*>(b.data() + at), count);
    at += count;
    return s.find('\0') == std::string::npos;
}
inline void table(Bytes& b, const GammaTable& t) {
    integer(b, static_cast<uint32_t>(t.size()));
    for (float f : t) {
        uint32_t bits;
        std::memcpy(&bits, &f, sizeof(bits));
        integer(b, bits);
    }
}
inline bool table(const Bytes& b, size_t& at, GammaTable& t) {
    uint32_t count = 0;
    if (!integer(b, at, count) || count == 0 || count > 3 * 65536 || count % 3 || at + size_t(count) * 4 > b.size()) return false;
    t.resize(count);
    for (float& f : t) {
        uint32_t bits = 0;
        if (!integer(b, at, bits)) return false;
        std::memcpy(&f, &bits, sizeof(f));
    }
    return valid_table(t);
}
inline Bytes snapshot(const Snapshot& values) {
    Bytes b;
    integer(b, static_cast<uint32_t>(values.size()));
    for (const auto& item : values) { text(b, item.first); table(b, item.second); }
    return b;
}
inline bool snapshot(const Bytes& b, Snapshot& values) {
    uint32_t count = 0;
    size_t at = 0;
    if (!integer(b, at, count) || count == 0 || count > max_displays || b.size() > max_frame) return false;
    Snapshot incoming;
    for (uint32_t i = 0; i < count; ++i) {
        std::string uuid;
        GammaTable original;
        if (!text(b, at, uuid) || !table(b, at, original) || !incoming.emplace(uuid, original).second) return false;
    }
    if (at != b.size()) return false;
    values = std::move(incoming);
    return true;
}

inline bool transfer(int fd, uint8_t* data, size_t count, bool sending,
                     std::chrono::steady_clock::time_point deadline) {
    size_t at = 0;
    while (at < count) {
        auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
        if (left <= 0) return false;
        pollfd p{fd, static_cast<short>(sending ? POLLOUT : POLLIN), 0};
        int result = poll(&p, 1, static_cast<int>(std::min<int64_t>(left, 500)));
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || p.revents & POLLNVAL) return false;
        if (!result) continue;
        ssize_t size = sending ? send(fd, data + at, count - at, MSG_DONTWAIT) : recv(fd, data + at, count - at, MSG_DONTWAIT);
        if (size < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (size <= 0) return false;
        at += static_cast<size_t>(size);
    }
    return true;
}
inline bool send_frame(int fd, Op op, const Nonce& nonce, uint32_t sequence, const Bytes& body = {}) {
    if (body.size() > max_frame) return false;
    Bytes frame{'N','K','W','A','T','C','H','1'};
    integer(frame, protocol_version); integer(frame, static_cast<uint32_t>(op));
    frame.insert(frame.end(), nonce.begin(), nonce.end());
    integer(frame, sequence); integer(frame, static_cast<uint32_t>(body.size()));
    frame.insert(frame.end(), body.begin(), body.end());
    return transfer(fd, frame.data(), frame.size(), true, std::chrono::steady_clock::now() + lease);
}
inline Receive receive_frame(int fd, Op& op, const Nonce& nonce, uint32_t& sequence, Bytes& body,
                             std::chrono::steady_clock::time_point deadline) {
    pollfd p{fd, POLLIN, 0};
    auto wait = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
    if (wait <= 0) return Receive::timeout;
    int result = poll(&p, 1, static_cast<int>(std::min<int64_t>(wait, 500)));
    if (result < 0 && errno == EINTR) return Receive::timeout;
    if (result < 0 || p.revents & POLLNVAL) return Receive::invalid;
    if (!result) return Receive::timeout;
    Bytes header(40);
    if (!transfer(fd, header.data(), header.size(), false, deadline)) return Receive::closed;
    if (std::memcmp(header.data(), "NKWATCH1", 8) || !std::equal(nonce.begin(), nonce.end(), header.begin() + 16)) return Receive::invalid;
    size_t at = 8;
    uint32_t version = 0, command = 0, length = 0;
    if (!integer(header, at, version) || version != protocol_version || !integer(header, at, command)) return Receive::invalid;
    at = 32;
    if (!integer(header, at, sequence) || !integer(header, at, length) || length > max_frame) return Receive::invalid;
    op = static_cast<Op>(command);
    body.resize(length);
    if (length && !transfer(fd, body.data(), length, false, deadline)) return Receive::closed;
    return Receive::ok;
}
} // namespace nikodesk_privacy::watchdog
