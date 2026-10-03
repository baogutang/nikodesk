use base::message_proto::{video_frame, VideoFrame};
use std::{collections::VecDeque, sync::Mutex};

use crate::client::{MediaData, MediaSender};

const MAX_BYTES: usize = 64 * 1024 * 1024;

#[derive(Default)]
pub(crate) struct PushResult {
    pub depth: usize,
    pub overflow: bool,
    pub discarded: usize,
    pub refresh: bool,
}

struct State {
    frames: VecDeque<(VideoFrame, usize)>,
    bytes: usize,
    awaiting_keyframe: bool,
    prefix_valid: bool,
    reset_pending: bool,
    wake_pending: bool,
    sender: Option<MediaSender>,
}

pub(crate) struct VideoQueue {
    limit: usize,
    state: Mutex<State>,
}

fn frame_info(frame: &VideoFrame) -> Option<(bool, usize)> {
    use video_frame::Union::*;
    let frames = match frame.union.as_ref()? {
        Vp8s(frames) | Vp9s(frames) | Av1s(frames) | H264s(frames) | H265s(frames) => {
            &frames.frames
        }
        _ => return None,
    };
    // A later keyframe cannot repair the delta frames preceding it in this message.
    let key = frames.first()?.key;
    let bytes = frames
        .iter()
        .try_fold(0usize, |total, frame| total.checked_add(frame.data.len()))?;
    Some((key, bytes))
}

impl VideoQueue {
    pub(crate) fn new(limit: usize, sender: MediaSender) -> Self {
        Self {
            limit: limit.max(1),
            state: Mutex::new(State {
                frames: VecDeque::new(),
                bytes: 0,
                awaiting_keyframe: true,
                prefix_valid: true,
                reset_pending: false,
                wake_pending: false,
                sender: Some(sender),
            }),
        }
    }

    fn wake(state: &mut State) {
        if !state.wake_pending && !state.frames.is_empty() {
            if state
                .sender
                .as_ref()
                .is_some_and(|sender| sender.send(MediaData::VideoQueue).is_ok())
            {
                state.wake_pending = true;
            } else {
                state.sender = None;
                state.frames.clear();
                state.bytes = 0;
            }
        }
    }

    pub(crate) fn push(&self, frame: VideoFrame) -> PushResult {
        let mut state = self.state.lock().unwrap();
        let mut result = PushResult::default();
        if state.sender.is_none() {
            return result;
        }
        let Some((key, bytes)) = frame_info(&frame) else {
            result.discarded = 1;
            return result;
        };
        if bytes > MAX_BYTES {
            result.overflow = true;
            result.discarded = 1;
            result.refresh = !state.awaiting_keyframe;
            state.awaiting_keyframe = true;
        } else if state.awaiting_keyframe && !key {
            result.discarded = 1;
        } else {
            let full = state.frames.len() >= self.limit
                || state
                    .bytes
                    .checked_add(bytes)
                    .is_none_or(|size| size > MAX_BYTES);
            if key && (state.awaiting_keyframe || full) {
                // Only an explicit new reference permits abandoning the queued prefix.
                result.discarded = state.frames.len();
                state.frames.clear();
                state.bytes = 0;
                state.awaiting_keyframe = false;
                state.prefix_valid = true;
            } else if full {
                // The queued prefix is still valid. Drain it, but do not decode the
                // missing reference chain until the requested keyframe arrives.
                state.awaiting_keyframe = true;
                result.overflow = true;
                result.discarded = 1;
                result.refresh = true;
            }
            if !state.awaiting_keyframe {
                state.bytes += bytes;
                state.frames.push_back((frame, bytes));
                Self::wake(&mut state);
            }
        }
        result.depth = state.frames.len();
        result
    }

    pub(crate) fn pop(&self) -> Option<(VideoFrame, bool)> {
        let mut state = self.state.lock().unwrap();
        state.wake_pending = false;
        if !state.prefix_valid {
            return None;
        }
        let (frame, bytes) = state.frames.pop_front()?;
        state.bytes -= bytes;
        Self::wake(&mut state);
        let reset = std::mem::take(&mut state.reset_pending);
        Some((frame, reset))
    }

    pub(crate) fn depth(&self) -> usize {
        self.state.lock().unwrap().frames.len()
    }

    pub(crate) fn await_keyframe(&self) {
        let mut state = self.state.lock().unwrap();
        state.awaiting_keyframe = true;
        // An explicit refresh or decoder error retires the old reference chain.
        // Keep its bounded storage until the keyframe arrives, without decoding it.
        state.prefix_valid = false;
    }

    pub(crate) fn reset(&self) {
        let mut state = self.state.lock().unwrap();
        state.awaiting_keyframe = true;
        state.prefix_valid = false;
        // Reset belongs to the replacement reference, never to an earlier wake token.
        state.reset_pending = true;
    }

    pub(crate) fn close(&self) {
        let mut state = self.state.lock().unwrap();
        state.sender = None;
        state.frames.clear();
        state.bytes = 0;
    }
}

pub(crate) fn minimum_decode_fps(samples: impl Iterator<Item = Option<usize>>) -> Option<usize> {
    samples.flatten().min()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{EncodedVideoFrame, EncodedVideoFrames};
    use hbb_common::bytes::Bytes;
    use std::sync::{mpsc, Arc};

    fn frame(pts: i64, key: bool) -> VideoFrame {
        let mut frame = VideoFrame::new();
        frame.set_vp9s(EncodedVideoFrames {
            frames: vec![EncodedVideoFrame {
                data: Bytes::from(vec![pts as u8]),
                pts,
                key,
                ..Default::default()
            }],
            ..Default::default()
        });
        frame
    }

    fn pts(frame: &VideoFrame) -> i64 {
        match frame.union.as_ref().unwrap() {
            video_frame::Union::Vp8s(frames)
            | video_frame::Union::Vp9s(frames)
            | video_frame::Union::Av1s(frames) => frames.frames[0].pts,
            _ => panic!("test codec"),
        }
    }

    fn take(queue: &VideoQueue, receiver: &mpsc::Receiver<MediaData>) -> Option<VideoFrame> {
        assert!(matches!(
            receiver.try_recv().unwrap(),
            MediaData::VideoQueue
        ));
        queue.pop().map(|(frame, _)| frame)
    }

    #[test]
    fn healthy_keyframes_and_deltas_remain_in_wire_order_with_one_pending_wake() {
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(120, sender);
        for value in 0..100 {
            let result = queue.push(frame(value, value % 10 == 0));
            assert!(!result.overflow);
            assert_eq!(result.discarded, 0);
        }
        assert_eq!(receiver.try_iter().count(), 1);
        // The one consumed token is handled now; each pop schedules just its successor.
        assert_eq!(pts(&queue.pop().unwrap().0), 0);
        for value in 1..100 {
            assert_eq!(pts(&take(&queue, &receiver).unwrap()), value);
        }
        assert_eq!(queue.depth(), 0);
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn overflow_keeps_valid_prefix_and_requests_one_refresh_until_a_leading_keyframe() {
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(3, sender);
        for value in 0..3 {
            queue.push(frame(value, value == 0));
        }
        let result = queue.push(frame(3, false));
        assert!(result.overflow && result.refresh);
        assert_eq!(queue.depth(), 3);
        for value in 4..20 {
            let result = queue.push(frame(value, false));
            assert!(!result.refresh && !result.overflow);
            assert_eq!(result.discarded, 1);
        }
        for value in 0..3 {
            assert_eq!(pts(&take(&queue, &receiver).unwrap()), value);
        }
        assert!(receiver.try_recv().is_err());
        queue.push(frame(20, true));
        queue.push(frame(21, false));
        assert_eq!(pts(&take(&queue, &receiver).unwrap()), 20);
        assert_eq!(pts(&take(&queue, &receiver).unwrap()), 21);
    }

    #[test]
    fn explicit_refresh_replaces_obsolete_prefix_only_when_new_reference_arrives() {
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(3, sender);
        queue.push(frame(0, true));
        queue.push(frame(1, false));
        queue.await_keyframe();
        assert_eq!(queue.push(frame(2, false)).discarded, 1);
        assert_eq!(queue.depth(), 2);
        assert!(take(&queue, &receiver).is_none());
        assert!(receiver.try_recv().is_err());
        assert_eq!(queue.push(frame(3, true)).discarded, 2);
        queue.push(frame(4, false));
        assert_eq!(pts(&take(&queue, &receiver).unwrap()), 3);
        assert_eq!(pts(&take(&queue, &receiver).unwrap()), 4);
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn full_queue_can_recover_from_an_unsolicited_keyframe_without_requesting_refresh() {
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(2, sender);
        queue.push(frame(0, true));
        queue.push(frame(1, false));
        let result = queue.push(frame(2, true));
        assert_eq!(result.discarded, 2);
        assert!(!result.overflow && !result.refresh);
        assert_eq!(pts(&take(&queue, &receiver).unwrap()), 2);
    }

    #[test]
    fn recovery_requires_the_first_encoded_frame_to_be_key_for_every_supported_codec() {
        let delta = match frame(1, false).union.unwrap() {
            video_frame::Union::Vp9s(frames) => frames.frames[0].clone(),
            _ => unreachable!(),
        };
        let mut key = delta.clone();
        key.key = true;
        for format in 0..5 {
            for first_is_key in [false, true] {
                let frames = EncodedVideoFrames {
                    frames: if first_is_key {
                        vec![key.clone(), delta.clone()]
                    } else {
                        vec![delta.clone(), key.clone()]
                    },
                    ..Default::default()
                };
                let mut frame = VideoFrame::new();
                match format {
                    0 => frame.set_vp8s(frames),
                    1 => frame.set_vp9s(frames),
                    2 => frame.set_av1s(frames),
                    3 => frame.set_h264s(frames),
                    _ => frame.set_h265s(frames),
                }
                let (sender, _receiver) = mpsc::channel();
                let queue = VideoQueue::new(3, sender);
                assert_eq!(queue.push(frame).discarded, usize::from(!first_is_key));
            }
        }
    }

    #[test]
    fn close_releases_self_owned_sender_rejects_new_frames_and_wakes_receiver_exit() {
        let (sender, receiver) = mpsc::channel();
        let queue = Arc::new(VideoQueue::new(2, sender));
        queue.push(frame(0, true));
        queue.close();
        assert!(take(&queue, &receiver).is_none());
        assert!(matches!(receiver.recv(), Err(mpsc::RecvError)));
        assert_eq!(queue.push(frame(1, true)).depth, 0);
    }

    #[test]
    fn concurrent_pop_and_push_never_lose_the_wake_for_the_last_frame() {
        let (sender, receiver) = mpsc::channel();
        let queue = Arc::new(VideoQueue::new(5000, sender));
        let writer = queue.clone();
        let producer = std::thread::spawn(move || {
            for value in 0..4000 {
                writer.push(frame(value, value == 0));
            }
        });
        for value in 0..4000 {
            assert!(matches!(
                receiver
                    .recv_timeout(std::time::Duration::from_secs(3))
                    .unwrap(),
                MediaData::VideoQueue
            ));
            assert_eq!(pts(&queue.pop().unwrap().0), value);
        }
        producer.join().unwrap();
        assert_eq!(queue.depth(), 0);
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn unavailable_display_estimate_does_not_disable_other_display_backpressure() {
        assert_eq!(
            minimum_decode_fps([Some(60), None, Some(24)].into_iter()),
            Some(24)
        );
        assert_eq!(minimum_decode_fps([None, None].into_iter()), None);
        assert_eq!(
            minimum_decode_fps([Some(0), None, Some(24)].into_iter()),
            Some(0)
        );
    }

    #[test]
    fn encoded_byte_budget_rejects_a_large_packet_without_losing_valid_prefix() {
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(120, sender);
        queue.push(frame(0, true));
        let mut oversized = frame(1, false);
        if let Some(video_frame::Union::Vp9s(frames)) = oversized.union.as_mut() {
            frames.frames[0].data = Bytes::from(vec![0; MAX_BYTES + 1]);
        }
        let result = queue.push(oversized);
        assert!(result.overflow && result.refresh);
        assert_eq!(result.depth, 1);
        assert_eq!(pts(&take(&queue, &receiver).unwrap()), 0);
        assert_eq!(queue.push(frame(2, false)).discarded, 1);
    }

    fn encode_fixture(
        format: scrap::CodecFormat,
        width: usize,
        height: usize,
        count: usize,
        interval: usize,
    ) -> Vec<VideoFrame> {
        use scrap::{
            aom::AomEncoderConfig,
            codec::{Encoder, EncoderCfg},
            CodecFormat, EncodeInput, VpxEncoderConfig, VpxVideoCodecId,
        };
        let config = match format {
            CodecFormat::VP8 | CodecFormat::VP9 => EncoderCfg::VPX(VpxEncoderConfig {
                width: width as _,
                height: height as _,
                quality: 1.0,
                codec: if format == CodecFormat::VP8 {
                    VpxVideoCodecId::VP8
                } else {
                    VpxVideoCodecId::VP9
                },
                keyframe_interval: Some(interval),
            }),
            CodecFormat::AV1 => EncoderCfg::AOM(AomEncoderConfig {
                width: width as _,
                height: height as _,
                quality: 1.0,
                keyframe_interval: Some(interval),
            }),
            _ => panic!("software test codec"),
        };
        let mut encoder = Encoder::new(config, false).unwrap();
        let fmt = encoder.yuvfmt();
        let len = (fmt.v + fmt.stride[1] * fmt.h / 2)
            .max(fmt.u + fmt.stride[1] * fmt.h / 2)
            .max(fmt.stride[0] * fmt.h);
        let mut yuv = vec![128u8; len];
        let mut frames = Vec::new();
        for index in 0..count {
            for y in 0..height {
                for x in 0..width {
                    yuv[y * fmt.stride[0] + x] = 32 + ((x + y + index * 7) % 128) as u8;
                }
            }
            frames.push(
                encoder
                    .encode_to_message(EncodeInput::YUV(&yuv), index as i64 * 16)
                    .unwrap(),
            );
        }
        frames
    }

    fn decode_fixture(frames: &[VideoFrame]) -> Vec<u8> {
        use scrap::{codec::Decoder, CodecFormat, ImageFormat, ImageRgb, ImageTexture};
        let mut decoder = Decoder::new(CodecFormat::from(&frames[0]), None);
        let mut rgb = ImageRgb::new(ImageFormat::ARGB, 1);
        let mut texture = ImageTexture::default();
        for frame in frames {
            let output = decoder
                .handle_video_frame(
                    frame.union.as_ref().unwrap(),
                    &mut rgb,
                    &mut texture,
                    &mut true,
                    &mut None,
                )
                .unwrap();
            assert!(output);
        }
        rgb.raw
    }

    #[test]
    fn native_vp9_delta_chain_after_overflow_recovers_to_the_baseline_pixels() {
        let frames = encode_fixture(scrap::CodecFormat::VP9, 64, 64, 6, 4);
        assert!(frame_info(&frames[0]).unwrap().0);
        assert!(frame_info(&frames[4]).unwrap().0);
        for index in [1, 2, 3, 5] {
            assert!(!frame_info(&frames[index]).unwrap().0);
        }
        let baseline = decode_fixture(&frames);
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(2, sender);
        for frame in frames {
            queue.push(frame);
        }
        let mut recovered = Vec::new();
        while receiver.try_recv().is_ok() {
            recovered.push(queue.pop().unwrap().0);
        }
        assert_eq!(recovered.iter().map(pts).collect::<Vec<_>>(), vec![64, 80]);
        assert_eq!(decode_fixture(&recovered), baseline);
    }

    #[test]
    fn native_vp8_vp9_av1_sequence_has_leading_references_and_identical_fifo_pixels() {
        for format in [
            scrap::CodecFormat::VP8,
            scrap::CodecFormat::VP9,
            scrap::CodecFormat::AV1,
        ] {
            let frames = encode_fixture(format, 64, 64, 12, 4);
            assert!(frame_info(&frames[0]).unwrap().0);
            assert!(frames
                .iter()
                .skip(1)
                .any(|frame| !frame_info(frame).unwrap().0));
            let baseline = decode_fixture(&frames);
            let order = frames.iter().map(pts).collect::<Vec<_>>();
            let (sender, receiver) = mpsc::channel();
            let queue = VideoQueue::new(120, sender);
            for frame in frames {
                assert_eq!(queue.push(frame).discarded, 0);
            }
            let mut queued = Vec::new();
            while receiver.try_recv().is_ok() {
                queued.push(queue.pop().unwrap().0);
            }
            assert_eq!(queued.iter().map(pts).collect::<Vec<_>>(), order);
            assert_eq!(decode_fixture(&queued), baseline);
        }
    }

    #[test]
    fn split_keyframe_queue_counterexample_is_removed_without_reordering_healthy_frames() {
        let frames = (0..6)
            .map(|value| frame(value, value % 4 == 0))
            .collect::<Vec<_>>();
        let old_deltas = crossbeam_queue::ArrayQueue::new(2);
        let mut old_wakes = VecDeque::new();
        let mut old_refreshes = 0;
        for frame in &frames {
            if frame_info(frame).unwrap().0 {
                old_wakes.push_back(Some(frame.clone()));
            } else if old_deltas.force_push(frame.clone()).is_some() {
                old_refreshes += 1;
            } else {
                old_wakes.push_back(None);
            }
        }
        let old_order = old_wakes
            .into_iter()
            .map(|wake| pts(&wake.or_else(|| old_deltas.pop()).unwrap()))
            .collect::<Vec<_>>();
        assert_eq!(old_order, [0, 3, 5, 4]);
        assert_eq!(old_refreshes, 2);
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(2, sender);
        let mut new_refreshes = 0;
        for frame in frames {
            new_refreshes += usize::from(queue.push(frame).refresh);
        }
        let mut new_order = Vec::new();
        while receiver.try_recv().is_ok() {
            new_order.push(pts(&queue.pop().unwrap().0));
        }
        assert_eq!(new_order, [4, 5]);
        assert_eq!(new_refreshes, 1);
    }

    #[test]
    #[ignore = "explicit local synthetic codec measurement; no capture, session or network"]
    fn synthetic_native_video_measurement() {
        let started = std::time::Instant::now();
        let frames = encode_fixture(scrap::CodecFormat::VP9, 640, 360, 120, 30);
        let encode_us = started.elapsed().as_micros();
        let encoded_bytes: usize = frames
            .iter()
            .map(|frame| frame_info(frame).unwrap().1)
            .sum();
        let started = std::time::Instant::now();
        let baseline = decode_fixture(&frames);
        let decode_us = started.elapsed().as_micros();
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(120, sender);
        let started = std::time::Instant::now();
        for frame in frames {
            queue.push(frame);
        }
        assert_eq!(receiver.try_iter().count(), 1);
        let mut recovered = vec![queue.pop().unwrap().0];
        while receiver.try_recv().is_ok() {
            recovered.push(queue.pop().unwrap().0);
        }
        let queue_us = started.elapsed().as_micros();
        assert_eq!(decode_fixture(&recovered), baseline);
        println!(
            "{}",
            serde_json::json!({
                "fixture": "generated luma gradient, VP9 software, 640x360, 120 frames",
                "build": "Rust debug test with pinned native codec dependencies",
                "encodeTotalUs": encode_us, "decodeTotalUs": decode_us,
                "queueEnqueueDrainTotalUs": queue_us, "encodedPayloadBytes": encoded_bytes,
                "legacyBufferedFrameNotifications": 120, "newPendingFrameNotifications": 1,
                "decodedFrames": recovered.len(), "pixelIdenticalToSequentialBaseline": true,
                "networkInputToPhotonOrHardwarePerformance": "not measured"
            })
        );
    }

    #[test]
    fn display_reset_is_atomic_with_the_replacement_keyframe_even_with_an_earlier_wake() {
        let (sender, receiver) = mpsc::channel();
        let queue = VideoQueue::new(3, sender);
        queue.push(frame(0, true));
        queue.push(frame(1, false));
        queue.reset();
        queue.push(frame(2, true));
        queue.push(frame(3, false));
        assert!(matches!(
            receiver.try_recv().unwrap(),
            MediaData::VideoQueue
        ));
        let (reference, reset) = queue.pop().unwrap();
        assert_eq!(pts(&reference), 2);
        assert!(reset);
        assert!(matches!(
            receiver.try_recv().unwrap(),
            MediaData::VideoQueue
        ));
        let (delta, reset) = queue.pop().unwrap();
        assert_eq!(pts(&delta), 3);
        assert!(!reset);
        assert!(receiver.try_recv().is_err());
    }
}
