use super::layout::{self, Color, Pixels};
use std::{fmt, io};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code {
    Native,
    MediaUnavailable,
    Permission,
    OrdinaryUser,
    InvalidDevice,
    InvalidFormat,
    UnsupportedFormat,
    InvalidLayout,
    Stale,
    Busy,
    StartPending,
    StopPending,
    Closed,
}
impl Code {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Native => "native",
            Self::MediaUnavailable => "media-unavailable",
            Self::Permission => "permission",
            Self::OrdinaryUser => "ordinary-user",
            Self::InvalidDevice => "invalid-device",
            Self::InvalidFormat => "invalid-format",
            Self::UnsupportedFormat => "unsupported-format",
            Self::InvalidLayout => "invalid-layout",
            Self::Stale => "stale",
            Self::Busy => "busy",
            Self::StartPending => "start-pending",
            Self::StopPending => "stop-pending",
            Self::Closed => "closed",
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Failure {
    pub code: Code,
    pub hresult: i32,
}
impl Failure {
    pub fn new(code: Code) -> Self {
        Self { code, hresult: 0 }
    }
    pub fn io(self) -> io::Error {
        let kind = match self.code {
            Code::Permission | Code::OrdinaryUser => io::ErrorKind::PermissionDenied,
            Code::InvalidDevice | Code::InvalidFormat | Code::InvalidLayout | Code::Stale => {
                io::ErrorKind::InvalidInput
            }
            Code::MediaUnavailable | Code::UnsupportedFormat => io::ErrorKind::Unsupported,
            Code::Busy => io::ErrorKind::AddrInUse,
            Code::StartPending | Code::StopPending => io::ErrorKind::TimedOut,
            Code::Closed => io::ErrorKind::ConnectionAborted,
            _ => io::ErrorKind::Other,
        };
        // No driver messages, paths, friendly names or symbolic links in errors.
        io::Error::new(
            kind,
            format!(
                "Niko camera {} HRESULT={:08x}",
                self.code.as_str(),
                self.hresult as u32
            ),
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CameraAuthorization {
    NotDetermined,
    Restricted,
    Denied,
    Authorized,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct NativeFormatKey {
    pub stream: u32,
    pub stream_id: u32,
    pub subtype: u128,
    pub width: u32,
    pub height: u32,
    pub fps_num: u32,
    pub fps_den: u32,
    pub stride: i32,
    pub pixels: Pixels,
    pub color: Option<Color>,
    pub matrix: u32,
    pub range: u32,
    pub interlace: u32,
    pub pixel_aspect: u64,
    pub attributes: Vec<u8>,
}

/// Returned only by explicit local probing. No public constructor: JSON must
/// refer to the saved object through a connection/revision-scoped opaque token.
#[derive(Clone, PartialEq, Eq)]
pub struct CameraFormat {
    pub width: u32,
    pub height: u32,
    pub(super) key: NativeFormatKey,
    pub(super) device_id: String,
    pub(super) epoch: u64,
}
impl CameraFormat {
    pub fn fps_num(&self) -> u32 {
        self.key.fps_num
    }
    pub fn fps_den(&self) -> u32 {
        self.key.fps_den
    }
    /// Canonical bytes for the core's scope hash only, never a format constructor
    /// or a UI field. A saved native object remains required for selection.
    pub fn identity_bytes(&self) -> Vec<u8> {
        let k = &self.key;
        let mut bytes = b"NikoCameraMF-v1\0".to_vec();
        bytes.extend_from_slice(&(self.device_id.len() as u32).to_le_bytes());
        bytes.extend_from_slice(self.device_id.as_bytes());
        bytes.extend_from_slice(&self.epoch.to_le_bytes());
        bytes.extend_from_slice(&self.width.to_le_bytes());
        bytes.extend_from_slice(&self.height.to_le_bytes());
        bytes.extend_from_slice(&k.subtype.to_le_bytes());
        for value in [
            k.stream,
            k.stream_id,
            k.width,
            k.height,
            k.fps_num,
            k.fps_den,
            k.stride as u32,
            k.matrix,
            k.range,
            k.interlace,
        ] {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        bytes.extend_from_slice(&k.pixel_aspect.to_le_bytes());
        bytes.extend_from_slice(&(k.attributes.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&k.attributes);
        bytes.push(match k.pixels {
            Pixels::Bgra => 1,
            Pixels::Bgrx => 2,
            Pixels::Nv12 => 3,
            Pixels::Yuy2 => 4,
        });
        bytes.push(match k.color {
            None => 0,
            Some(Color::Bt601Limited) => 1,
            Some(Color::Bt601Full) => 2,
            Some(Color::Bt709Limited) => 3,
            Some(Color::Bt709Full) => 4,
        });
        bytes
    }
}
impl fmt::Debug for CameraFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CameraFormat")
            .field("width", &self.width)
            .field("height", &self.height)
            .field("fps_num", &self.fps_num())
            .field("fps_den", &self.fps_den())
            .finish()
    }
}
#[derive(Clone)]
pub struct CameraDevice {
    pub unique_id: String,
    pub name: String,
    pub formats: Vec<CameraFormat>,
}
impl fmt::Debug for CameraDevice {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CameraDevice")
            .field("formats", &self.formats)
            .finish_non_exhaustive()
    }
}
#[derive(Clone)]
pub struct CaptureSelection {
    pub unique_id: String,
    pub format: CameraFormat,
    pub epoch: u64,
}
pub(super) fn validate_id(id: &str, epoch: u64) -> Result<(), Failure> {
    if id.is_empty() || id.len() > 1024 || id.contains('\0') || epoch == 0 {
        Err(Failure::new(Code::InvalidDevice))
    } else {
        Ok(())
    }
}
impl CaptureSelection {
    pub fn validate(&self) -> io::Result<()> {
        self.validate_native().map_err(Failure::io)
    }
    pub(super) fn validate_native(&self) -> Result<(), Failure> {
        validate_id(&self.unique_id, self.epoch)?;
        let f = &self.format;
        let k = &f.key;
        layout::dimensions(f.width, f.height)?;
        if f.device_id != self.unique_id || f.epoch != self.epoch {
            return Err(Failure::new(Code::Stale));
        }
        if f.width != k.width
            || f.height != k.height
            || k.fps_num == 0
            || k.fps_den == 0
            || u64::from(k.fps_num) > 60 * u64::from(k.fps_den)
            || k.stream >= 32
            || k.attributes.len() > 2048
        {
            return Err(Failure::new(Code::InvalidFormat));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selection() -> CaptureSelection {
        CaptureSelection {
            unique_id: "exact-id".into(),
            epoch: 9,
            format: CameraFormat {
                width: 2,
                height: 2,
                device_id: "exact-id".into(),
                epoch: 9,
                key: NativeFormatKey {
                    stream: 0,
                    stream_id: 7,
                    subtype: 1,
                    width: 2,
                    height: 2,
                    fps_num: 30000,
                    fps_den: 1001,
                    stride: 8,
                    pixels: Pixels::Bgrx,
                    color: None,
                    matrix: 0,
                    range: 0,
                    interlace: 2,
                    pixel_aspect: 1u64 << 32 | 1,
                    attributes: vec![1, 2, 3],
                },
            },
        }
    }
    #[test]
    fn exact_device_epoch_and_fractional_format_are_preserved() {
        let mut s = selection();
        assert!(s.validate().is_ok());
        assert_eq!((s.format.fps_num(), s.format.fps_den()), (30000, 1001));
        s.unique_id = "another-id".into();
        assert!(s.validate().is_err());
        s = selection();
        s.epoch += 1;
        assert!(s.validate().is_err());
        s = selection();
        s.format.width += 2;
        assert!(s.validate().is_err());
    }
    #[test]
    fn no_integer_fps_alias_or_invalid_id_is_accepted() {
        let mut s = selection();
        s.format.key.fps_den = 0;
        assert!(s.validate().is_err());
        s = selection();
        s.format.key.fps_num = 61000;
        s.format.key.fps_den = 1000;
        assert!(s.validate().is_err());
        s = selection();
        s.unique_id.push('\0');
        assert!(s.validate().is_err());
    }
    #[test]
    fn errors_and_debug_do_not_disclose_device_paths() {
        let s = selection();
        assert!(!format!("{:?}", s.format).contains("exact-id"));
        let d = CameraDevice {
            unique_id: s.unique_id,
            name: "private-name".into(),
            formats: vec![s.format],
        };
        assert!(!format!("{:?}", d).contains("private-name"));
        assert_eq!(
            Failure::new(Code::Permission).io().kind(),
            io::ErrorKind::PermissionDenied
        );
    }
    #[test]
    fn scope_identity_covers_every_native_discriminator_and_is_bounded() {
        let s = selection();
        let baseline = s.format.identity_bytes();
        let mut changes: Vec<Box<dyn Fn(&mut CameraFormat)>> = vec![
            Box::new(|f| f.key.subtype += 1),
            Box::new(|f| f.key.stream += 1),
            Box::new(|f| f.key.stream_id += 1),
            Box::new(|f| f.key.fps_num += 1),
            Box::new(|f| f.key.fps_den += 1),
            Box::new(|f| f.key.stride *= -1),
            Box::new(|f| f.key.matrix += 1),
            Box::new(|f| f.key.range += 1),
            Box::new(|f| f.key.interlace += 1),
            Box::new(|f| f.key.pixel_aspect += 1),
            Box::new(|f| f.key.attributes.push(4)),
            Box::new(|f| f.epoch += 1),
            Box::new(|f| f.device_id.push('x')),
            Box::new(|f| f.key.pixels = Pixels::Bgra),
            Box::new(|f| f.key.color = Some(Color::Bt601Limited)),
        ];
        for change in changes.drain(..) {
            let mut f = s.format.clone();
            change(&mut f);
            assert_ne!(baseline, f.identity_bytes());
        }
        let mut f = s.format;
        f.device_id = "x".repeat(1024);
        f.key.attributes = vec![0; 2048];
        assert!(f.identity_bytes().len() <= 4096);
    }
}
