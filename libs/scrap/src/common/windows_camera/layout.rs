//! Owned CPU frames. Never lend an MF lock or a COM pointer to the encoder.
use super::{Code, Failure};
use crate::{
    kYuvF709Constants, kYuvH709Constants, kYuvI601Constants, kYuvJPEGConstants, I420ToARGBMatrix,
    NV12ToARGBMatrix, YUY2ToI420, YuvConstants,
};
use std::convert::TryFrom;

pub const MAX_BYTES: usize = 64 * 1024 * 1024;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pixels {
    Bgra,
    Bgrx,
    Nv12,
    Yuy2,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Bt601Limited,
    Bt601Full,
    Bt709Limited,
    Bt709Full,
}

pub struct OwnedFrame {
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub epoch: u64,
}

pub fn dimensions(width: u32, height: u32) -> Result<usize, Failure> {
    if width == 0
        || height == 0
        || width > 4096
        || height > 4096
        || width % 2 != 0
        || height % 2 != 0
    {
        return Err(Failure::new(Code::InvalidFormat));
    }
    (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
        .filter(|n| *n <= MAX_BYTES)
        .ok_or_else(|| Failure::new(Code::InvalidLayout))
}

/// `first` is scanline zero's offset within a *verified* allocation. Signed
/// arithmetic validates every row before any native bytes are read.
pub fn copy_rows(
    bytes: &[u8],
    first: usize,
    pitch: i32,
    row_bytes: usize,
    rows: usize,
) -> Result<Vec<u8>, Failure> {
    let size = row_bytes
        .checked_mul(rows)
        .filter(|n| *n <= MAX_BYTES)
        .ok_or_else(|| Failure::new(Code::InvalidLayout))?;
    if rows == 0
        || row_bytes == 0
        || i64::from(pitch).abs() < row_bytes as i64
        || bytes.len() > MAX_BYTES
    {
        return Err(Failure::new(Code::InvalidLayout));
    }
    let mut offsets = Vec::with_capacity(rows);
    for row in 0..rows {
        let offset = i64::try_from(first)
            .ok()
            .and_then(|n| n.checked_add(i64::from(pitch) * row as i64))
            .and_then(|n| usize::try_from(n).ok())
            .ok_or_else(|| Failure::new(Code::InvalidLayout))?;
        let end = offset
            .checked_add(row_bytes)
            .filter(|n| *n <= bytes.len())
            .ok_or_else(|| Failure::new(Code::InvalidLayout))?;
        offsets.push(offset..end);
    }
    let mut result = Vec::with_capacity(size);
    for range in offsets {
        result.extend_from_slice(&bytes[range]);
    }
    Ok(result)
}

pub fn normalize(
    bytes: &[u8],
    first: usize,
    pitch: i32,
    width: u32,
    height: u32,
    pixels: Pixels,
    color: Option<Color>,
    epoch: u64,
) -> Result<OwnedFrame, Failure> {
    let length = dimensions(width, height)?;
    if epoch == 0 {
        return Err(Failure::new(Code::Stale));
    }
    let w = width as usize;
    let h = height as usize;
    let row_bytes = match pixels {
        Pixels::Bgra | Pixels::Bgrx => w * 4,
        Pixels::Yuy2 => w * 2,
        Pixels::Nv12 => w,
    };
    // NV12 is top-down, Y then interleaved UV with the same actual pitch.
    if pixels == Pixels::Nv12 && pitch <= 0 {
        return Err(Failure::new(Code::InvalidLayout));
    }
    let rows = if pixels == Pixels::Nv12 { h + h / 2 } else { h };
    let tight = copy_rows(bytes, first, pitch, row_bytes, rows)?;
    let mut data = vec![0; length];
    if matches!(pixels, Pixels::Bgra | Pixels::Bgrx) {
        data.copy_from_slice(&tight);
        // The encoder uses opaque camera pictures, including RGB32's unused X.
        for pixel in data.chunks_exact_mut(4) {
            pixel[3] = 255;
        }
    } else {
        let matrix = unsafe {
            (match color.ok_or_else(|| Failure::new(Code::UnsupportedFormat))? {
                Color::Bt601Limited => &kYuvI601Constants,
                Color::Bt601Full => &kYuvJPEGConstants,
                Color::Bt709Limited => &kYuvH709Constants,
                Color::Bt709Full => &kYuvF709Constants,
            }) as *const YuvConstants
        };
        let result = if pixels == Pixels::Nv12 {
            unsafe {
                NV12ToARGBMatrix(
                    tight.as_ptr(),
                    width as i32,
                    tight[w * h..].as_ptr(),
                    width as i32,
                    data.as_mut_ptr(),
                    width as i32 * 4,
                    matrix,
                    width as i32,
                    height as i32,
                )
            }
        } else {
            let mut i420 = vec![0; w * h * 3 / 2];
            let (y, chroma) = i420.split_at_mut(w * h);
            let (u, v) = chroma.split_at_mut(w * h / 4);
            let decoded = unsafe {
                YUY2ToI420(
                    tight.as_ptr(),
                    width as i32 * 2,
                    y.as_mut_ptr(),
                    width as i32,
                    u.as_mut_ptr(),
                    width as i32 / 2,
                    v.as_mut_ptr(),
                    width as i32 / 2,
                    width as i32,
                    height as i32,
                )
            };
            if decoded != 0 {
                return Err(Failure::new(Code::InvalidLayout));
            }
            unsafe {
                I420ToARGBMatrix(
                    y.as_ptr(),
                    width as i32,
                    u.as_ptr(),
                    width as i32 / 2,
                    v.as_ptr(),
                    width as i32 / 2,
                    data.as_mut_ptr(),
                    width as i32 * 4,
                    matrix,
                    width as i32,
                    height as i32,
                )
            }
        };
        if result != 0 {
            return Err(Failure::new(Code::InvalidLayout));
        }
    }
    Ok(OwnedFrame {
        data,
        width,
        height,
        epoch,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn padded_and_bottom_up_rows_are_checked() {
        assert_eq!(
            copy_rows(&[1, 2, 9, 9, 3, 4, 9, 9], 0, 4, 2, 2).unwrap(),
            [1, 2, 3, 4]
        );
        assert_eq!(
            copy_rows(&[1, 2, 9, 9, 3, 4, 9, 9], 4, -4, 2, 2).unwrap(),
            [3, 4, 1, 2]
        );
        assert!(copy_rows(&[0; 8], 0, -4, 2, 2).is_err());
        assert!(copy_rows(&[0; 8], usize::MAX, 4, 2, 2).is_err());
        assert!(copy_rows(&[0; 8], 0, 1, 2, 2).is_err());
    }
    #[test]
    fn dimensions_and_truncated_nv12_fail_closed() {
        for (w, h) in [(0, 2), (3, 2), (2, 3), (8192, 2)] {
            assert!(dimensions(w, h).is_err());
        }
        assert!(normalize(
            &[0; 4],
            0,
            2,
            2,
            2,
            Pixels::Nv12,
            Some(Color::Bt601Limited),
            1
        )
        .is_err());
        assert!(normalize(
            &[0; 6],
            4,
            -2,
            2,
            2,
            Pixels::Nv12,
            Some(Color::Bt601Limited),
            1
        )
        .is_err());
        assert!(normalize(&[0; 6], 0, 2, 2, 2, Pixels::Nv12, None, 1).is_err());
    }
    #[test]
    fn rgbx_owned_frame_has_opaque_alpha_and_epoch() {
        let f = normalize(&[1; 16], 0, 8, 2, 2, Pixels::Bgrx, None, 7).unwrap();
        assert_eq!(f.epoch, 7);
        assert_eq!(
            f.data,
            [1, 1, 1, 255, 1, 1, 1, 255, 1, 1, 1, 255, 1, 1, 1, 255]
        );
        assert!(normalize(&[1; 16], 0, 8, 2, 2, Pixels::Bgra, None, 0).is_err());
    }
    #[test]
    fn actual_libyuv_nv12_and_yuy2_black_white() {
        let black = normalize(
            &[16, 16, 16, 16, 128, 128],
            0,
            2,
            2,
            2,
            Pixels::Nv12,
            Some(Color::Bt601Limited),
            1,
        )
        .unwrap();
        assert!(black.data.chunks_exact(4).all(|p| p == [0, 0, 0, 255]));
        let white = normalize(
            &[235, 128, 235, 128, 235, 128, 235, 128],
            0,
            4,
            2,
            2,
            Pixels::Yuy2,
            Some(Color::Bt709Limited),
            1,
        )
        .unwrap();
        assert!(white
            .data
            .chunks_exact(4)
            .all(|p| p == [255, 255, 255, 255]));
    }
}
