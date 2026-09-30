#pragma once
#include "macos_camera.h"
#include <CoreVideo/CoreVideo.h>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <chrono>

namespace nikodesk_camera {
constexpr uint32_t max_dimension = 4096;
constexpr uint32_t max_fps = 60;
constexpr size_t max_frame_bytes = 64 * 1024 * 1024;
inline bool valid_selection(NKCameraSelection s) {
    return s.epoch && s.width && s.height && s.width <= max_dimension && s.height <= max_dimension &&
        !(s.width % 2) && !(s.height % 2) && s.fps && s.fps <= max_fps;
}
}

struct NKCameraFrame {
    CVPixelBufferRef buffer = nullptr;
    NKCameraFrameView view{};
    ~NKCameraFrame() {
        if (buffer) {
            CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferRelease(buffer);
        }
    }
    NKCameraFrame() = default;
    NKCameraFrame(const NKCameraFrame&) = delete;
    NKCameraFrame& operator=(const NKCameraFrame&) = delete;
    static std::unique_ptr<NKCameraFrame> retain(CVPixelBufferRef buffer, uint64_t epoch) {
        using namespace nikodesk_camera;
        if (!buffer || !epoch || CVPixelBufferIsPlanar(buffer) ||
                CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) return {};
        size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        if (!width || !height || width > max_dimension || height > max_dimension ||
                width % 2 || height % 2 || stride < width * 4 || stride > max_frame_bytes / height) return {};
        CVPixelBufferRetain(buffer);
        if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
            CVPixelBufferRelease(buffer); return {};
        }
        std::unique_ptr<NKCameraFrame> frame(new NKCameraFrame);
        frame->buffer = buffer;
        const auto* data = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
        size_t length = stride * height;
        if (!data || CVPixelBufferGetDataSize(buffer) < length) return {};
        frame->view = {data, length, stride, static_cast<uint32_t>(width), static_cast<uint32_t>(height), epoch};
        return frame;
    }
};

namespace nikodesk_camera {
struct State {
    explicit State(NKCameraSelection value): selection(value) {}
    std::mutex mutex;
    std::condition_variable changed;
    const NKCameraSelection selection;
    int phase = NKCAM_STARTING;
    bool revoked = false;
    bool failed = false;
    bool first_frame = false;
    bool hardware_started = false;
    std::unique_ptr<NKCameraFrame> latest;
    int publish(CVPixelBufferRef buffer, uint64_t epoch) {
        auto frame = NKCameraFrame::retain(buffer, epoch);
        if (!frame) return NKCAM_INVALID;
        if (frame->view.width != selection.width || frame->view.height != selection.height) return NKCAM_INVALID;
        std::unique_ptr<NKCameraFrame> discarded;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (revoked || epoch != selection.epoch || (phase != NKCAM_STARTING && phase != NKCAM_RUNNING)) return NKCAM_STALE;
            discarded = std::move(latest);
            latest = std::move(frame);
            first_frame = true;
            if (hardware_started) phase = NKCAM_RUNNING;
        }
        changed.notify_all();
        // Release a replaced CV buffer outside the short queue-state lock.
        return NKCAM_OK;
    }
    void started() {
        { std::lock_guard<std::mutex> lock(mutex);
          if (!revoked) { hardware_started = true; if (first_frame) phase = NKCAM_RUNNING; } }
        changed.notify_all();
    }
    void revoke(int next = NKCAM_REVOKING) {
        std::unique_ptr<NKCameraFrame> discarded;
        {
            std::lock_guard<std::mutex> lock(mutex);
            revoked = true;
            failed = failed || next == NKCAM_ERROR;
            phase = next == NKCAM_ENDED && failed ? NKCAM_ERROR : next;
            discarded = std::move(latest);
        }
        changed.notify_all();
    }
    int terminal_result() const {
        return failed ? NKCAM_FAILED : revoked ? NKCAM_STOPPED : NKCAM_OK;
    }
};
} // namespace nikodesk_camera
