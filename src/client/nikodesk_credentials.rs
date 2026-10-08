use super::*;

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct PresetChoice {
    schema: u32,
    namespace: String,
    remember: bool,
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Metadata {
    nikodesk_credentials: PresetChoice,
}

impl LoginConfigHandler {
    pub(super) fn initialize_credentials(&mut self, token: Option<&str>) {
        self.stored_credential = self
            .peer_storage_key
            .as_ref()
            .and_then(|key| crate::nikodesk::credentials::load(key).ok().flatten());
        self.using_stored_credential = false;
        self.remember = self.stored_credential.is_some();
        self.credential_warning = None;
        self.credential_choice = token.and_then(|token| {
            if token.len() > 512 {
                return None;
            }
            let parsed: Metadata = serde_json::from_str(token).ok()?;
            let choice = parsed.nikodesk_credentials;
            (choice.schema == 1
                && self
                    .connection_snapshot
                    .as_ref()
                    .map(|snapshot| snapshot.namespace())
                    == Some(choice.namespace.as_str()))
            .then_some(choice.remember)
        });
        if let Some(choice) = self.credential_choice {
            self.remember = choice;
        }
    }

    pub(super) fn credential_password(&mut self, salt: &str) -> Option<Vec<u8>> {
        let password = self.stored_credential.as_ref()?.password_for_salt(salt);
        self.using_stored_credential = true;
        if password.is_none() {
            self.credential_warning = self.reject_stored_credential();
        }
        password
    }

    pub(super) fn reject_stored_credential(&mut self) -> Option<&'static str> {
        if !self.using_stored_credential {
            return None;
        }
        self.using_stored_credential = false;
        let stored = self.stored_credential.take();
        // Keep the user's remember choice for the password retry. Saving still
        // requires another successful remote authentication.
        let deleted = self
            .peer_storage_key
            .as_ref()
            .zip(stored.as_ref())
            .map(|(key, stored)| crate::nikodesk::credentials::delete_stored(key, stored));
        if matches!(deleted, Some(Ok(()))) {
            Some("The saved password is no longer valid. Enter the remote password again.")
        } else {
            log::warn!("NikoDesk invalid credential removal was not confirmed");
            Some("The saved password is no longer valid and secure storage could not confirm its removal. Enter the remote password again.")
        }
    }

    pub(super) fn persist_authenticated_credential(&mut self, password: &[u8], hash: &Hash) {
        let Some(remember) = self.credential_choice.take() else {
            return;
        };
        let result = self
            .peer_storage_key
            .as_ref()
            .ok_or_else(|| anyhow!("credential_scope_unavailable"))
            .and_then(|key| {
                if remember {
                    if self.password_source.is_shared_ab(password, hash) {
                        bail!("shared_credential_not_stored");
                    }
                    crate::nikodesk::credentials::save(key, &hash.salt, password)
                } else {
                    crate::nikodesk::credentials::delete(key)
                }
            });
        if result.is_err() {
            self.remember = false;
            self.credential_warning = Some("Saved credentials could not be updated. This connection remains authenticated. Retry from the device password dialog.");
            log::warn!("NikoDesk secure credential persistence was not confirmed");
        } else {
            self.remember = remember;
            self.stored_credential = if remember {
                self.peer_storage_key
                    .as_ref()
                    .and_then(|key| crate::nikodesk::credentials::load(key).ok().flatten())
                    .filter(|stored| {
                        stored.password_for_salt(&hash.salt).as_deref() == Some(password)
                    })
            } else {
                None
            };
            self.using_stored_credential = self.stored_credential.is_some();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(not(feature = "nikodesk-dev-profile"))]
    fn handler(namespace: &str) -> LoginConfigHandler {
        let scope = crate::nikodesk::server_scope::ServerScope::from_namespace(namespace).unwrap();
        let mut handler = LoginConfigHandler::default();
        handler.peer_storage_key = scope.peer_key("123456789");
        handler
    }

    #[cfg(not(feature = "nikodesk-dev-profile"))]
    #[test]
    fn rejected_saved_password_removes_only_its_captured_scope_and_retains_opt_in() {
        use crate::nikodesk::credentials::{self, TestStore};
        let _storage = TestStore::new();
        let mut first = handler(&"a".repeat(64));
        let second = handler(&"b".repeat(64));
        for entry in [&first, &second] {
            credentials::save(entry.peer_storage_key.as_ref().unwrap(), "salt", &[7; 32]).unwrap();
        }
        first.initialize_credentials(None);
        assert_eq!(first.credential_password("salt"), Some(vec![7; 32]));
        assert!(first.reject_stored_credential().is_some());
        assert!(first.remember);
        assert!(credentials::load(first.peer_storage_key.as_ref().unwrap())
            .unwrap()
            .is_none());
        assert!(credentials::load(second.peer_storage_key.as_ref().unwrap())
            .unwrap()
            .is_some());
        assert!(first.reject_stored_credential().is_none());
    }

    #[cfg(not(feature = "nikodesk-dev-profile"))]
    #[test]
    fn changed_salt_revokes_saved_reference_without_saving_a_retry() {
        use crate::nikodesk::credentials::{self, TestStore};
        let _storage = TestStore::new();
        let mut handler = handler(&"a".repeat(64));
        let key = handler.peer_storage_key.as_ref().unwrap().clone();
        credentials::save(&key, "old-salt", &[7; 32]).unwrap();
        handler.initialize_credentials(None);
        assert!(handler.credential_password("new-salt").is_none());
        assert!(handler.remember);
        assert!(handler
            .credential_warning
            .unwrap()
            .contains("no longer valid"));
        assert!(credentials::load(&key).unwrap().is_none());
        let hash = Hash {
            salt: "new-salt".to_owned(),
            ..Default::default()
        };
        handler.credential_choice = Some(true);
        assert!(credentials::load(&key).unwrap().is_none());
        handler.persist_authenticated_credential(&[8; 32], &hash);
        assert_eq!(
            credentials::load(&key)
                .unwrap()
                .unwrap()
                .password_for_salt("new-salt"),
            Some(vec![8; 32])
        );
        // A repeated success with no new local choice cannot overwrite it.
        handler.persist_authenticated_credential(&[9; 32], &hash);
        assert_eq!(
            credentials::load(&key)
                .unwrap()
                .unwrap()
                .password_for_salt("new-salt"),
            Some(vec![8; 32])
        );
    }

    #[cfg(not(feature = "nikodesk-dev-profile"))]
    #[test]
    fn manually_entered_wrong_password_preserves_the_saved_reference() {
        use crate::nikodesk::credentials::{self, TestStore};
        let _storage = TestStore::new();
        let mut handler = handler(&"a".repeat(64));
        let key = handler.peer_storage_key.as_ref().unwrap().clone();
        credentials::save(&key, "salt", &[7; 32]).unwrap();
        handler.initialize_credentials(None);
        handler.credential_choice = Some(false);
        handler.password = vec![8; 32];
        assert!(handler.reject_stored_credential().is_none());
        assert_eq!(
            credentials::load(&key)
                .unwrap()
                .unwrap()
                .password_for_salt("salt"),
            Some(vec![7; 32])
        );
        // Successful explicit unremembered input, rather than failure/cancel,
        // is the existing authorization to remove the saved credential.
        handler.persist_authenticated_credential(
            &[8; 32],
            &Hash {
                salt: "salt".to_owned(),
                ..Default::default()
            },
        );
        assert!(credentials::load(&key).unwrap().is_none());
    }

    #[cfg(not(feature = "nikodesk-dev-profile"))]
    #[test]
    fn unavailable_delete_keeps_storage_present_and_reports_uncertainty() {
        use crate::nikodesk::credentials::{self, TestStore};
        let storage = TestStore::new();
        let mut handler = handler(&"a".repeat(64));
        let key = handler.peer_storage_key.as_ref().unwrap().clone();
        credentials::save(&key, "salt", &[7; 32]).unwrap();
        handler.initialize_credentials(None);
        assert!(handler.credential_password("salt").is_some());
        storage.fail_delete();
        let warning = handler.reject_stored_credential().unwrap();
        assert!(warning.contains("could not confirm"));
        assert!(handler.remember);
        assert!(handler.stored_credential.is_none());
        assert!(credentials::load(&key).unwrap().is_some());
    }

    #[cfg(not(feature = "nikodesk-dev-profile"))]
    #[test]
    fn late_rejection_preserves_a_newer_successful_credential() {
        use crate::nikodesk::credentials::{self, TestStore};
        let _storage = TestStore::new();
        let mut handler = handler(&"a".repeat(64));
        let key = handler.peer_storage_key.as_ref().unwrap().clone();
        credentials::save(&key, "salt", &[7; 32]).unwrap();
        handler.initialize_credentials(None);
        assert!(handler.credential_password("salt").is_some());
        credentials::save(&key, "salt", &[8; 32]).unwrap();
        handler.reject_stored_credential();
        assert_eq!(
            credentials::load(&key)
                .unwrap()
                .unwrap()
                .password_for_salt("salt"),
            Some(vec![8; 32])
        );
    }

    #[cfg(not(feature = "nikodesk-dev-profile"))]
    #[test]
    fn default_authentication_does_not_create_a_saved_credential() {
        use crate::nikodesk::credentials::{self, TestStore};
        let _storage = TestStore::new();
        let mut handler = handler(&"a".repeat(64));
        handler.initialize_credentials(None);
        assert!(!handler.remember);
        handler.persist_authenticated_credential(
            &[7; 32],
            &Hash {
                salt: "salt".to_owned(),
                ..Default::default()
            },
        );
        assert!(
            credentials::load(handler.peer_storage_key.as_ref().unwrap())
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn flutter_choice_metadata_accepts_explicit_true_and_false_without_secrets() {
        for remember in [false, true] {
            let token = serde_json::json!({"nikodesk_credentials": {
                "schema": 1, "namespace": "a".repeat(64), "remember": remember
            }})
            .to_string();
            let choice: Metadata = serde_json::from_str(&token).unwrap();
            assert_eq!(choice.nikodesk_credentials.schema, 1);
            assert_eq!(choice.nikodesk_credentials.namespace, "a".repeat(64));
            assert_eq!(choice.nikodesk_credentials.remember, remember);
        }
        let secret_bearing = serde_json::json!({"nikodesk_credentials": {
            "schema": 1, "namespace": "a".repeat(64), "remember": true,
            "password": "synthetic-secret"
        }})
        .to_string();
        assert!(serde_json::from_str::<Metadata>(&secret_bearing).is_err());
    }

    #[test]
    fn native_reconnect_api_does_not_export_an_authentication_secret() {
        let mut handler = LoginConfigHandler::default();
        handler.password = vec![7; 32];
        handler.session_id = 123;
        assert!(handler.get_conn_token().is_none());
        handler.password.clear();
        assert!(handler.get_conn_token().is_none());
    }
}
