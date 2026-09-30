//! Local settings APIs. Persisted request policy never grants a remote resource.
use super::{
    capability_policy::{Repository, Snapshot},
    capability_state::Kind,
    favorites, server_scope, server_settings,
};
use hbb_common::{bail, ResultType};

fn kind(value: &str) -> ResultType<Kind> {
    Ok(match value {
        "terminal" => Kind::Terminal,
        "tunnel" => Kind::Tunnel,
        "camera" => Kind::Camera,
        "voice" => Kind::Voice,
        _ => bail!("invalid_capability_kind"),
    })
}

fn verify_scope(
    namespace: &str,
    options: &std::collections::HashMap<String, String>,
) -> ResultType<()> {
    if server_scope::ServerScope::from_namespace(namespace).is_none() {
        bail!("invalid_namespace");
    }
    if server_scope::namespace_from_options(options).as_deref() != Some(namespace) {
        bail!("namespace_changed");
    }
    Ok(())
}

fn wire(result: ResultType<Snapshot>) -> String {
    match result {
        Ok(snapshot) => {
            // A decimal string preserves u64 across Dart/JS JSON boundaries.
            serde_json::json!({"ok": snapshot.ok, "status": snapshot.status,
                "namespace": snapshot.namespace, "revision": snapshot.revision,
                "generation": snapshot.generation.to_string(),
                "allow_requests": snapshot.allow_requests})
            .to_string()
        }
        Err(error) => {
            let status = match error.to_string().as_str() {
                "invalid_namespace" => "invalid_namespace",
                "namespace_changed" => "namespace_changed",
                "invalid_revision" => "invalid_revision",
                "invalid_capability_kind" => "invalid_kind",
                "invalid_capability_policy" => "invalid_data",
                "capability_policy_generation_exhausted" => "exhausted",
                "capability_policy_limit" | "storage_file_too_large" => "limit_exceeded",
                "unsupported_capability_policy" => "unsupported",
                _ => "unavailable",
            };
            serde_json::json!({"ok": false, "status": status}).to_string()
        }
    }
}

fn locally<T>(
    namespace: &str,
    operation: impl FnOnce(Repository) -> ResultType<T>,
) -> ResultType<T> {
    if !cfg!(any(target_os = "windows", target_os = "macos"))
        || super::background::is_system_worker()
    {
        bail!("unsupported_capability_policy");
    }
    if server_scope::ServerScope::from_namespace(namespace).is_none() {
        bail!("invalid_namespace");
    }
    super::initialize()?;
    let root = favorites::application_root()?;
    server_settings::with_verified_options(|options| {
        verify_scope(namespace, options)?;
        operation(Repository::new(root))
    })
}

pub(crate) fn get(namespace: &str) -> String {
    wire(locally(namespace, |repository| repository.get(namespace)))
}

pub(crate) fn set(namespace: &str, revision: &str, capability: &str, enabled: bool) -> String {
    wire(kind(capability).and_then(|kind| {
        locally(namespace, |repository| {
            repository.set_allow_requests(namespace, revision, kind, enabled)
        })
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scope_and_kind_are_strict_and_do_not_fall_back() {
        let options = std::collections::HashMap::from([
            (
                "custom-rendezvous-server".to_owned(),
                "127.0.0.1:21116".to_owned(),
            ),
            (
                "key".to_owned(),
                hbb_common::sodiumoxide::base64::encode(
                    [7u8; 32],
                    hbb_common::sodiumoxide::base64::Variant::Original,
                ),
            ),
        ]);
        let namespace = server_scope::namespace_from_options(&options).unwrap();
        assert!(verify_scope(&namespace, &options).is_ok());
        assert!(verify_scope(&"a".repeat(64), &options).is_err());
        assert!(verify_scope(&"a".repeat(64), &Default::default()).is_err());
        assert!(verify_scope("../bad", &Default::default()).is_err());
        assert_eq!(kind("terminal").unwrap(), Kind::Terminal);
        for invalid in ["Terminal", "shell", "", "voice\0", "camera:any"] {
            assert!(kind(invalid).is_err());
        }
    }
    #[test]
    fn errors_are_bounded_without_private_paths_or_raw_messages() {
        let response = wire(Err(hbb_common::anyhow::anyhow!(
            "private/path and credentials"
        )));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&response).unwrap(),
            serde_json::json!({"ok": false, "status": "unavailable"})
        );
        let response = wire(Err(hbb_common::anyhow::anyhow!(
            "capability_policy_generation_exhausted"
        )));
        assert!(response.contains("exhausted"));
    }

    #[test]
    fn u64_generations_are_decimal_strings_on_the_wire() {
        let value: serde_json::Value = serde_json::from_str(&wire(Ok(Snapshot {
            ok: true,
            status: "ready",
            namespace: "a".repeat(64),
            revision: "b".repeat(64),
            generation: u64::MAX,
            allow_requests: Default::default(),
        })))
        .unwrap();
        assert_eq!(value["generation"], "18446744073709551615");
        assert_eq!(value["allow_requests"]["terminal"], false);
    }
}
