//! Fallible native release exactly once, including errors/unwinding. Unknown
//! release retains the actual resource and marks the enclosing owner unresolved.
use super::Failure;
pub struct ReleaseGuard<T, F: Fn(&T) -> Result<(), Failure>, U: Fn()> {
    resource: Option<T>,
    release: F,
    uncertain: U,
    failure: Option<Failure>,
}
impl<T, F: Fn(&T) -> Result<(), Failure>, U: Fn()> ReleaseGuard<T, F, U> {
    pub fn new(resource: T, release: F, uncertain: U) -> Self {
        Self {
            resource: Some(resource),
            release,
            uncertain,
            failure: None,
        }
    }
    pub fn finish(&mut self) -> Result<(), Failure> {
        if let Some(error) = self.failure {
            return Err(error);
        }
        if let Some(resource) = self.resource.take() {
            if let Err(error) = (self.release)(&resource) {
                self.failure = Some(error);
                (self.uncertain)();
                std::mem::forget(resource);
                return Err(error);
            }
        }
        Ok(())
    }
}
impl<T, F: Fn(&T) -> Result<(), Failure>, U: Fn()> Drop for ReleaseGuard<T, F, U> {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}
#[cfg(test)]
mod tests {
    use super::super::Code;
    use super::*;
    use std::{cell::Cell, rc::Rc};
    struct Resource(Rc<Cell<usize>>);
    impl Drop for Resource {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }
    #[test]
    fn successful_release_is_exactly_once_and_drops_resource() {
        let release = Cell::new(0);
        let dropped = Rc::new(Cell::new(0));
        {
            let mut guard = ReleaseGuard::new(
                Resource(dropped.clone()),
                |_| {
                    release.set(release.get() + 1);
                    Ok(())
                },
                || panic!("unknown"),
            );
            assert!(guard.finish().is_ok());
            assert!(guard.finish().is_ok());
        }
        assert_eq!(release.get(), 1);
        assert_eq!(dropped.get(), 1);
    }
    #[test]
    fn validation_error_and_unwinding_still_release_once() {
        let release = Cell::new(0);
        let dropped = Rc::new(Cell::new(0));
        {
            let _guard = ReleaseGuard::new(
                Resource(dropped.clone()),
                |_| {
                    release.set(release.get() + 1);
                    Ok(())
                },
                || panic!("unknown"),
            );
        }
        let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = ReleaseGuard::new(
                Resource(dropped.clone()),
                |_| {
                    release.set(release.get() + 1);
                    Ok(())
                },
                || panic!("unknown"),
            );
            panic!("synthetic conversion failure");
        }));
        assert!(panic.is_err());
        assert_eq!(release.get(), 2);
        assert_eq!(dropped.get(), 2);
    }
    #[test]
    fn failed_release_retains_actual_resource_without_retry_or_fake_ack() {
        let release = Cell::new(0);
        let uncertain = Cell::new(0);
        let dropped = Rc::new(Cell::new(0));
        {
            let mut guard = ReleaseGuard::new(
                Resource(dropped.clone()),
                |_| {
                    release.set(release.get() + 1);
                    Err(Failure::new(Code::Native))
                },
                || uncertain.set(uncertain.get() + 1),
            );
            assert!(guard.finish().is_err());
            assert!(guard.finish().is_err());
        }
        assert_eq!(release.get(), 1);
        assert_eq!(uncertain.get(), 1);
        assert_eq!(dropped.get(), 0);
    }
}
