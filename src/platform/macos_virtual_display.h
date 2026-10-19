#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
bool NikoMacVirtualDisplaySupported(void);
void *NikoMacVirtualDisplayCreate(uint32_t slot, uint32_t *display_id, uint32_t *serial, bool *applied);
bool NikoMacVirtualDisplayOnline(uint32_t display_id, uint32_t serial);
void *NikoMacVirtualDisplayCreateMatched(uint32_t slot, uint32_t width, uint32_t height, bool hidpi,
    uint32_t refresh_hz, uint32_t *display_id, uint32_t *serial, bool *applied, int32_t *matched);
bool NikoMacOtherDisplayOnline(const uint32_t *excluded, uint32_t count);
void NikoMacVirtualDisplayRelease(void *display);
#ifdef __cplusplus
}
#endif
