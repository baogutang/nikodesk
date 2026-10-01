#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NKCameraPermission NKCameraPermission;
typedef struct NKCameraDevices NKCameraDevices;
typedef struct NKCameraSession NKCameraSession;
typedef struct NKCameraFrame NKCameraFrame;
enum NKCameraResult {
    NKCAM_OK = 0, NKCAM_WOULD_BLOCK = 1, NKCAM_PERMISSION = 2,
    NKCAM_INVALID = 3, NKCAM_STOPPED = 4, NKCAM_FAILED = 5,
    NKCAM_TIMEOUT = 6, NKCAM_STALE = 7, NKCAM_BUSY = 8
};
enum NKCameraPhase { NKCAM_STARTING = 0, NKCAM_RUNNING = 1, NKCAM_REVOKING = 2, NKCAM_ENDED = 3, NKCAM_ERROR = 4 };
typedef struct {
    uint32_t width, height, min_fps_milli, max_fps_milli;
    uint32_t native_index, range_index;
    uint8_t native_fingerprint[32];
} NKCameraFormat;
typedef struct { const char* unique_id; const char* name; size_t format_count; } NKCameraDevice;
typedef struct { uint32_t width, height, fps; uint64_t epoch; } NKCameraSelection;
typedef struct {
    const uint8_t* data;
    size_t length, stride;
    uint32_t width, height;
    uint64_t epoch;
} NKCameraFrameView;

// Status is read-only. Only RequestAccess can ask the OS for authorization.
int NKCameraAuthorizationStatus(void);
NKCameraPermission* NKCameraRequestAccess(uint64_t request_id);
int NKCameraPermissionPoll(NKCameraPermission*, int* authorization_status);
void NKCameraPermissionCancel(NKCameraPermission*);
void NKCameraPermissionRelease(NKCameraPermission*);
NKCameraDevices* NKCameraEnumerate(int* result);
size_t NKCameraDeviceCount(const NKCameraDevices*);
int NKCameraDeviceAt(const NKCameraDevices*, size_t index, NKCameraDevice*);
int NKCameraFormatAt(const NKCameraDevices*, size_t device, size_t format, NKCameraFormat*);
void NKCameraDevicesRelease(NKCameraDevices*);

// Caller must provide the exact locally approved uniqueID/format and epoch.
// No index/default-device fallback and no implicit requestAccess calls.
NKCameraSession* NKCameraStart(const char* unique_id, NKCameraSelection selection,
    const NKCameraFormat* approved_format, int* result);
int NKCameraWaitRunning(NKCameraSession*, uint32_t timeout_ms);
int NKCameraTakeLatest(NKCameraSession*, uint64_t epoch, uint32_t timeout_ms, NKCameraFrame**);
int NKCameraSessionStatus(NKCameraSession*, int* phase);
int NKCameraStop(NKCameraSession*);
// Failed release transfers the handle to the pending owner registry. Do not
// reuse that raw handle; retry only with its unique process-local capture lease.
int NKCameraSessionRelease(NKCameraSession*);
// Only failed construction/release owners are eligible, never a live capturer.
int NKCameraStopPending(uint64_t capture_lease);
int NKCameraFrameDescribe(const NKCameraFrame*, NKCameraFrameView*);
void NKCameraFrameRelease(NKCameraFrame*);

#ifdef NIKODESK_CAMERA_TEST_HOOKS
// Buffer/state tests only: these paths never create AV capture objects or ask TCC.
NKCameraSession* NKCameraTestCreate(NKCameraSelection selection);
void NKCameraTestStarted(NKCameraSession*);
int NKCameraTestPublish(NKCameraSession*, void* pixel_buffer, uint64_t epoch);
void NKCameraTestFail(NKCameraSession*);
int NKCameraTestReserve(NKCameraSession*);
void NKCameraTestStopFailures(NKCameraSession*, uint32_t failures);
// Pure format-description fixtures. No discovery, input, session or TCC calls.
int NKCameraTestFormat(const void* description, const void* extensions, uint32_t native_index,
    double minimum_fps, double maximum_fps, NKCameraFormat* output);
int NKCameraTestFormatMatches(const NKCameraFormat*, const NKCameraFormat*);
#endif

#ifdef __cplusplus
}
#endif
