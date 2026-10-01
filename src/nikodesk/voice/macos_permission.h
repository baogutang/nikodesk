#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Read-only: 1 authorized, 0 undetermined, -1 denied, -3 restricted, -2 unavailable. */
int NKVoiceMicrophoneAuthorization(void);
typedef void (*NKVoicePermissionCompletion)(void *context, int status);
/* Explicit local action ONLY. 1 accepts and retains context until exactly one
 * completion; -2 does not retain it. A timeout must not free accepted context. */
int NKVoiceRequestMicrophoneAuthorization(NKVoicePermissionCompletion completion, void *context);
/* Completion dispatch shared by production and no-TCC memory checks. */
int NKVoiceCompleteMicrophoneAuthorization(NKVoicePermissionCompletion completion, void *context, int status);
/* Public CoreAudio read-only properties; never opens or starts a device. */
int NKVoiceReadDeviceUID(uint32_t device, char *output, uint32_t capacity);
int NKVoiceDeviceMatches(uint32_t device, const char *expected_uid);
int NKVoiceUIDEquals(const char *expected_uid, const char *actual_uid);
/* Only AudioObject property reads. No AudioUnit or hardware format changes. */
int NKVoiceReadDeviceMetadata(uint32_t device, uint32_t *capture_channels,
                            uint32_t *playback_channels, double *nominal_rate);
#ifdef __cplusplus
}
#endif
