use super::*;

pub(super) fn enqueue<T: InvokeUiSession>(
    handler: &Session<T>,
    thread: &VideoThread,
    frame: VideoFrame,
) {
    let display = frame.display;
    let result = thread.niko_queue.push(frame);
    if let Some(metrics) = thread.video_metrics.as_ref() {
        metrics.queue_depth(result.depth);
        if result.overflow {
            metrics.count(crate::nikodesk::video_metrics::Counter::DeltaOverflow);
        }
        for _ in 0..result.discarded {
            metrics.count(crate::nikodesk::video_metrics::Counter::RefreshDiscard);
        }
    }
    if result.refresh {
        handler.refresh_video(display);
    }
}

impl<T: InvokeUiSession> Remote<T> {
    pub(super) fn fps_control(&mut self, direct: bool, real_fps_map: HashMap<usize, i32>) {
        self.video_threads.iter_mut().for_each(|(k, v)| {
            let real_fps = real_fps_map.get(k).cloned().unwrap_or_default();
            if real_fps == 0 {
                v.fps_control.inactive_counter += 1;
            } else {
                v.fps_control.inactive_counter = 0;
            }
        });
        let custom_fps = self.handler.lc.read().unwrap().custom_fps.clone();
        let custom_fps = custom_fps.lock().unwrap().clone();
        let mut custom_fps = custom_fps.unwrap_or(30);
        if custom_fps < 5 || custom_fps > 120 {
            custom_fps = 30;
        }
        let inactive_threshold = 15;
        let max_queue_len = self
            .video_threads
            .iter()
            .map(|v| v.1.niko_queue.depth())
            .max()
            .unwrap_or_default();
        let min_decode_fps = crate::nikodesk::video_queue::minimum_decode_fps(
            self.video_threads
                .iter()
                .filter(|v| v.1.fps_control.inactive_counter < inactive_threshold)
                .map(|v| *v.1.decode_fps.read().unwrap()),
        );
        let Some(min_decode_fps) = min_decode_fps else {
            return;
        };
        let mut limited_fps = if direct {
            min_decode_fps * 9 / 10 // 30 got 27
        } else {
            min_decode_fps * 4 / 5 // 30 got 24
        };
        if limited_fps > custom_fps {
            limited_fps = custom_fps;
        }
        let last_auto_fps = self.handler.lc.read().unwrap().last_auto_fps.clone();
        let displays = self.video_threads.keys().cloned().collect::<Vec<_>>();
        let mut fps_trending = |display: usize| {
            let thread = self.video_threads.get_mut(&display)?;
            let ctl = &mut thread.fps_control;
            let len = thread.niko_queue.depth();
            let decode_fps = thread.decode_fps.read().unwrap().clone()?;
            let last_auto_fps = last_auto_fps.clone().unwrap_or(custom_fps as _);
            if ctl.inactive_counter > inactive_threshold {
                return None;
            }
            if len > 1 && last_auto_fps > limited_fps || len > std::cmp::max(1, decode_fps / 2) {
                ctl.idle_counter = 0;
                return Some(false);
            }
            if len <= 1 {
                ctl.idle_counter += 1;
                if ctl.idle_counter > 3 && last_auto_fps + 3 <= limited_fps {
                    return Some(true);
                }
            }
            if len > 1 {
                ctl.idle_counter = 0;
            }
            None
        };
        let trendings: Vec<_> = displays.iter().map(|k| fps_trending(*k)).collect();
        let should_decrease = trendings.iter().any(|v| *v == Some(false));
        let should_increase = !should_decrease && trendings.iter().any(|v| *v == Some(true));
        if last_auto_fps.is_none() || should_decrease || should_increase {
            // limited_fps to ensure decoding is faster than encoding
            let mut auto_fps = limited_fps;
            if should_decrease && limited_fps < max_queue_len {
                auto_fps = limited_fps / 2;
            }
            if auto_fps < 1 {
                auto_fps = 1;
            }
            if Some(auto_fps) != last_auto_fps {
                let mut misc = Misc::new();
                misc.set_option(OptionMessage {
                    custom_fps: auto_fps as _,
                    ..Default::default()
                });
                let mut msg = Message::new();
                msg.set_misc(misc);
                self.sender.send(Data::Message(msg)).ok();
                log::info!("Set fps to {}", auto_fps);
                self.handler.lc.write().unwrap().last_auto_fps = Some(auto_fps);
            }
        }
        // send refresh
        for (display, thread) in self.video_threads.iter_mut() {
            let ctl = &mut thread.fps_control;
            let queue_len = thread.niko_queue.depth();
            let tolerable = std::cmp::min(min_decode_fps, client::VIDEO_QUEUE_SIZE / 2);
            if ctl.refresh_times < 20 // enough
                    && (queue_len > tolerable
                            && (ctl.refresh_times == 0 || ctl.last_refresh_instant.map(|t|t.elapsed().as_secs() > 10).unwrap_or(false)))
            {
                // Refresh causes client set_display, left frames cause flickering.
                thread.niko_queue.await_keyframe();
                self.handler.refresh_video(*display as _);
                log::info!("Refresh display {} to reduce delay", display);
                ctl.refresh_times += 1;
                ctl.last_refresh_instant = Some(Instant::now());
            }
        }
    }
}
