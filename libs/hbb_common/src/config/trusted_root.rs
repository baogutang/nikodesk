//! One-time opt-in for a caller-verified privileged configuration directory.
//! This module does not discover paths, create files or authenticate callers.
use std::{
    path::{Component, Path, PathBuf},
    sync::Mutex,
};

#[derive(Default)]
struct State {
    accessed: bool,
    root: Option<PathBuf>,
}
static STATE: Mutex<State> = Mutex::new(State {
    accessed: false,
    root: None,
});

impl State {
    fn install(&mut self, root: PathBuf) -> anyhow::Result<()> {
        if self.accessed || self.root.is_some() {
            anyhow::bail!("Configuration storage has already been selected");
        }
        if !root.is_absolute()
            || root
                .components()
                .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
        {
            anyhow::bail!("Trusted configuration storage must be an absolute canonical path");
        }
        self.root = Some(root);
        Ok(())
    }
    fn resolve(&mut self, child: &Path) -> Option<PathBuf> {
        self.accessed = true;
        self.root.as_ref().map(|root| {
            // Config::path is an infallible internal API. An invalid privileged
            // child must stop the process, never escape or select a user path.
            assert!(
                !child.is_absolute()
                    && !child
                        .components()
                        .any(|c| matches!(c, Component::ParentDir | Component::CurDir)),
                "Invalid trusted configuration child"
            );
            root.join(child)
        })
    }
}

/// The caller must verify its system role, directory ACL and identity first.
/// May be called exactly once, before any Config::path/Config access.
pub(super) fn install(root: PathBuf) -> anyhow::Result<()> {
    STATE
        .lock()
        .map_err(|_| anyhow::anyhow!("Configuration storage lock is poisoned"))?
        .install(root)
}

pub(super) fn resolve(child: &Path) -> Option<PathBuf> {
    // A poisoned selector must never fall back to a user/environment directory.
    STATE
        .lock()
        .expect("configuration storage lock poisoned")
        .resolve(child)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection_is_once_only_and_cannot_change_after_default_access() {
        let mut state = State::default();
        assert_eq!(state.resolve(Path::new("fixture")), None);
        assert!(state.install(std::env::temp_dir()).is_err());
        let mut state = State::default();
        let root = std::env::temp_dir().join("nikodesk-pure-fixture");
        state.install(root.clone()).unwrap();
        assert_eq!(
            state.resolve(Path::new("NikoDesk.toml")),
            Some(root.join("NikoDesk.toml"))
        );
        assert!(state.install(root).is_err());
    }
    #[test]
    fn relative_and_parent_directory_selection_are_rejected_without_io() {
        for root in [
            PathBuf::from("relative"),
            std::env::temp_dir().join("../fixture"),
        ] {
            assert!(State::default().install(root).is_err());
        }
    }
    #[test]
    #[should_panic(expected = "Invalid trusted configuration child")]
    fn trusted_child_cannot_escape_the_selected_root() {
        let mut state = State::default();
        state.install(std::env::temp_dir()).unwrap();
        state.resolve(Path::new("../outside"));
    }
}
