// NikoDesk's own VideoToolbox session for the HEVC encoder the hwcodec crate
// would otherwise run through ffmpeg. ffmpeg's VideoToolbox encoder hands a
// frame's bitstream back on a later call; this one waits for it, so each
// frame is sent as soon as the hardware has encoded it. It takes NV12 (the
// same input as before) or the capture's own IOSurface (no CPU copy). Output
// is Annex B with the parameter sets in front of every keyframe, as ffmpeg's.
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <vector>

namespace {
struct Output {
    std::vector<uint8_t> data;
    int64_t pts;
    bool key;
};

struct Session {
    VTCompressionSessionRef session = nullptr;
    CVPixelBufferPoolRef pool = nullptr;
    uint32_t width = 0, height = 0;
    std::mutex lock;
    std::condition_variable changed;
    std::deque<Output> outputs;
    uint64_t submitted = 0, finished = 0, failed = 0;
    Output taken;
};

const uint8_t kStartCode[4] = {0, 0, 0, 1};

// The average alone lets a sparse stream (a few new pictures a second) spend
// the whole second's budget on each picture: measured 4.7 Mbit/s at a 3.9
// Mbit/s target, and larger pictures raise the delay the frame rate follows.
// The hard limit holds every second to the target.
bool SetRate(VTCompressionSessionRef session, uint32_t kbps) {
    bool ok = VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(kbps * 1000.0)) == noErr;
    NSArray *limits = @[@(kbps * 1000.0 / 8), @1.0];
    VTSessionSetProperty(session, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)limits);
    return ok;
}

void Append(std::vector<uint8_t> &data, const uint8_t *bytes, size_t length) {
    data.insert(data.end(), kStartCode, kStartCode + 4);
    data.insert(data.end(), bytes, bytes + length);
}

void Encoded(void *context, void *, OSStatus status, VTEncodeInfoFlags, CMSampleBufferRef sample) {
    Session *s = static_cast<Session *>(context);
    Output output;
    bool ok = status == noErr && sample && CMSampleBufferDataIsReady(sample);
    if (ok) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
        output.key = true;
        if (attachments && CFArrayGetCount(attachments)) {
            CFDictionaryRef first = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            output.key = !CFDictionaryContainsKey(first, kCMSampleAttachmentKey_NotSync);
        }
        output.pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000 + .5;
        if (output.key) {
            CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
            size_t count = 0;
            if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, nullptr, nullptr, &count, nullptr) != noErr)
                ok = false;
            for (size_t i = 0; ok && i < count; ++i) {
                const uint8_t *set = nullptr;
                size_t length = 0;
                ok = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &set, &length, nullptr, nullptr) == noErr;
                if (ok) Append(output.data, set, length);
            }
        }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t total = block ? CMBlockBufferGetDataLength(block) : 0;
        std::vector<uint8_t> avcc(total);
        if (ok && total && CMBlockBufferCopyDataBytes(block, 0, total, avcc.data()) == noErr) {
            size_t offset = 0;
            while (offset + 4 <= total) {
                uint32_t length = (uint32_t)avcc[offset] << 24 | (uint32_t)avcc[offset + 1] << 16 |
                    (uint32_t)avcc[offset + 2] << 8 | avcc[offset + 3];
                if (length > total - offset - 4) { ok = false; break; }
                Append(output.data, avcc.data() + offset + 4, length);
                offset += 4 + length;
            }
        } else {
            ok = false;
        }
    }
    std::lock_guard<std::mutex> guard(s->lock);
    ++s->finished;
    if (ok && !output.data.empty()) s->outputs.push_back(std::move(output));
    else ++s->failed;
    s->changed.notify_all();
}

int Submit(Session *s, CVPixelBufferRef buffer, int64_t pts, bool key, uint32_t waitMs) {
    uint64_t target;
    {
        std::lock_guard<std::mutex> guard(s->lock);
        target = ++s->submitted;
    }
    NSDictionary *options = key ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
    OSStatus status = VTCompressionSessionEncodeFrame(s->session, buffer, CMTimeMake(pts, 1000), kCMTimeInvalid,
        (__bridge CFDictionaryRef)options, nullptr, nullptr);
    if (status != noErr) {
        std::lock_guard<std::mutex> guard(s->lock);
        ++s->finished;
        ++s->failed;
        return -1;
    }
    std::unique_lock<std::mutex> guard(s->lock);
    s->changed.wait_for(guard, std::chrono::milliseconds(waitMs), [&] { return s->finished >= target; });
    return s->finished >= target ? 0 : 1;
}
}  // namespace

extern "C" void *NVTCreate(uint32_t width, uint32_t height, uint32_t kbps, int32_t gop) {
    @autoreleasepool {
        if (!width || !height || width > 8192 || height > 8192) return nullptr;
        Session *s = new Session();
        s->width = width;
        s->height = height;
        NSDictionary *spec = @{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
        OSStatus status = VTCompressionSessionCreate(nullptr, (int32_t)width, (int32_t)height, kCMVideoCodecType_HEVC,
            (__bridge CFDictionaryRef)spec, nullptr, nullptr, Encoded, s, &s->session);
        if (status != noErr || !s->session) {
            delete s;
            return nullptr;
        }
        // Real-time mode paces sparse frames: a single new picture after a
        // pause (typing) took 27 ms instead of 13 ms on an M1 Max at 3024x1964,
        // with no difference at a steady 76 frames a second.
        VTSessionSetProperty(s->session, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
        VTSessionSetProperty(s->session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
        VTSessionSetProperty(s->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(s->session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
        // An IOSurface is converted to YUV by VideoToolbox: use BT.601 like
        // the CPU path's libyuv conversion, which is what decoders assume.
        VTSessionSetProperty(s->session, kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4);
        SetRate(s->session, kbps);
        if (gop > 0 && gop < INT32_MAX)
            VTSessionSetProperty(s->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@(gop));
        if (VTCompressionSessionPrepareToEncodeFrames(s->session) != noErr) {
            VTCompressionSessionInvalidate(s->session);
            CFRelease(s->session);
            delete s;
            return nullptr;
        }
        CFBooleanRef hardware = nullptr;
        VTSessionCopyProperty(s->session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, nullptr, &hardware);
        bool isHardware = hardware == kCFBooleanTrue;
        if (hardware) CFRelease(hardware);
        s->pool = VTCompressionSessionGetPixelBufferPool(s->session);
        if (!isHardware || !s->pool) {
            VTCompressionSessionInvalidate(s->session);
            CFRelease(s->session);
            delete s;
            return nullptr;
        }
        CFRetain(s->pool);
        return s;
    }
}

// The plane layout of the NV12 frames this session takes from the pool, so
// the converter can write them in place. Returns false without a pool buffer.
extern "C" bool NVTLayout(void *session, size_t *yStride, size_t *uvStride) {
    Session *s = static_cast<Session *>(session);
    CVPixelBufferRef buffer = nullptr;
    if (!s || CVPixelBufferPoolCreatePixelBuffer(nullptr, s->pool, &buffer) != kCVReturnSuccess) return false;
    *yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    *uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    CVPixelBufferRelease(buffer);
    return true;
}

// Encodes one NV12 frame (Y plane then interleaved UV, with the given
// strides) and waits up to `waitMs` for its bitstream. 0: done, 1: still
// encoding, -1: failed.
extern "C" int NVTEncodeNV12(void *session, const uint8_t *y, size_t yStride, const uint8_t *uv, size_t uvStride,
        int64_t pts, bool key, uint32_t waitMs) {
    Session *s = static_cast<Session *>(session);
    if (!s || !y || !uv) return -1;
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferPoolCreatePixelBuffer(nullptr, s->pool, &buffer) != kCVReturnSuccess) return -1;
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(buffer);
        return -1;
    }
    const uint8_t *sources[2] = {y, uv};
    const size_t strides[2] = {yStride, uvStride};
    const size_t rows[2] = {s->height, (s->height + 1) / 2};
    for (size_t plane = 0; plane < 2; ++plane) {
        uint8_t *target = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
        size_t targetStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
        size_t width = MIN(strides[plane], targetStride);
        for (size_t row = 0; row < rows[plane]; ++row)
            memcpy(target + row * targetStride, sources[plane] + row * strides[plane], width);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    int result = Submit(s, buffer, pts, key, waitMs);
    CVPixelBufferRelease(buffer);
    return result;
}

// Encodes the capture's IOSurface as it is; VideoToolbox converts the colour
// on the GPU. Same results as NVTEncodeNV12.
extern "C" int NVTEncodeSurface(void *session, void *surface, int64_t pts, bool key, uint32_t waitMs) {
    Session *s = static_cast<Session *>(session);
    if (!s || !surface) return -1;
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreateWithIOSurface(nullptr, (IOSurfaceRef)surface, nullptr, &buffer) != kCVReturnSuccess) return -1;
    int result = Submit(s, buffer, pts, key, waitMs);
    CVPixelBufferRelease(buffer);
    return result;
}

// Takes the oldest finished frame. The bytes stay valid until the next call.
extern "C" bool NVTTake(void *session, const uint8_t **data, size_t *length, int64_t *pts, bool *key) {
    Session *s = static_cast<Session *>(session);
    if (!s) return false;
    std::lock_guard<std::mutex> guard(s->lock);
    if (s->outputs.empty()) return false;
    s->taken = std::move(s->outputs.front());
    s->outputs.pop_front();
    *data = s->taken.data.data();
    *length = s->taken.data.size();
    *pts = s->taken.pts;
    *key = s->taken.key;
    return true;
}

extern "C" bool NVTSetBitrate(void *session, uint32_t kbps) {
    Session *s = static_cast<Session *>(session);
    return s && SetRate(s->session, kbps);
}

extern "C" void NVTRelease(void *session) {
    Session *s = static_cast<Session *>(session);
    if (!s) return;
    VTCompressionSessionCompleteFrames(s->session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(s->session);
    CFRelease(s->session);
    CFRelease(s->pool);
    delete s;
}
