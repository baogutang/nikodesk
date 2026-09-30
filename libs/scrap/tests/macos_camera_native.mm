// In-memory CVPixelBuffer + production queue/ownership ABI tests. No device
// enumeration, authorization request, AVCaptureSession or physical capture.
#ifndef NIKODESK_CAMERA_TEST_HOOKS
#define NIKODESK_CAMERA_TEST_HOOKS
#endif
#include "../src/common/macos_camera_state.h"
#include <libyuv.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vp8cx.h>
#include <atomic>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <thread>

static std::atomic<int> released{0};
static int passed = 0;
static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static void release_bytes(void*, const void* base) { std::free(const_cast<void*>(base)); ++released; }
static CVPixelBufferRef buffer(size_t width = 16, size_t height = 16, size_t stride = 128,
                                OSType format = kCVPixelFormatType_32BGRA, uint8_t marker = 77) {
    auto* bytes = static_cast<uint8_t*>(std::malloc(stride * height));
    require(bytes != nullptr, "allocate bytes"); std::memset(bytes, marker, stride * height);
    CVPixelBufferRef result = nullptr;
    auto status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height, format,
        bytes, stride, release_bytes, nullptr, nullptr, &result);
    if (status != kCVReturnSuccess) std::free(bytes);
    require(status == kCVReturnSuccess && result, "create actual CVPixelBuffer"); return result;
}
struct Session {
    NKCameraSession* value = NKCameraTestCreate({16,16,30,42});
    ~Session() { if (value) require(NKCameraSessionRelease(value) == NKCAM_OK, "release acknowledged"); }
};
static void publish(NKCameraSession* session, uint8_t marker = 77, uint64_t epoch = 42) {
    auto image = buffer(16,16,128,kCVPixelFormatType_32BGRA,marker);
    int status = NKCameraTestPublish(session, image, epoch); CVPixelBufferRelease(image);
    require(status == NKCAM_OK, "publish");
}
static NKCameraFrame* take(NKCameraSession* session) {
    NKCameraFrame* frame = nullptr;
    require(NKCameraTakeLatest(session,42,0,&frame) == NKCAM_OK && frame, "take frame"); return frame;
}
template<class Function> static void test(const char* name, Function body) {
    body(); ++passed; std::printf("PASS %s\n", name);
}
int main() { try {
    test("selection bounds", [] {
        require(nikodesk_camera::valid_selection({16,16,30,42}), "valid");
        for (auto selection : {NKCameraSelection{0,16,30,42}, {17,16,30,42}, {16,17,30,42},
                {4098,16,30,42}, {16,4098,30,42}, {16,16,0,42}, {16,16,61,42}, {16,16,30,0}})
            require(!NKCameraTestCreate(selection), "invalid selection refused");
    });
    test("frame alone is not running", [] {
        Session s; publish(s.value); require(NKCameraWaitRunning(s.value,0) == NKCAM_TIMEOUT, "not running");
        NKCameraTestStarted(s.value); require(NKCameraWaitRunning(s.value,0) == NKCAM_OK, "both acknowledgements");
    });
    test("start alone is not running", [] {
        Session s; NKCameraTestStarted(s.value);
        require(NKCameraWaitRunning(s.value,0) == NKCAM_TIMEOUT, "first frame required");
        publish(s.value); require(NKCameraWaitRunning(s.value,0) == NKCAM_OK, "both acknowledgements");
    });
    test("stride and owned bytes survive stop", [] {
        int before = released; Session s; NKCameraTestStarted(s.value); publish(s.value);
        auto* frame = take(s.value); NKCameraFrameView view{};
        require(NKCameraFrameDescribe(frame,&view) == NKCAM_OK, "descriptor");
        require(view.width==16 && view.height==16 && view.stride==128 && view.length==2048 && view.epoch==42, "real stride");
        require(NKCameraStop(s.value)==NKCAM_OK, "stop acknowledged for nil-device test owner");
        require(released==before && view.data[0]==77 && view.data[2047]==77, "borrow remains live");
        NKCameraFrameRelease(frame); require(released==before+1, "last native retain released");
    });
    test("latest queue is bounded and replaces", [] {
        int before = released; Session s; NKCameraTestStarted(s.value);
        for (int i=0;i<2000;++i) publish(s.value,static_cast<uint8_t>(i));
        require(released==before+1999, "exactly one retained queue slot");
        auto* frame = take(s.value); NKCameraFrameView view{}; NKCameraFrameDescribe(frame,&view);
        require(view.data[0]==static_cast<uint8_t>(1999), "latest contents"); NKCameraFrameRelease(frame);
        require(released==before+2000, "every replacement released");
    });
    test("stop flushes queued frame", [] {
        int before=released; Session s; NKCameraTestStarted(s.value); publish(s.value);
        require(NKCameraStop(s.value)==NKCAM_OK && released==before+1, "queue flushed before ack");
        NKCameraFrame* frame=nullptr; require(NKCameraTakeLatest(s.value,42,0,&frame)==NKCAM_STOPPED && !frame, "no poststop frame");
        int phase=-1; require(NKCameraSessionStatus(s.value,&phase)==NKCAM_OK && phase==NKCAM_ENDED, "actual ended");
        require(NKCameraStop(s.value)==NKCAM_OK, "idempotent stop");
    });
    test("stale epoch cannot publish or consume", [] {
        Session s; auto image=buffer(); require(NKCameraTestPublish(s.value,image,41)==NKCAM_STALE, "old publish");
        CVPixelBufferRelease(image); NKCameraFrame* frame=nullptr;
        require(NKCameraTakeLatest(s.value,41,0,&frame)==NKCAM_STALE && !frame, "old read");
    });
    test("revoked epoch cannot restart", [] {
        Session s; require(NKCameraStop(s.value)==NKCAM_OK, "stopped");
        auto image=buffer(); require(NKCameraTestPublish(s.value,image,42)==NKCAM_STALE, "late delegate"); CVPixelBufferRelease(image);
        NKCameraTestStarted(s.value); require(NKCameraWaitRunning(s.value,0)==NKCAM_STOPPED, "late start");
    });
    test("invalid pixel and shape rejected", [] {
        Session s;
        for (auto image : {buffer(16,16,128,kCVPixelFormatType_32ARGB), buffer(17,16,128),
                           buffer(18,16,128), buffer(4100,2,16400)}) {
            require(NKCameraTestPublish(s.value,image,42)==NKCAM_INVALID, "pixel/shape mismatch"); CVPixelBufferRelease(image);
        }
        require(NKCameraTestPublish(s.value,nullptr,42)==NKCAM_INVALID, "null frame");
    });
    test("empty queue reports would block", [] {
        Session s; NKCameraTestStarted(s.value); publish(s.value); NKCameraFrameRelease(take(s.value));
        NKCameraFrame* frame=nullptr; require(NKCameraTakeLatest(s.value,42,0,&frame)==NKCAM_WOULD_BLOCK, "empty");
        require(NKCameraTakeLatest(s.value,42,30001,&frame)==NKCAM_INVALID, "timeout bound");
    });
    test("failed state is not successful stop state", [] {
        Session s; NKCameraTestFail(s.value); require(NKCameraWaitRunning(s.value,0)==NKCAM_FAILED, "failure");
        require(NKCameraStop(s.value)==NKCAM_OK, "resource teardown succeeded");
        int phase=-1; NKCameraSessionStatus(s.value,&phase); require(phase==NKCAM_ERROR, "failure preserved");
    });
    test("producer versus revoke drops late frames", [] {
        Session s; NKCameraTestStarted(s.value);
        std::thread producer([&]{for (int i=0;i<1000;++i) {
            auto image=buffer(); int result=NKCameraTestPublish(s.value,image,42); CVPixelBufferRelease(image);
            require(result==NKCAM_OK || result==NKCAM_STALE, "bounded racing publication");
        }});
        require(NKCameraStop(s.value)==NKCAM_OK, "revoke"); producer.join();
        NKCameraFrame* frame=nullptr; require(NKCameraTakeLatest(s.value,42,0,&frame)==NKCAM_STOPPED, "never revived");
    });
    test("owned actual BGRA frame reaches native VP8 encoder", [] {
        Session s; NKCameraTestStarted(s.value); publish(s.value); auto* frame=take(s.value); NKCameraFrameView view{};
        NKCameraFrameDescribe(frame,&view); vpx_image_t image{};
        require(vpx_img_alloc(&image,VPX_IMG_FMT_I420,view.width,view.height,1)!=nullptr,"I420 alloc");
        require(libyuv::ARGBToI420(view.data,static_cast<int>(view.stride),image.planes[0],image.stride[0],
            image.planes[1],image.stride[1],image.planes[2],image.stride[2],view.width,view.height)==0,"actual libyuv conversion");
        vpx_codec_enc_cfg_t cfg{}; require(vpx_codec_enc_config_default(vpx_codec_vp8_cx(),&cfg,0)==VPX_CODEC_OK,"config");
        cfg.g_w=view.width;cfg.g_h=view.height;cfg.g_timebase={1,30};cfg.g_threads=1;cfg.g_lag_in_frames=0;cfg.rc_target_bitrate=100;
        vpx_codec_ctx_t codec{}; require(vpx_codec_enc_init(&codec,vpx_codec_vp8_cx(),&cfg,0)==VPX_CODEC_OK,"encoder init");
        require(vpx_codec_encode(&codec,&image,0,1,0,VPX_DL_REALTIME)==VPX_CODEC_OK,"real encode");
        vpx_codec_iter_t it=nullptr;const vpx_codec_cx_pkt_t* packet=nullptr;size_t bytes=0;
        while ((packet=vpx_codec_get_cx_data(&codec,&it))) if(packet->kind==VPX_CODEC_CX_FRAME_PKT)bytes+=packet->data.frame.sz;
        require(bytes>0,"encoded native packet");std::printf("VP8 packet bytes: %zu\n",bytes);
        vpx_codec_destroy(&codec);vpx_img_free(&image);NKCameraFrameRelease(frame);
    });
    std::printf("{\"layer\":\"actual-in-memory-CVPixelBuffer-and-native-codec\",\"tests_passed\":%d,\"physical_capture\":false,\"TCC_request\":false}\n",passed);
    return 0;
} catch(const std::exception& error) { std::fprintf(stderr,"FAIL %s\n",error.what());return 1; } }
