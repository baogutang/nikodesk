#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Read-only: 1 authorized, 0 undetermined, -1 denied, -2 invalid process. */
int NKVoiceMicrophoneAuthorization(void);
/* Public CoreAudio read-only properties; never opens or starts a device. */
int NKVoiceReadDeviceUID(uint32_t device, char *output, uint32_t capacity);
int NKVoiceDeviceMatches(uint32_t device, const char *expected_uid);
int NKVoiceUIDEquals(const char *expected_uid, const char *actual_uid);
#ifdef __cplusplus
}
#endif
