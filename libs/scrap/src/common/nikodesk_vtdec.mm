// NikoDesk's VideoToolbox decoder for the Mac controller (plan A3). H.264 or
// HEVC Annex B goes in; each picture comes out as an IOSurface-backed NV12
// pixel buffer that the Flutter texture draws as it is. ffmpeg's path copies
// every picture back from the GPU and converts it to RGBA on the CPU.
// The buffers are video range, which Flutter converts with BT.601: the matrix
// every NikoDesk and RustDesk encoder uses (see nikodesk_vt.mm).
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import <VideoToolbox/VideoToolbox.h>
#include <algorithm>
#include <cmath>
#include <mutex>
#include <vector>

namespace {
// Keep in sync with nikodesk_vtdec.rs.
enum Result : int32_t {
    kPicture = 1,
    kNothing = 0,
    kNotYet = 2,
    kUnsupported = -1,
    kFailed = -2,
};

struct Decoder {
    bool hevc = false;
    VTDecompressionSessionRef session = nullptr;
    CMVideoFormatDescriptionRef format = nullptr;
    std::vector<std::vector<uint8_t>> sets;
    std::mutex lock;
    CVPixelBufferRef picture = nullptr;
    bool got = false;
    OSStatus status = noErr;
    // Why the last call failed, for the log.
    OSStatus error = noErr;
};

struct Nal {
    const uint8_t *data;
    size_t length;
};

std::vector<Nal> Split(const uint8_t *data, size_t length) {
    std::vector<Nal> nals;
    size_t start = SIZE_MAX;
    auto end = [&](size_t at) {
        // A 4-byte start code's first zero, or trailing zeros, are not NAL data.
        while (at > start && data[at - 1] == 0) --at;
        if (start != SIZE_MAX && at > start) nals.push_back({data + start, at - start});
    };
    size_t i = 0;
    while (i + 3 <= length) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            if (start != SIZE_MAX) end(i);
            i += 3;
            start = i;
        } else {
            ++i;
        }
    }
    if (start != SIZE_MAX) end(length);
    return nals;
}

int Type(const Decoder *d, const Nal &nal) {
    return d->hevc ? (nal.data[0] >> 1) & 0x3F : nal.data[0] & 0x1F;
}

bool ParameterSet(const Decoder *d, int type) {
    return d->hevc ? type >= 32 && type <= 34 : type == 7 || type == 8;
}

bool Delimiter(const Decoder *d, int type) {
    return d->hevc ? type == 35 : type == 9;
}

// Every kind a format needs: VPS, SPS and PPS for HEVC, SPS and PPS for H.264.
bool Complete(const Decoder *d, const std::vector<std::vector<uint8_t>> &sets) {
    auto has = [&](int type) {
        return std::any_of(sets.begin(), sets.end(), [&](const auto &set) { return Type(d, {set.data(), set.size()}) == type; });
    };
    return d->hevc ? has(32) && has(33) && has(34) : has(7) && has(8);
}

void Decoded(void *context, void *, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime, CMTime) {
    Decoder *d = static_cast<Decoder *>(context);
    std::lock_guard<std::mutex> guard(d->lock);
    if (status != noErr) {
        d->status = status;
        return;
    }
    if (!image || (flags & kVTDecodeInfo_FrameDropped)) return;
    if (d->picture) CVPixelBufferRelease(d->picture);
    d->picture = CVPixelBufferRetain(image);
    d->got = true;
}

void Stop(Decoder *d) {
    if (d->session) {
        VTDecompressionSessionWaitForAsynchronousFrames(d->session);
        VTDecompressionSessionInvalidate(d->session);
        CFRelease(d->session);
        d->session = nullptr;
    }
    if (d->format) {
        CFRelease(d->format);
        d->format = nullptr;
    }
}

bool Start(Decoder *d) {
    Stop(d);
    std::vector<const uint8_t *> pointers;
    std::vector<size_t> sizes;
    for (const auto &set : d->sets) {
        pointers.push_back(set.data());
        sizes.push_back(set.size());
    }
    OSStatus status = d->hevc
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, pointers.size(), pointers.data(),
              sizes.data(), 4, nullptr, &d->format)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, pointers.size(), pointers.data(),
              sizes.data(), 4, &d->format);
    if (status != noErr) {
        d->error = status;
        d->format = nullptr;
        return false;
    }
#if TARGET_OS_IPHONE
    // iOS decodes in hardware by default; the key only exists from iOS 17.
    NSDictionary *specification = @{};
#else
    NSDictionary *specification = @{
        (__bridge NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES,
    };
#endif
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    VTDecompressionOutputCallbackRecord callback = {Decoded, d};
    status = VTDecompressionSessionCreate(kCFAllocatorDefault, d->format, (__bridge CFDictionaryRef)specification,
        (__bridge CFDictionaryRef)attributes, &callback, &d->session);
    if (status != noErr) {
        d->error = status;
        d->session = nullptr;
        Stop(d);
        return false;
    }
    VTSessionSetProperty(d->session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    return true;
}

// The picture without the encoder's padding, as ffmpeg's decoder returns it.
bool Cropped(const Decoder *d, CVPixelBufferRef picture) {
    CGSize size = CMVideoFormatDescriptionGetPresentationDimensions(d->format, false, true);
    return std::lround(size.width) == (long)CVPixelBufferGetWidth(picture) &&
        std::lround(size.height) == (long)CVPixelBufferGetHeight(picture);
}
}  // namespace

extern "C" void *NVDCreate(bool hevc) {
    Decoder *d = new Decoder();
    d->hevc = hevc;
    return d;
}

// On kPicture, *picture stays valid until the next call or NVDRelease.
extern "C" int32_t NVDDecode(void *decoder, const uint8_t *data, size_t length, void **picture, uint32_t *width,
    uint32_t *height) {
    @autoreleasepool {
        Decoder *d = static_cast<Decoder *>(decoder);
        std::vector<std::vector<uint8_t>> sets;
        std::vector<uint8_t> sample;
        for (const Nal &nal : Split(data, length)) {
            int type = Type(d, nal);
            if (ParameterSet(d, type)) {
                sets.emplace_back(nal.data, nal.data + nal.length);
                continue;
            }
            if (Delimiter(d, type)) continue;
            uint32_t size = CFSwapInt32HostToBig((uint32_t)nal.length);
            const uint8_t *prefix = reinterpret_cast<const uint8_t *>(&size);
            sample.insert(sample.end(), prefix, prefix + 4);
            sample.insert(sample.end(), nal.data, nal.data + nal.length);
        }
        // Partial sets would make a format without the others; the session
        // keeps the complete ones it started with.
        if (Complete(d, sets)) {
            std::stable_sort(sets.begin(), sets.end(), [d](const auto &a, const auto &b) {
                return Type(d, {a.data(), a.size()}) < Type(d, {b.data(), b.size()});
            });
            if (!d->session || sets != d->sets) {
                d->sets = std::move(sets);
                if (!Start(d)) return kUnsupported;
            }
        }
        if (!d->session) return kNotYet;
        if (sample.empty()) return kNothing;

        CMBlockBufferRef block = nullptr;
        CMSampleBufferRef buffer = nullptr;
        size_t total = sample.size();
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, total, kCFAllocatorDefault,
            nullptr, 0, total, kCMBlockBufferAssureMemoryNowFlag, &block);
        if (status == noErr) status = CMBlockBufferReplaceDataBytes(sample.data(), block, 0, total);
        if (status == noErr)
            status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, d->format, 1, 0, nullptr, 1, &total, &buffer);
        {
            std::lock_guard<std::mutex> guard(d->lock);
            d->got = false;
            d->status = noErr;
        }
        if (status == noErr) {
            VTDecodeInfoFlags info = 0;
            status = VTDecompressionSessionDecodeFrame(d->session, buffer, 0, nullptr, &info);
            if (status == noErr) VTDecompressionSessionWaitForAsynchronousFrames(d->session);
        }
        if (buffer) CFRelease(buffer);
        if (block) CFRelease(block);
        if (status == kVTInvalidSessionErr) {
            // The system dropped the session, as it may on sleep or a GPU
            // change; a new one starts at the next keyframe.
            d->error = status;
            Stop(d);
            d->sets.clear();
            return kFailed;
        }
        std::lock_guard<std::mutex> guard(d->lock);
        if (status == noErr) status = d->status;
        if (status != noErr) {
            d->error = status;
            return kFailed;
        }
        if (!d->got) return kNothing;
        if (!Cropped(d, d->picture)) {
            d->error = kVTVideoDecoderUnsupportedDataFormatErr;
            return kUnsupported;
        }
        *picture = d->picture;
        *width = (uint32_t)CVPixelBufferGetWidth(d->picture);
        *height = (uint32_t)CVPixelBufferGetHeight(d->picture);
        return kPicture;
    }
}

extern "C" bool NVDHardware(void *decoder) {
    Decoder *d = static_cast<Decoder *>(decoder);
    if (!d->session) return false;
#if TARGET_OS_IPHONE
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    // Weakly linked: null before iOS 17, where the answer is unknown.
    if (&kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder == nullptr) return false;
#endif
    CFBooleanRef value = nullptr;
    bool hardware = VTSessionCopyProperty(d->session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                        kCFAllocatorDefault, &value) == noErr &&
        value && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    return hardware;
#if TARGET_OS_IPHONE
#pragma clang diagnostic pop
#endif
}

extern "C" int32_t NVDError(void *decoder) {
    return static_cast<Decoder *>(decoder)->error;
}

extern "C" void NVDSize(void *picture, uint32_t *width, uint32_t *height) {
    CVPixelBufferRef buffer = static_cast<CVPixelBufferRef>(picture);
    *width = (uint32_t)CVPixelBufferGetWidth(buffer);
    *height = (uint32_t)CVPixelBufferGetHeight(buffer);
}

extern "C" void NVDRelease(void *decoder) {
    Decoder *d = static_cast<Decoder *>(decoder);
    Stop(d);
    if (d->picture) CVPixelBufferRelease(d->picture);
    delete d;
}

// For the iOS RGB path and the Mac's device thumbnails: NV12 to ARGB8888 in libyuv's byte order (B, G, R, A),
// BT.601 video range as the encoder wrote it.
extern "C" bool NVDToARGB(void *picture, uint8_t *dst, size_t stride) {
    CVPixelBufferRef buffer = static_cast<CVPixelBufferRef>(picture);
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return false;
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    vImage_Buffer yp = {CVPixelBufferGetBaseAddressOfPlane(buffer, 0), height, width,
        CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)};
    vImage_Buffer cbcr = {CVPixelBufferGetBaseAddressOfPlane(buffer, 1), height / 2, width / 2,
        CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)};
    vImage_Buffer out = {dst, height, width, stride};
    vImage_YpCbCrPixelRange range = {16, 128, 235, 240, 255, 0, 255, 0};
    vImage_YpCbCrToARGB info;
    vImage_Error error = vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
        &range, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, kvImageNoFlags);
    if (error == kvImageNoError)
        error = vImageConvert_420Yp8_CbCr8ToARGB8888(&yp, &cbcr, &out, &info, nullptr, 255, kvImageNoFlags);
    if (error == kvImageNoError) {
        for (size_t y = 0; y < height; y++) {
            uint32_t *row = reinterpret_cast<uint32_t *>(dst + y * stride);
            for (size_t x = 0; x < width; x++) row[x] = __builtin_bswap32(row[x]);
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return error == kvImageNoError;
}
