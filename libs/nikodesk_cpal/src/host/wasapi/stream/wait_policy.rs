//! Niko's bounded fallback for render-loopback capture. No device or OS calls.

const INFINITE: u32 = u32::MAX;
const WAIT_TIMEOUT: u32 = 0x102;
const WAIT_FAILED: u32 = u32::MAX;
pub(super) const LOOPBACK_POLL_MS: u32 = 10;
pub(super) const LOOPBACK_PACKET_BATCH: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Wake {
    Command,
    Audio,
    LoopbackPoll,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum WaitError {
    Failed,
    Unexpected(u32),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct WaitPlan {
    pub handle_count: usize,
    pub timeout_ms: u32,
}

pub(super) struct WaitPolicy {
    loopback: bool,
    playing: bool,
}

impl WaitPolicy {
    pub fn new(loopback: bool, playing: bool) -> Self {
        Self { loopback, playing }
    }

    pub fn wait(&self, wait: impl FnOnce(WaitPlan) -> u32) -> Result<Wake, WaitError> {
        let plan = WaitPlan {
            // Paused loopback ignores a lingering capture event and blocks on commands.
            handle_count: if self.loopback && !self.playing { 1 } else { 2 },
            timeout_ms: if self.loopback && self.playing {
                LOOPBACK_POLL_MS
            } else {
                INFINITE
            },
        };
        match wait(plan) {
            0 => Ok(Wake::Command),
            1 if plan.handle_count == 2 => Ok(Wake::Audio),
            WAIT_TIMEOUT if self.loopback && self.playing => Ok(Wake::LoopbackPoll),
            WAIT_FAILED => Err(WaitError::Failed),
            value => Err(WaitError::Unexpected(value)),
        }
    }
}

pub(super) fn batch_complete(loopback: bool, packets: usize) -> bool {
    loopback && packets >= LOOPBACK_PACKET_BATCH
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn active_loopback_missing_event_polls_after_ten_ms() {
        assert_eq!(
            WaitPolicy::new(true, true).wait(|plan| {
                assert_eq!(
                    plan,
                    WaitPlan {
                        handle_count: 2,
                        timeout_ms: 10
                    }
                );
                WAIT_TIMEOUT
            }),
            Ok(Wake::LoopbackPoll)
        );
    }

    #[test]
    fn paused_loopback_blocks_on_commands_without_polling_or_audio_wakes() {
        assert_eq!(
            WaitPolicy::new(true, false).wait(|plan| {
                assert_eq!(
                    plan,
                    WaitPlan {
                        handle_count: 1,
                        timeout_ms: INFINITE
                    }
                );
                0
            }),
            Ok(Wake::Command)
        );
        assert_eq!(
            WaitPolicy::new(true, false).wait(|_| 1),
            Err(WaitError::Unexpected(1))
        );
        assert_eq!(
            WaitPolicy::new(true, false).wait(|_| WAIT_TIMEOUT),
            Err(WaitError::Unexpected(WAIT_TIMEOUT))
        );
    }

    #[test]
    fn microphone_and_output_keep_infinite_event_wait() {
        for playing in [false, true] {
            assert_eq!(
                WaitPolicy::new(false, playing).wait(|plan| {
                    assert_eq!(
                        plan,
                        WaitPlan {
                            handle_count: 2,
                            timeout_ms: INFINITE
                        }
                    );
                    1
                }),
                Ok(Wake::Audio)
            );
            assert_eq!(
                WaitPolicy::new(false, playing).wait(|_| WAIT_TIMEOUT),
                Err(WaitError::Unexpected(WAIT_TIMEOUT))
            );
        }
    }

    #[test]
    fn command_and_real_audio_event_wake_before_poll_timeout() {
        assert_eq!(WaitPolicy::new(true, true).wait(|_| 0), Ok(Wake::Command));
        assert_eq!(WaitPolicy::new(true, true).wait(|_| 1), Ok(Wake::Audio));
    }

    #[test]
    fn failed_wait_never_enters_data_branch() {
        for loopback in [false, true] {
            for playing in [false, true] {
                assert_eq!(
                    WaitPolicy::new(loopback, playing).wait(|_| WAIT_FAILED),
                    Err(WaitError::Failed)
                );
            }
        }
    }

    #[test]
    fn abandoned_apc_and_out_of_range_values_never_enter_data_branch() {
        for value in [2, 3, 0x80, 0x81, 0xc0, 0x101, 0x103, u32::MAX - 1] {
            assert_eq!(
                WaitPolicy::new(true, true).wait(|_| value),
                Err(WaitError::Unexpected(value))
            );
        }
    }

    #[test]
    fn loopback_backlog_returns_to_command_gate_at_bounded_batch() {
        assert!(!batch_complete(true, LOOPBACK_PACKET_BATCH - 1));
        assert!(batch_complete(true, LOOPBACK_PACKET_BATCH));
        assert!(batch_complete(true, LOOPBACK_PACKET_BATCH + 1));
        assert!(!batch_complete(false, usize::MAX));
    }
}
