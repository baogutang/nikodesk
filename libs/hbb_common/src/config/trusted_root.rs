//! One-time opt-in for a caller-verified privileged configuration directory.
//! This module does not discover paths, create files or authenticate callers.
use std::{
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
};
use super::MachineRuntimeProfile;

#[derive(Default)]
struct State {
    accessed: bool,
    root: Option<PathBuf>,
    runtime: Option<Arc<MachineRuntimeProfile>>,
}
static STATE: Mutex<State> = Mutex::new(State {
    accessed: false,
    root: None,
    runtime: None,
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
    fn install_runtime(&mut self, root: PathBuf, profile: MachineRuntimeProfile) -> anyhow::Result<()> {
        self.install(root)?;
        self.runtime = Some(Arc::new(profile));
        Ok(())
    }
    fn runtime_snapshot(&mut self) -> Option<Arc<MachineRuntimeProfile>> {
        // An old/default load must close the installation window before it
        // releases the selector lock and begins its original decoder body.
        self.accessed = true;
        self.runtime.clone()
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

pub(super) fn install_runtime(root: PathBuf, profile: MachineRuntimeProfile) -> anyhow::Result<()> {
    STATE.lock().map_err(|_| anyhow::anyhow!("Configuration storage lock is poisoned"))?
        .install_runtime(root, profile)
}

pub(crate) fn runtime_snapshot() -> Option<Arc<MachineRuntimeProfile>> {
    STATE.lock().expect("configuration storage lock poisoned").runtime_snapshot()
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
    #[test]
    fn machine_runtime_root_and_snapshot_publish_together_or_not_at_all() {
        let mut state = State::default();
        assert!(state.install_runtime(PathBuf::from("relative"),
            super::super::machine_runtime::fixture_profile()).is_err());
        assert!(state.root.is_none() && state.runtime.is_none() && !state.accessed);
        let root = std::env::temp_dir().join("nikodesk-runtime-atomic-fixture");
        let profile = super::super::machine_runtime::fixture_profile();
        let id = profile.public_id().to_owned();
        state.install_runtime(root.clone(), profile).unwrap();
        assert_eq!(state.root, Some(root.clone()));
        assert_eq!(state.runtime_snapshot().unwrap().public_id(), id);
        assert_eq!(state.resolve(Path::new("NikoDesk.toml")), Some(root.join("NikoDesk.toml")));
        assert!(state.install_runtime(std::env::temp_dir(),
            super::super::machine_runtime::fixture_profile()).is_err());
        assert_eq!(state.runtime_snapshot().unwrap().public_id(), id);
    }
    #[test]
    fn machine_runtime_default_load_closes_late_installation_window() {
        let mut state = State::default();
        assert!(state.runtime_snapshot().is_none());
        assert!(state.install_runtime(std::env::temp_dir(),
            super::super::machine_runtime::fixture_profile()).is_err());
        assert!(state.root.is_none() && state.runtime.is_none());
    }
    #[test]
    fn machine_runtime_concurrent_selection_never_exposes_half_installed_state() {
        for _ in 0..32 {
            let state = Arc::new(Mutex::new(State::default()));
            let install_state = state.clone();
            let profile = super::super::machine_runtime::fixture_profile();
            let expected = profile.public_id().to_owned();
            let install = std::thread::spawn(move || install_state.lock().unwrap()
                .install_runtime(std::env::temp_dir(), profile));
            let load_state = state.clone();
            let load = std::thread::spawn(move || {
                let mut state = load_state.lock().unwrap();
                let profile = state.runtime_snapshot();
                assert_eq!(profile.is_some(), state.root.is_some());
                profile.map(|p| p.public_id().to_owned())
            });
            let installed = install.join().unwrap().is_ok();
            let observed = load.join().unwrap();
            assert_eq!(observed, if installed { Some(expected) } else { None });
        }
    }
}
