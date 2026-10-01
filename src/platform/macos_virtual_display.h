#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
bool NikoMacVirtualDisplaySupported(void);
void *NikoMacVirtualDisplayCreate(uint32_t slot, uint32_t *display_id, uint32_t *serial, bool *applied);
bool NikoMacVirtualDisplayOnline(uint32_t display_id, uint32_t serial);
void NikoMacVirtualDisplayRelease(void *display);
#ifdef __cplusplus
}
#endif
