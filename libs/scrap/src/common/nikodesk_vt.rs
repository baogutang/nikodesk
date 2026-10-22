//! NikoDesk's own VideoToolbox HEVC session in place of ffmpeg's for the same
//! hardware encoder (see nikodesk_vt.mm). Each frame's bitstream is returned
//! from the call that encoded it instead of a later one. On by default since
//! the 2026-10-20 A/B (host CPU 3-5% instead of 15-31%, equal or lower round
//! trips); the option `nikodesk-native-encoder` = "N" turns it off, and "all"
//! also uses it above 4K. A failure turns it off for the rest of the process
//! and falls back to ffmpeg's.
use crate::{
    codec::{EncoderApi, EncoderCfg},
    hwcodec::{HwRamEncoder, HwRamEncoderConfig},
    EncodeInput, EncodeYuvFormat, Pixfmt,
};
use base::message_proto::{EncodedVideoFrame, EncodedVideoFrames, VideoFrame};
use hbb_common::{
    anyhow::{anyhow, bail},
    bytes::Bytes,
    config::Config,
    log, ResultType,
};
use std::{
    ffi::c_void,
    sync::atomic::{AtomicBool, Ordering},
};

extern "C" {
    fn NVTCreate(width: u32, height: u32, kbps: u32, gop: i32) -> *mut c_void;
    fn NVTLayout(session: *mut c_void, y_stride: *mut usize, uv_stride: *mut usize) -> bool;
    fn NVTEncodeNV12(
        session: *mut c_void,
        y: *const u8,
        y_stride: usize,
        uv: *const u8,
        uv_stride: usize,
        pts: i64,
        key: bool,
        wait_ms: u32,
    ) -> i32;
    fn NVTEncodeSurface(session: *mut c_void, surface: *mut c_void, pts: i64, key: bool, wait_ms: u32) -> i32;
    fn NVTTake(
        session: *mut c_void,
        data: *mut *const u8,
        length: *mut usize,
        pts: *mut i64,
        key: *mut bool,
    ) -> bool;
    fn NVTSetBitrate(session: *mut c_void, kbps: u32) -> bool;
    fn NVTRelease(session: *mut c_void);
}

const OPTION: &str = "nikodesk-native-encoder";
const NAME: &str = "hevc_videotoolbox";
/// Longer than a frame takes at 8K; a frame still encoding after this is
/// returned with a later one.
const WAIT_MS: u32 = 60;
/// A new session's first frame took up to 77 ms on an M1 Max, and a first
/// frame that returns nothing makes the video service give the encoder up.
const FIRST_WAIT_MS: u32 = 250;

static DISABLED: AtomicBool = AtomicBool::new(false);

/// Up to 4K only, for now. At 5K it reaches its 6.5 Mbit/s target, three
/// times what ffmpeg's session actually sent, and three of five test
/// sessions through the tunnel nearly stalled (none at 3K or 4K, none with
/// ffmpeg's); larger captures stay on ffmpeg's until that is understood.
const MAX_PIXELS: usize = 3840 * 2160;

fn size_allowed(width: usize, height: usize, option: &str) -> bool {
    width * height <= MAX_PIXELS || option == "all"
}

/// Whether this hardware encoder runs on the native session.
pub fn wanted(config: &HwRamEncoderConfig) -> bool {
    let option = Config::get_option(OPTION);
    config.name == NAME
        && size_allowed(config.width, config.height, &option)
        && !DISABLED.load(Ordering::Acquire)
        && option != "N"
}

pub fn disable() {
    DISABLED.store(true, Ordering::Release);
}

pub fn is_disabled() -> bool {
    DISABLED.load(Ordering::Acquire)
}

/// Whether a capture of this size should hand IOSurfaces over: only when the
/// native session will encode it, i.e. HEVC through hevc_videotoolbox.
pub fn texture_wanted(width: usize, height: usize) -> bool {
    let option = Config::get_option(OPTION);
    size_allowed(width, height, &option)
        && !is_disabled()
        && option != "N"
        && crate::codec::Encoder::negotiated_codec() == crate::CodecFormat::H265
        && HwRamEncoder::try_get(crate::CodecFormat::H265).is_some_and(|info| info.name == NAME)
}

pub struct NikoVtEncoder {
    session: usize,
    config: HwRamEncoderConfig,
    y_stride: usize,
    uv_stride: usize,
    bitrate: u32,
    started: bool,
}

// The session serializes its own state; the pointer is only used by its owner.
unsafe impl Send for NikoVtEncoder {}

impl Drop for NikoVtEncoder {
    fn drop(&mut self) {
        unsafe { NVTRelease(self.session as _) };
    }
}

impl EncoderApi for NikoVtEncoder {
    fn new(cfg: EncoderCfg, _i444: bool) -> ResultType<Self> {
        let EncoderCfg::HWRAM(config) = cfg else {
            bail!("encoder type mismatch");
        };
        let bitrate = HwRamEncoder::check_bitrate_range(
            &config,
            HwRamEncoder::bitrate(&config.name, config.width, config.height, config.quality),
        );
        let gop = config.keyframe_interval.map_or(0, |gop| gop.min(i32::MAX as usize) as i32);
        let session = unsafe { NVTCreate(config.width as _, config.height as _, bitrate, gop) };
        if session.is_null() {
            bail!("native VideoToolbox session unavailable");
        }
        let (mut y_stride, mut uv_stride) = (0, 0);
        if !unsafe { NVTLayout(session, &mut y_stride, &mut uv_stride) }
            || y_stride < config.width
            || uv_stride < config.width
        {
            unsafe { NVTRelease(session) };
            bail!("native VideoToolbox buffer layout unavailable");
        }
        log::info!(
            "NikoDesk VideoToolbox session: {}x{}, {} kbps",
            config.width,
            config.height,
            bitrate
        );
        Ok(Self {
            session: session as usize,
            config,
            y_stride,
            uv_stride,
            bitrate,
            started: false,
        })
    }

    fn encode_to_message(&mut self, input: EncodeInput, ms: i64) -> ResultType<VideoFrame> {
        let session = self.session as *mut c_void;
        let wait = if self.started { WAIT_MS } else { FIRST_WAIT_MS };
        self.started = true;
        let status = match input {
            EncodeInput::YUV(yuv) => {
                let y_size = self.y_stride * self.config.height;
                let uv_size = self.uv_stride * ((self.config.height + 1) / 2);
                if yuv.len() < y_size + uv_size {
                    bail!("frame smaller than its layout");
                }
                unsafe {
                    NVTEncodeNV12(
                        session,
                        yuv.as_ptr(),
                        self.y_stride,
                        yuv[y_size..].as_ptr(),
                        self.uv_stride,
                        ms,
                        false,
                        wait,
                    )
                }
            }
            EncodeInput::Texture((surface, _)) => unsafe {
                NVTEncodeSurface(session, surface, ms, false, wait)
            },
        };
        if status < 0 {
            bail!("native VideoToolbox encode failed");
        }
        let mut frames = Vec::new();
        let (mut data, mut length, mut pts, mut key) = (std::ptr::null(), 0, 0, false);
        while unsafe { NVTTake(session, &mut data, &mut length, &mut pts, &mut key) } {
            frames.push(EncodedVideoFrame {
                data: Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(data, length) }),
                pts,
                key,
                ..Default::default()
            });
        }
        if frames.is_empty() {
            return Err(anyhow!("no valid frame"));
        }
        let mut vf = VideoFrame::new();
        vf.set_h265s(EncodedVideoFrames {
            frames: frames.into(),
            ..Default::default()
        });
        Ok(vf)
    }

    fn yuvfmt(&self) -> EncodeYuvFormat {
        EncodeYuvFormat {
            pixfmt: Pixfmt::NV12,
            w: self.config.width,
            h: self.config.height,
            stride: vec![self.y_stride, self.uv_stride],
            u: self.y_stride * self.config.height,
            v: 0,
        }
    }

    #[cfg(feature = "vram")]
    fn input_texture(&self) -> bool {
        false
    }

    fn set_quality(&mut self, ratio: f32) -> ResultType<()> {
        let bitrate = HwRamEncoder::bitrate(NAME, self.config.width, self.config.height, ratio);
        if bitrate > 0 {
            let bitrate = HwRamEncoder::check_bitrate_range(&self.config, bitrate);
            if unsafe { NVTSetBitrate(self.session as _, bitrate) } {
                self.bitrate = bitrate;
            }
        }
        self.config.quality = ratio;
        Ok(())
    }

    fn bitrate(&self) -> u32 {
        self.bitrate
    }

    fn support_changing_quality(&self) -> bool {
        true
    }

    // Each call waits for its own frame, so nothing has to be pushed out by
    // encoding the last picture again.
    fn latency_free(&self) -> bool {
        true
    }

    fn is_hardware(&self) -> bool {
        true
    }

    // Repeated failures fall back to ffmpeg's session for the same hardware
    // encoder, rather than to software.
    fn disable(&self) {
        log::warn!("NikoDesk VideoToolbox session disabled after repeated failures");
        disable();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> HwRamEncoderConfig {
        HwRamEncoderConfig {
            name: NAME.into(),
            mc_name: None,
            width: 640,
            height: 480,
            quality: 1.0,
            keyframe_interval: None,
        }
    }

    // Needs a hardware HEVC encoder; skipped where there is none (CI VMs).
    #[test]
    fn first_frame_is_an_annex_b_keyframe_starting_with_the_parameter_sets() {
        let Ok(mut encoder) = NikoVtEncoder::new(EncoderCfg::HWRAM(config()), false) else {
            eprintln!("no hardware HEVC encoder here; skipped");
            return;
        };
        let format = encoder.yuvfmt();
        assert_eq!(format.pixfmt, Pixfmt::NV12);
        let mut yuv = vec![128u8; format.u + format.stride[1] * 240];
        for pts in [0, 33] {
            let frame = encoder
                .encode_to_message(EncodeInput::YUV(&mut yuv), pts)
                .expect("a frame from each call");
            let frames = frame.h265s().frames.clone();
            assert_eq!(frames.len(), 1);
            let data = &frames[0].data;
            assert_eq!(&data[..4], &[0, 0, 0, 1]);
            assert_eq!(frames[0].pts, pts);
            if pts == 0 {
                assert!(frames[0].key);
                assert_eq!((data[4] >> 1) & 0x3f, 32, "VPS first");
            } else {
                assert!(!frames[0].key);
            }
        }
        encoder.set_quality(0.5).unwrap();
        assert!(encoder.bitrate() > 0);
    }

    #[test]
    fn only_videotoolbox_hevc_up_to_4k() {
        let mut other = config();
        other.name = "h264_videotoolbox".into();
        assert!(!wanted(&other));
        let mut large = config();
        (large.width, large.height) = (5120, 2880);
        assert!(!wanted(&large));
        assert!(!texture_wanted(5120, 2880));
        assert!(size_allowed(5120, 2880, "all"));
        assert!(!size_allowed(5120, 2880, "Y"));
    }
}
