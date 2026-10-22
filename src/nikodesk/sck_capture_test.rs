//! The ScreenCaptureKit main capture (`scrap::nikodesk_sck`) against the real
//! display. It lives here because scrap's own tests cannot link the display
//! helpers defined in this crate.
use scrap::{nikodesk_sck::SckCapturer, Display, Frame, TraitCapturer, TraitPixelBuffer};
use std::{
    io,
    time::{Duration, Instant},
};

// Needs the Screen Recording permission; skipped without it (CI). The picture
// stays in memory.
#[test]
fn a_full_picture_comes_from_the_main_display() {
    let Ok(display) = Display::primary() else {
        return;
    };
    let mut capturer = match SckCapturer::new(&display, false) {
        Ok(capturer) => capturer,
        Err(error) => {
            eprintln!("no ScreenCaptureKit capture here ({error}); skipped");
            return;
        }
    };
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match capturer.frame(Duration::from_millis(30)) {
            Ok(Frame::PixelBuffer(picture)) => {
                assert_eq!(
                    (picture.width(), picture.height()),
                    (display.width(), display.height())
                );
                assert!(picture.stride()[0] >= display.width() * 4);
                assert!(picture.data().len() >= picture.stride()[0] * display.height());
                break;
            }
            Ok(Frame::Texture(_)) => panic!("asked for pixels"),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => panic!("no picture: {error}"),
        }
    }
}
