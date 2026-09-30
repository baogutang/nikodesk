//! Optional Windows capabilities must not raise the desktop client's minimum OS.
use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TerminalSupportError {
    Unsupported,
    ProbeUnavailable,
}

impl fmt::Display for TerminalSupportError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unsupported => {
                "Terminal is unsupported on this Windows system. ConPTY requires Windows 10 version 1809 or later. Screen control remains available."
            }
            Self::ProbeUnavailable => {
                "Terminal support could not be verified on this Windows system. Screen control remains available."
            }
        })
    }
}

impl std::error::Error for TerminalSupportError {}

fn require_conpty(
    exports: Result<[bool; 3], TerminalSupportError>,
) -> Result<(), TerminalSupportError> {
    if exports?.iter().all(|available| *available) {
        Ok(())
    } else {
        Err(TerminalSupportError::Unsupported)
    }
}

#[cfg(target_os = "windows")]
pub(crate) fn check_terminal_support() -> Result<(), TerminalSupportError> {
    use ::windows::{
        core::{s, w},
        Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress},
    };

    // Do not load a side DLL, allocate a pseudoconsole, or call these functions.
    let kernel = unsafe { GetModuleHandleW(w!("kernel32.dll")) }
        .map_err(|_| TerminalSupportError::ProbeUnavailable)?;
    let exports = unsafe {
        [
            GetProcAddress(kernel, s!("CreatePseudoConsole")).is_some(),
            GetProcAddress(kernel, s!("ResizePseudoConsole")).is_some(),
            GetProcAddress(kernel, s!("ClosePseudoConsole")).is_some(),
        ]
    };
    require_conpty(Ok(exports))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_three_exports_are_required() {
        assert_eq!(require_conpty(Ok([true; 3])), Ok(()));
        for mask in 0_u8..7 {
            let exports = [mask & 1 != 0, mask & 2 != 0, mask & 4 != 0];
            assert_eq!(
                require_conpty(Ok(exports)),
                Err(TerminalSupportError::Unsupported)
            );
        }
    }

    #[test]
    fn probe_failure_is_not_reported_as_an_old_os_or_supported() {
        assert_eq!(
            require_conpty(Err(TerminalSupportError::ProbeUnavailable)),
            Err(TerminalSupportError::ProbeUnavailable)
        );
    }

    #[test]
    fn errors_are_bounded_and_keep_screen_control_separate() {
        for error in [
            TerminalSupportError::Unsupported,
            TerminalSupportError::ProbeUnavailable,
        ] {
            let message = error.to_string();
            assert!(message.is_ascii());
            assert!(message.len() <= 160);
            assert!(message.contains("Screen control remains available."));
            assert!(!message.contains('\n'));
        }
        assert!(TerminalSupportError::Unsupported
            .to_string()
            .contains("Windows 10 version 1809 or later"));
        assert!(!TerminalSupportError::ProbeUnavailable
            .to_string()
            .contains("1809"));
    }
}
