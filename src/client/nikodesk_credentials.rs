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
        if password.is_none() {
            self.stored_credential = None;
            if self.credential_choice.is_none() {
                self.remember = false;
            }
        }
        password
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
            if !remember {
                self.stored_credential = None;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
