//
//  TextureRgbaApi.m
//  texture_rgba_renderer
//
//  Created by kingtous on 2023/2/19.
//

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "texture_rgba_renderer/texture_rgba_renderer-Swift.h"

#if __cplusplus
extern "C" {
#endif
    
/// Keep the same name with Windows.
void FlutterRgbaRendererPluginOnRgba(void* texture_rgba_ptr, const uint8_t* buffer, int len, int width, int height, int stride_align) {
    TextRgba* texture_rgba = (__bridge TextRgba *)(texture_rgba_ptr);
    [texture_rgba markFrameAvaliableRawWithBuffer:buffer len:len width:width height:height stride_align: stride_align];
}

/// NikoDesk: the texture keeps its own reference to `buffer`.
void FlutterRgbaRendererPluginOnPixelBuffer(void* texture_rgba_ptr, CVPixelBufferRef buffer) {
    TextRgba* texture_rgba = (__bridge TextRgba *)(texture_rgba_ptr);
    [texture_rgba markPixelBufferAvailableWithBuffer:buffer];
}

#if __cplusplus
} //Extern C
#endif
