#pragma once
#include "macos_privacy_watchdog_protocol.h"
#include "macos_privacy_watchdog_spawn.h"
#include <Security/Security.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <cstdlib>
#include <cstdio>

namespace nikodesk_privacy::watchdog {
inline bool same_file(const struct stat& a, const struct stat& b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
           a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec;
}
inline bool verify_helper(NSString* app, const std::string& path, int fd, CodeHash* approved = nullptr) {
    struct stat held{}, current{};
    if (fstat(fd, &held) || lstat(path.c_str(), &current) || !S_ISREG(held.st_mode) ||
            !same_file(held, current) || (held.st_mode & (S_ISUID | S_ISGID | 0022)) ||
            (held.st_uid != getuid() && held.st_uid != 0)) return false;
    SecStaticCodeRef outer = nullptr, helper = nullptr;
    SecRequirementRef identity = nullptr;
    NSString* heldPath = [NSString stringWithFormat:@"/dev/fd/%d", fd];
    bool ok = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:app], kSecCSDefaultFlags, &outer) == errSecSuccess &&
        SecStaticCodeCheckValidity(outer, kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures, nullptr) == errSecSuccess &&
        SecRequirementCreateWithString(CFSTR("identifier \"io.nikodesk.privacy-watchdog\""), kSecCSDefaultFlags, &identity) == errSecSuccess &&
        SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:heldPath], kSecCSDefaultFlags, &helper) == errSecSuccess &&
        SecStaticCodeCheckValidity(helper, kSecCSStrictValidate | kSecCSCheckAllArchitectures, identity) == errSecSuccess;
    if (ok && approved) ok = signing_hash(helper, *approved);
    if (outer) CFRelease(outer);
    if (helper) CFRelease(helper);
    if (identity) CFRelease(identity);
    struct stat after{};
    return ok && fstat(fd, &after) == 0 && same_file(held, after) && lstat(path.c_str(), &current) == 0 && same_file(held, current);
}

class Client {
public:
    ~Client() { close_channel(); }
    bool start() {
        if (channel_ >= 0 || getuid() == 0 || geteuid() != getuid()) return false;
        reap();
        NSBundle* bundle = [NSBundle mainBundle];
        if (![[bundle bundleIdentifier] isEqualToString:@"io.nikodesk.macos"]) return false;
        std::string helper = [[[bundle bundlePath] stringByAppendingPathComponent:@"Contents/Helpers/NikoDeskPrivacyWatchdog"] fileSystemRepresentation];
        int executable = open(helper.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (executable < 0) return false;
        executable = promote(executable);
        CodeHash approved;
        if (executable < 0 || !verify_helper([bundle bundlePath], helper, executable, &approved)) { if (executable >= 0) close(executable); return false; }
        std::string folder = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"nikodesk-privacy-watchdog.XXXXXX"] fileSystemRepresentation];
        std::vector<char> name(folder.begin(), folder.end()); name.push_back(0);
        if (!mkdtemp(name.data())) { close(executable); return false; }
        int directory = promote(open(name.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
        int log = directory < 0 ? -1 : promote(openat(directory, "recovery.txt", O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600));
        int pair[2]{-1, -1};
        if (directory < 0 || log < 0 || socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) {
            close(executable); if (directory >= 0) close(directory); if (log >= 0) close(log); return false;
        }
        pair[0] = promote(pair[0]); pair[1] = promote(pair[1]);
        if (pair[0] < 0 || pair[1] < 0) { close(executable); close(directory); close(log); if (pair[0]>=0) close(pair[0]); if (pair[1]>=0) close(pair[1]); return false; }
        int no_sigpipe = 1;
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
        arc4random_buf(nonce_.data(), nonce_.size());
        char nonce_text[33]{};
        for (size_t i = 0; i < nonce_.size(); ++i) std::snprintf(nonce_text + i*2, 3, "%02x", nonce_[i]);
        std::string parent = std::to_string(getpid());
        char* argv[]{helper.data(), parent.data(), nonce_text, nullptr};
        char env_path[] = "PATH=/usr/bin:/bin";
        char* environment[]{env_path, nullptr};
        posix_spawn_file_actions_t actions;
        posix_spawnattr_t attributes;
        bool initialized_actions = posix_spawn_file_actions_init(&actions) == 0;
        bool initialized_attributes = posix_spawnattr_init(&attributes) == 0;
        bool configured = initialized_actions && initialized_attributes;
        if (configured) configured = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED) == 0 &&
            posix_spawn_file_actions_adddup2(&actions, pair[1], 3) == 0 &&
            posix_spawn_file_actions_adddup2(&actions, directory, 4) == 0 &&
            posix_spawn_file_actions_adddup2(&actions, log, 5) == 0 &&
            posix_spawn_file_actions_adddup2(&actions, executable, 6) == 0 &&
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0 &&
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) == 0 &&
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0;
        pid_t child = 0;
        int result = configured ? spawn_verified(&child, helper.c_str(), executable, &actions, &attributes, argv, environment, approved) : EINVAL;
        if (initialized_actions) posix_spawn_file_actions_destroy(&actions);
        if (initialized_attributes) posix_spawnattr_destroy(&attributes);
        close(pair[1]); close(executable); close(directory); close(log);
        if (result) { close(pair[0]); return false; }
        children_.push_back(child);
        channel_ = pair[0]; sequence_ = 0;
        Op op; Bytes body; uint32_t sequence = 0;
        bool ready = receive(op, sequence, body) && op == Op::ready && sequence == 0 &&
            std::string(body.begin(), body.end()) == "nikodesk-privacy-watchdog-v1-production";
        if (!ready) close_channel();
        else NSLog(@"Niko privacy recovery journal: %s", name.data());
        return ready;
    }
    bool prepare(const Snapshot& tables) { return exchange(Op::snapshot, snapshot(tables)); }
    bool write(const std::string& uuid, const GammaTable& values) {
        Bytes body; text(body, uuid); table(body, values);
        return exchange(Op::write, body);
    }
    bool heartbeat() { return exchange(Op::heartbeat); }
    bool stop() {
        bool ok = channel_ < 0 || exchange(Op::stop);
        close_channel();
        return ok;
    }
    void close_channel() { if (channel_ >= 0) close(channel_); channel_ = -1; reap(); }
private:
    static int promote(int fd) {
        if (fd < 0) return -1;
        int result = fcntl(fd, F_DUPFD_CLOEXEC, 10);
        close(fd);
        return result;
    }
    void reap() {
        for (auto it = children_.begin(); it != children_.end();) {
            int status = 0;
            pid_t result = waitpid(*it, &status, WNOHANG);
            if (result > 0 || (result < 0 && errno == ECHILD)) it = children_.erase(it);
            else ++it;
        }
    }
    bool receive(Op& op, uint32_t& sequence, Bytes& body) {
        auto end = std::chrono::steady_clock::now() + lease;
        Receive result;
        do { result = receive_frame(channel_, op, nonce_, sequence, body, end); }
        while (result == Receive::timeout && std::chrono::steady_clock::now() < end);
        return result == Receive::ok;
    }
    bool exchange(Op op, const Bytes& body = {}) {
        if (channel_ < 0 || sequence_ == UINT32_MAX) return false;
        uint32_t request = ++sequence_, response = 0;
        Op reply; Bytes received;
        bool ok = send_frame(channel_, op, nonce_, request, body) && receive(reply, response, received) &&
            response == request && reply == Op::ack && received.empty();
        if (!ok) close_channel();
        return ok;
    }
    int channel_ = -1;
    Nonce nonce_{};
    uint32_t sequence_ = 0;
    std::vector<pid_t> children_;
};
} // namespace nikodesk_privacy::watchdog
