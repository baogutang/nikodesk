#include "macos_privacy_watchdog_state.h"
#ifndef NIKODESK_WATCHDOG_TEST_PROVIDER
#include "macos_privacy_gamma.h"
#endif
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <cstdio>
#include <cstdlib>
#include <climits>

using namespace nikodesk_privacy;
using namespace nikodesk_privacy::watchdog;

namespace {
constexpr int channel = 3, directory = 4, report = 5;
#ifdef NIKODESK_WATCHDOG_TEST_PROVIDER
constexpr const char* identity = "nikodesk-privacy-watchdog-v1-test-provider";
std::map<std::string, GammaTable> simulated{{"a", {0,1,0,1,0,1}}, {"b", {0,.8f,0,.8f,0,.8f}}, {"fail", {0,1,0,1,0,1}}};
bool read_gamma(const std::string& id, GammaTable& table) {
    auto it = simulated.find(id);
    if (it == simulated.end()) return false;
    table = it->second;
    return true;
}
bool write_gamma(const std::string& id, const GammaTable& table) {
    dprintf(report, "simulated_write %s black=%d\n", id.c_str(), is_black(table));
    if (id == "fail" && !is_black(table)) return false;
    simulated[id] = table;
    return true;
}
#else
constexpr const char* identity = "nikodesk-privacy-watchdog-v1-production";
bool read_gamma(const std::string& id, GammaTable& table) { return gamma::read(id, table); }
bool write_gamma(const std::string& id, const GammaTable& table) { return gamma::write(id, table); }
#endif

bool valid_inheritance(pid_t parent) {
    if (getuid() == 0 || geteuid() != getuid() || getegid() != getgid() || parent <= 1 || getppid() != parent) return false;
    int kind = 0;
    socklen_t size = sizeof(kind);
    if (getsockopt(channel, SOL_SOCKET, SO_TYPE, &kind, &size) || kind != SOCK_STREAM) return false;
    pid_t peer = 0;
    size = sizeof(peer);
    uid_t uid = 0;
    gid_t gid = 0;
    if (getsockopt(channel, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) || peer != parent ||
            getpeereid(channel, &uid, &gid) || uid != getuid() || gid != getgid()) return false;
    struct stat folder{}, file{};
    return fstat(directory, &folder) == 0 && S_ISDIR(folder.st_mode) && folder.st_uid == getuid() &&
           (folder.st_mode & 0777) == 0700 && fstat(report, &file) == 0 && S_ISREG(file.st_mode) &&
           file.st_uid == getuid() && file.st_nlink == 1 && (file.st_mode & 0777) == 0600;
}

bool persist(const RecoveryState& state, const Nonce& nonce) {
    Bytes data = state.journal(nonce);
    if (data.size() > max_journal) return false;
    int fd = openat(directory, "snapshot.bin.next", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    size_t at = 0;
    bool ok = true;
    while (at < data.size()) {
        ssize_t count = ::write(fd, data.data() + at, data.size() - at);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = false; break; }
        at += static_cast<size_t>(count);
    }
    ok = ok && fsync(fd) == 0;
    close(fd);
    if (!ok) { unlinkat(directory, "snapshot.bin.next", 0); return false; }
    struct stat previous{};
    if (fstatat(directory, "snapshot.bin", &previous, AT_SYMLINK_NOFOLLOW) == 0 &&
            (!S_ISREG(previous.st_mode) || previous.st_uid != getuid() || previous.st_nlink != 1 ||
             (previous.st_mode & 0777) != 0600)) return false;
    if (renameat(directory, "snapshot.bin.next", directory, "snapshot.bin") != 0 || fsync(directory) != 0) return false;
    return true;
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 3 || std::strlen(argv[2]) != 32) return 64;
    char* end = nullptr;
    long parent_value = std::strtol(argv[1], &end, 10);
    if (!end || *end || parent_value <= 1 || parent_value > INT_MAX) return 64;
    pid_t parent = static_cast<pid_t>(parent_value);
    Nonce nonce{};
    for (size_t i = 0; i < nonce.size(); ++i) {
        char pair[3]{argv[2][i*2], argv[2][i*2+1], 0};
        char* parsed = nullptr;
        long value = std::strtol(pair, &parsed, 16);
        if (!parsed || *parsed || value < 0 || value > 255) return 64;
        nonce[i] = static_cast<uint8_t>(value);
    }
    if (!valid_inheritance(parent)) return 65;
#ifdef NIKODESK_WATCHDOG_TEST_PROVIDER
    // Inspect only inherited descriptors before this process opens kqueue.
    // This test provider is never included in a product bundle.
    unsigned inherited = 0;
    for (int fd = 7; fd < getdtablesize(); ++fd) if (fcntl(fd, F_GETFD) >= 0) ++inherited;
    dprintf(report, "unrelated_inherited_descriptors=%u\n", inherited);
#endif
    int no_sigpipe = 1;
    setsockopt(channel, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    int queue = kqueue();
    if (queue < 0) return 66;
    struct kevent registration;
    EV_SET(&registration, parent, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, nullptr);
    if (kevent(queue, &registration, 1, nullptr, 0, nullptr) < 0 || getppid() != parent) { close(queue); return 66; }
    dprintf(report, "%s pid=%d parent=%d journal_version=%u\n", identity, getpid(), parent, protocol_version);
    Bytes ready(identity, identity + std::strlen(identity));
    if (!send_frame(channel, Op::ready, nonce, 0, ready)) { close(queue); return 67; }
    RecoveryState state;
    auto save = [&]{ return persist(state, nonce); };
    uint32_t sequence = 0;
    auto deadline = std::chrono::steady_clock::now() + lease;
    const char* reason = "protocol_failure";
    while (true) {
        struct kevent event{};
        timespec immediate{};
        int events = kevent(queue, nullptr, 0, &event, 1, &immediate);
        if (events < 0 && errno != EINTR) { reason = "process_monitor_failure"; break; }
        if (events > 0 || getppid() != parent) { reason = "parent_exit"; break; }
        if (std::chrono::steady_clock::now() >= deadline) { reason = "heartbeat_timeout"; break; }
        Op op;
        Bytes body;
        uint32_t incoming = 0;
        Receive received = receive_frame(channel, op, nonce, incoming, body, deadline);
        if (received == Receive::timeout) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false); continue; }
        if (received == Receive::closed) { reason = "channel_closed"; break; }
        if (received != Receive::ok || incoming != sequence + 1) break;
        sequence = incoming;
        bool ok = false;
        if (op == Op::snapshot) {
            Snapshot values;
            ok = snapshot(body, values) && state.prepare(values, read_gamma) && save();
        } else if (op == Op::write) {
            std::string uuid;
            GammaTable target;
            size_t at = 0;
            ok = text(body, at, uuid) && table(body, at, target) && at == body.size() &&
                 state.mutate(uuid, target, read_gamma, write_gamma, save);
        } else if (op == Op::heartbeat) ok = body.empty();
        else if (op == Op::stop) {
            ok = body.empty() && state.recover(read_gamma, write_gamma, save) && !state.touched();
            if (!send_frame(channel, ok ? Op::ack : Op::reject, nonce, sequence)) break;
            if (ok) { reason = "ordinary_stop"; break; }
            break;
        } else break;
        if (!send_frame(channel, ok ? Op::ack : Op::reject, nonce, sequence)) break;
        if (!ok) break;
        deadline = std::chrono::steady_clock::now() + lease;
    }
    dprintf(report, "recovery_trigger=%s\n", reason);
    close(channel);
    close(queue);
    bool restored = state.recover(read_gamma, write_gamma, save);
    // Reappearance and transient native failures are retried independently of
    // the parent. Unresolved state and the complete original tables remain on disk.
#ifdef NIKODESK_WATCHDOG_TEST_PROVIDER
    const auto retry_window = std::chrono::milliseconds(500);
#else
    const auto retry_window = std::chrono::seconds(30);
#endif
    auto retries_end = std::chrono::steady_clock::now() + retry_window;
    while (!restored && std::chrono::steady_clock::now() < retries_end) {
        poll(nullptr, 0, 250);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false);
        restored = state.recover(read_gamma, write_gamma, save);
    }
    dprintf(report, "recovery_complete=%d pending=%d; physical_input_release_not_verified\n", restored, state.touched());
    fsync(report);
    return restored ? 0 : 68;
}
