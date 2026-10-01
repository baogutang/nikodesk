use super::*;

pub(super) struct Publisher {
    pending: Option<tokio::task::JoinHandle<Result<(), &'static str>>>,
    next: Instant,
    last_sent: Option<bool>,
}
impl Default for Publisher {
    fn default() -> Self {
        Self { pending: None, next: Instant::now(), last_sent: None }
    }
}
impl Publisher {
    async fn poll_with<F>(&mut self, now: Instant, namespace: String, check: F) -> Option<bool>
    where F: FnOnce(String) -> Result<(), &'static str> + Send + 'static {
        if self.pending.as_ref().is_some_and(|job| job.is_finished()) {
            let result = match self.pending.take() {
                Some(job) => matches!(job.await, Ok(Ok(()))),
                None => false,
            };
            if self.last_sent != Some(result) { return Some(result); }
        }
        if self.pending.is_none() && now >= self.next {
            self.next = now + Duration::from_secs(1);
            self.pending = Some(tokio::task::spawn_blocking(move || check(namespace)));
        }
        None
    }
}
impl Drop for Publisher {
    fn drop(&mut self) {
        if let Some(job) = self.pending.take() { job.abort(); }
    }
}

impl Connection {
    pub(super) async fn poll_nikodesk_voice_policy(&mut self) {
        if !self.voice_role() { return; }
        let Some(features) = self.lr.nikodesk_features.as_ref() else { return; };
        if !features.nikodesk_voice_v1 || !features.nikodesk_voice_policy_updates { return; }
        let Some(namespace) = self.niko_voice_namespace.clone() else { return; };
        let Some(allowed) = self.niko_voice_policy.poll_with(Instant::now(), namespace,
            |namespace| crate::nikodesk::voice_runtime::availability(&namespace)).await else { return; };
        // This is a policy snapshot only. Native call admission and each local
        // device approval continue to read their own current execution grants.
        if matches!(tokio::time::timeout(Duration::from_millis(500),
            self.stream.send(&crate::nikodesk::voice_policy::snapshot(allowed))).await, Ok(Ok(()))) {
            self.niko_voice_policy.last_sent = Some(allowed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{atomic::{AtomicUsize, Ordering}, Arc};

    async fn ready(publisher: &mut Publisher, now: Instant) -> bool {
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if let Some(value) = publisher.poll_with(now, "scope".into(), |_| panic!("duplicate worker")).await {
                    return value;
                }
                tokio::task::yield_now().await;
            }
        }).await.unwrap()
    }

    #[tokio::test]
    async fn voice_policy_enabled_and_disabled_are_real_read_results_not_cached_login_grants() {
        let now = Instant::now();
        let mut publisher = Publisher::default();
        publisher.next = now;
        assert_eq!(publisher.poll_with(now, "scope".into(), |_| Err("policy_disabled")).await, None);
        assert!(!ready(&mut publisher, now).await);
        publisher.last_sent = Some(false);
        let later = now + Duration::from_secs(1);
        assert_eq!(publisher.poll_with(later, "scope".into(), |_| Ok(())).await, None);
        assert!(ready(&mut publisher, later).await);
        publisher.last_sent = Some(true);
        let later = later + Duration::from_secs(1);
        assert_eq!(publisher.poll_with(later, "scope".into(), |_| Err("namespace_changed")).await, None);
        assert!(!ready(&mut publisher, later).await);
    }

    #[tokio::test]
    async fn voice_policy_slow_read_has_one_worker_and_does_not_block_connection_polling() {
        let now = Instant::now();
        let mut publisher = Publisher::default();
        publisher.next = now;
        let started = Arc::new(AtomicUsize::new(0));
        let counted = started.clone();
        let (release, wait) = std::sync::mpsc::channel();
        assert_eq!(publisher.poll_with(now, "scope".into(), move |namespace| {
            assert_eq!(namespace, "scope");
            counted.fetch_add(1, Ordering::SeqCst);
            wait.recv().map_err(|_| "worker_failed")?;
            Ok(())
        }).await, None);
        for _ in 0..100 {
            assert_eq!(publisher.poll_with(now + Duration::from_secs(60), "scope".into(), |_| panic!("extra worker")).await, None);
        }
        release.send(()).unwrap();
        assert!(ready(&mut publisher, now).await);
        assert_eq!(started.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn voice_policy_failed_read_is_closed_and_unchanged_state_does_not_flood_the_stream() {
        let now = Instant::now();
        let mut publisher = Publisher::default();
        publisher.next = now;
        publisher.poll_with(now, "scope".into(), |_| Err("worker_failed")).await;
        assert!(!ready(&mut publisher, now).await);
        publisher.last_sent = Some(false);
        let later = now + Duration::from_secs(1);
        publisher.poll_with(later, "scope".into(), |_| Err("policy_disabled")).await;
        tokio::time::timeout(Duration::from_secs(2), async {
            while publisher.pending.as_ref().is_some_and(|job| !job.is_finished()) {
                tokio::task::yield_now().await;
            }
        }).await.unwrap();
        assert_eq!(publisher.poll_with(later, "scope".into(), |_| panic!("rate limit restarted worker")).await, None);
    }
}
