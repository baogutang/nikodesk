//! The Mac controller's VideoToolbox decoder (see nikodesk_vtdec.mm): each
//! H.264 or HEVC picture stays on the GPU as an NV12 pixel buffer for the
//! Flutter texture, instead of coming back for the CPU to convert to RGBA.
//! The app turns it on with `set_output_check` once its texture plugin takes
//! pixel buffers; the option `nikodesk-native-decoder` = "N" turns it off.
//! A stream it cannot decode goes to ffmpeg's decoder, as before.
use crate::ImageTexture;
use hbb_common::{anyhow::bail, config::LocalConfig, log, ResultType};
use std::{ffi::c_void, sync::OnceLock};

extern "C" {
    fn NVDCreate(hevc: bool) -> *mut c_void;
    fn NVDDecode(
        decoder: *mut c_void,
        data: *const u8,
        length: usize,
        picture: *mut *mut c_void,
        width: *mut u32,
        height: *mut u32,
    ) -> i32;
    fn NVDHardware(decoder: *mut c_void) -> bool;
    fn NVDError(decoder: *mut c_void) -> i32;
    fn NVDSize(picture: *mut c_void, width: *mut u32, height: *mut u32);
    fn NVDRelease(decoder: *mut c_void);
}

const OPTION: &str = "nikodesk-native-decoder";
// Keep in sync with nikodesk_vtdec.mm.
const PICTURE: i32 = 1;
const NOTHING: i32 = 0;
const NOT_YET: i32 = 2;
const UNSUPPORTED: i32 = -1;
/// Decode errors in a row that stay on VideoToolbox. The client asks for a
/// keyframe after each, and marks the codec unsupported after three, so the
/// second goes to ffmpeg's decoder with that keyframe.
const MAX_FAILURES: u32 = 2;

static OUTPUT_CHECK: OnceLock<fn() -> bool> = OnceLock::new();

/// `check` says whether the video now goes to textures that take pixel buffers.
pub fn set_output_check(check: fn() -> bool) {
    OUTPUT_CHECK.get_or_init(|| check);
}

pub fn wanted() -> bool {
    OUTPUT_CHECK.get().is_some_and(|check| check()) && LocalConfig::get_option(OPTION) != "N"
}

/// The size of a picture handed out by `decode`.
pub fn picture_size(picture: *mut c_void) -> (usize, usize) {
    let (mut width, mut height) = (0, 0);
    unsafe { NVDSize(picture, &mut width, &mut height) };
    (width as _, height as _)
}

pub enum Decoded {
    /// `texture` holds the picture until the next call.
    Picture,
    Nothing,
    /// For ffmpeg's decoder: no session can start from this frame yet.
    NotYet,
    /// For ffmpeg's decoder from this frame on.
    Unsupported,
}

pub struct VtDecoder {
    decoder: usize,
    failures: u32,
    started: bool,
}

// The decoder is used from one video thread at a time.
unsafe impl Send for VtDecoder {}

impl VtDecoder {
    pub fn new(hevc: bool) -> Option<Self> {
        let decoder = unsafe { NVDCreate(hevc) };
        (!decoder.is_null()).then(|| Self {
            decoder: decoder as usize,
            failures: 0,
            started: false,
        })
    }

    pub fn decode(&mut self, data: &[u8], texture: &mut ImageTexture) -> ResultType<Decoded> {
        let (mut picture, mut width, mut height) = (std::ptr::null_mut(), 0, 0);
        let result = unsafe {
            NVDDecode(
                self.decoder as _,
                data.as_ptr(),
                data.len(),
                &mut picture,
                &mut width,
                &mut height,
            )
        };
        match result {
            PICTURE => {
                self.failures = 0;
                if !self.started {
                    self.started = true;
                    log::info!(
                        "VideoToolbox decoder started, {width}x{height}, hardware: {}",
                        self.hardware()
                    );
                }
                *texture = ImageTexture {
                    texture: picture,
                    w: width as _,
                    h: height as _,
                };
                Ok(Decoded::Picture)
            }
            NOTHING => Ok(Decoded::Nothing),
            NOT_YET => Ok(Decoded::NotYet),
            UNSUPPORTED => {
                log::warn!("VideoToolbox decoder unsupported, error {}", self.error());
                Ok(Decoded::Unsupported)
            }
            _ => {
                self.failures += 1;
                // A failed first frame would mark the codec unsupported.
                if !self.started || self.failures >= MAX_FAILURES {
                    log::warn!("VideoToolbox decoder failed, error {}, using ffmpeg's", self.error());
                    return Ok(Decoded::Unsupported);
                }
                bail!("VideoToolbox decoder failed, error {}", self.error());
            }
        }
    }

    pub fn started(&self) -> bool {
        self.started
    }

    pub fn hardware(&self) -> bool {
        unsafe { NVDHardware(self.decoder as _) }
    }

    fn error(&self) -> i32 {
        unsafe { NVDError(self.decoder as _) }
    }
}

impl Drop for VtDecoder {
    fn drop(&mut self) {
        unsafe { NVDRelease(self.decoder as _) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        codec::{EncoderApi, EncoderCfg},
        hwcodec::{HwRamEncoder, HwRamEncoderConfig},
        nikodesk_vt::NikoVtEncoder,
        EncodeInput,
    };
    use base::message_proto::{video_frame, EncodedVideoFrame};

    #[link(name = "CoreVideo", kind = "framework")]
    extern "C" {
        fn CVPixelBufferGetPixelFormatType(buffer: *mut c_void) -> u32;
        fn CVPixelBufferGetIOSurface(buffer: *mut c_void) -> *mut c_void;
        fn CVPixelBufferLockBaseAddress(buffer: *mut c_void, flags: u64) -> i32;
        fn CVPixelBufferUnlockBaseAddress(buffer: *mut c_void, flags: u64) -> i32;
        fn CVPixelBufferGetBaseAddressOfPlane(buffer: *mut c_void, plane: usize) -> *const u8;
        fn CVPixelBufferGetBytesPerRowOfPlane(buffer: *mut c_void, plane: usize) -> usize;
    }

    const NV12_VIDEO_RANGE: u32 = u32::from_be_bytes(*b"420v");

    fn config(name: &str, width: usize, height: usize) -> HwRamEncoderConfig {
        HwRamEncoderConfig {
            name: name.into(),
            mc_name: None,
            width,
            height,
            quality: 1.0,
            keyframe_interval: None,
        }
    }

    fn luma(x: usize, width: usize) -> u8 {
        (16 + x * 219 / (width - 1)) as u8
    }

    /// Encodes `count` NV12 frames of a horizontal luma ramp with neutral
    /// chroma, moved `step` pixels a frame.
    fn encode(encoder: &mut dyn EncoderApi, count: usize, step: usize) -> Vec<EncodedVideoFrame> {
        let format = encoder.yuvfmt();
        let (width, height) = (format.w, format.h);
        let mut yuv = vec![128u8; format.u + format.stride[1] * height.div_ceil(2)];
        let mut frames = vec![];
        for i in 0..count * 4 {
            if frames.len() >= count {
                break;
            }
            for row in 0..height {
                for x in 0..width {
                    yuv[row * format.stride[0] + x] = luma((x + i * step) % width, width);
                }
            }
            if let Ok(frame) = encoder.encode_to_message(EncodeInput::YUV(&mut yuv), i as i64 * 33) {
                match frame.union {
                    Some(video_frame::Union::H264s(f)) | Some(video_frame::Union::H265s(f)) => {
                        frames.extend(f.frames)
                    }
                    _ => {}
                }
            }
        }
        frames
    }

    fn check(texture: &ImageTexture, width: usize, height: usize) {
        assert_eq!((texture.w, texture.h), (width, height));
        assert_eq!(picture_size(texture.texture), (width, height));
        let buffer = texture.texture;
        unsafe {
            assert_eq!(CVPixelBufferGetPixelFormatType(buffer), NV12_VIDEO_RANGE);
            assert!(!CVPixelBufferGetIOSurface(buffer).is_null());
            assert_eq!(CVPixelBufferLockBaseAddress(buffer, 1), 0);
            let (y, y_stride) = (
                CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
            );
            let (uv, uv_stride) = (
                CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
            );
            let (mut luma_error, mut chroma_error, mut samples) = (0.0, 0.0, 0.0);
            for row in (0..height).step_by(7) {
                for x in (0..width).step_by(5) {
                    let got = *y.add(row * y_stride + x);
                    luma_error += (got as f64 - luma(x, width) as f64).abs();
                    let got = *uv.add(row / 2 * uv_stride + x / 2 * 2);
                    chroma_error += (got as f64 - 128.0).abs();
                    samples += 1.0;
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, 1);
            assert!(luma_error / samples < 4.0, "luma off by {}", luma_error / samples);
            assert!(chroma_error / samples < 4.0, "chroma off by {}", chroma_error / samples);
        }
    }

    // Needs a hardware HEVC encoder; skipped where there is none (CI VMs).
    #[test]
    fn hevc_pictures_keep_their_size_and_colour() {
        for (width, height) in [(640, 480), (1366, 768), (3024, 1964)] {
            let cfg = EncoderCfg::HWRAM(config("hevc_videotoolbox", width, height));
            let Ok(mut encoder) = NikoVtEncoder::new(cfg, false) else {
                eprintln!("no hardware HEVC encoder here; skipped");
                return;
            };
            let frames = encode(&mut encoder, 3, 0);
            assert_eq!(frames.len(), 3);
            let mut decoder = VtDecoder::new(true).unwrap();
            let mut texture = ImageTexture::default();
            for frame in &frames {
                assert!(matches!(decoder.decode(&frame.data, &mut texture), Ok(Decoded::Picture)));
                check(&texture, width, height);
            }
            assert!(decoder.started());
        }
    }

    #[test]
    fn h264_pictures_keep_their_size_and_colour() {
        let (width, height) = (1366, 768);
        let cfg = EncoderCfg::HWRAM(config("h264_videotoolbox", width, height));
        let Ok(mut encoder) = HwRamEncoder::new(cfg, false) else {
            eprintln!("no H.264 VideoToolbox encoder here; skipped");
            return;
        };
        let frames = encode(&mut encoder, 3, 0);
        assert!(!frames.is_empty());
        let mut decoder = VtDecoder::new(false).unwrap();
        let mut texture = ImageTexture::default();
        for frame in &frames {
            assert!(matches!(decoder.decode(&frame.data, &mut texture), Ok(Decoded::Picture)));
            check(&texture, width, height);
        }
    }

    #[test]
    fn a_frame_before_the_first_keyframe_is_left_to_ffmpeg() {
        let cfg = EncoderCfg::HWRAM(config("hevc_videotoolbox", 640, 480));
        let Ok(mut encoder) = NikoVtEncoder::new(cfg, false) else {
            eprintln!("no hardware HEVC encoder here; skipped");
            return;
        };
        let frames = encode(&mut encoder, 2, 0);
        assert!(frames[0].key && !frames[1].key);
        let mut decoder = VtDecoder::new(true).unwrap();
        let mut texture = ImageTexture::default();
        assert!(matches!(decoder.decode(&frames[1].data, &mut texture), Ok(Decoded::NotYet)));
        assert!(matches!(decoder.decode(&frames[0].data, &mut texture), Ok(Decoded::Picture)));
        assert!(matches!(decoder.decode(&frames[1].data, &mut texture), Ok(Decoded::Picture)));
    }

    fn cpu() -> std::time::Duration {
        use hbb_common::libc::{getrusage, rusage, RUSAGE_SELF};
        let mut usage: rusage = unsafe { std::mem::zeroed() };
        unsafe { getrusage(RUSAGE_SELF, &mut usage) };
        let time = |t: hbb_common::libc::timeval| {
            std::time::Duration::new(t.tv_sec as u64, t.tv_usec as u32 * 1000)
        };
        time(usage.ru_utime) + time(usage.ru_stime)
    }

    /// Cost of a moving 4K picture: ffmpeg's VideoToolbox decode, its copies
    /// and RGBA conversion and the texture plugin's copy, against this decoder.
    /// `cargo test -p scrap --features nikodesk,hwcodec decode_cost -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn decode_cost() {
        use crate::convert::NV12ToARGB;
        use hwcodec::{
            ffmpeg::AVHWDeviceType,
            ffmpeg_ram::decode::{DecodeContext, Decoder},
        };
        use std::time::Instant;
        let (width, height, count) = (3840, 2160, 120);
        let cfg = EncoderCfg::HWRAM(config("hevc_videotoolbox", width, height));
        let Ok(mut encoder) = NikoVtEncoder::new(cfg, false) else {
            eprintln!("no hardware HEVC encoder here; skipped");
            return;
        };
        let frames = encode(&mut encoder, count, 16);
        assert_eq!(frames.len(), count);
        let mut ffmpeg = Decoder::new(DecodeContext {
            name: "hevc".into(),
            device_type: AVHWDeviceType::AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
            thread_count: 4,
        })
        .unwrap();
        let (mut argb, mut texture_copy) = (vec![0u8; width * height * 4], vec![0u8; width * height * 4]);
        let (wall, used) = (Instant::now(), cpu());
        let mut pictures = 0;
        for frame in &frames {
            for image in ffmpeg.decode(&frame.data).unwrap() {
                let result = unsafe {
                    NV12ToARGB(
                        image.data[0].as_ptr(),
                        image.linesize[0],
                        image.data[1].as_ptr(),
                        image.linesize[1],
                        argb.as_mut_ptr(),
                        (width * 4) as _,
                        width as _,
                        height as _,
                    )
                };
                assert_eq!(result, 0);
                texture_copy.copy_from_slice(&argb);
                pictures += 1;
            }
        }
        let old = (wall.elapsed() / pictures, (cpu() - used) / pictures, pictures);
        let mut decoder = VtDecoder::new(true).unwrap();
        let mut texture = ImageTexture::default();
        let (wall, used) = (Instant::now(), cpu());
        let mut pictures = 0;
        for frame in &frames {
            if matches!(decoder.decode(&frame.data, &mut texture), Ok(Decoded::Picture)) {
                pictures += 1;
            }
        }
        let new = (wall.elapsed() / pictures, (cpu() - used) / pictures, pictures);
        eprintln!("4K HEVC per picture: ffmpeg path wall {:?} cpu {:?} ({} pictures); VideoToolbox texture wall {:?} cpu {:?} ({} pictures)",
            old.0, old.1, old.2, new.0, new.1, new.2);
        assert_eq!(new.2, count as u32);
    }
}
