//! Verified, immutable SYSTEM startup snapshot. This is not an authorization
//! grant: the caller supplies protected-handle bytes and the OS-derived context.
use super::{
    machine_profile::decode_runtime_fields, Config, Config2, KeyPair, MachineEncryptionContext,
};

pub struct MachineRuntimeProfile {
    context: MachineEncryptionContext,
    identity: Config,
    settings: Config2,
}

impl MachineRuntimeProfile {
    pub fn decode(
        context: MachineEncryptionContext,
        identity_bytes: &[u8],
        settings_bytes: &[u8],
    ) -> anyhow::Result<Self> {
        let (identity, settings) = decode_runtime_fields(&context, identity_bytes, settings_bytes)?;
        Ok(Self {
            context,
            identity,
            settings,
        })
    }

    pub fn public_id(&self) -> &str {
        &self.identity.id
    }
    pub fn public_key(&self) -> &[u8] {
        &self.identity.key_pair.1
    }

    pub(super) fn identity_snapshot(&self) -> Config {
        self.identity.clone()
    }
    pub(super) fn settings_snapshot(&self) -> Config2 {
        self.settings.clone()
    }
    pub(super) fn key_pair(&self) -> KeyPair {
        self.identity.key_pair.clone()
    }
    pub(crate) fn crypt(&self, data: &[u8], encrypt: bool) -> Result<Vec<u8>, ()> {
        self.context.crypt(data, encrypt)
    }
}

impl Drop for MachineRuntimeProfile {
    fn drop(&mut self) {
        sodiumoxide::utils::memzero(&mut self.identity.key_pair.0);
    }
}

#[cfg(test)]
pub(super) fn fixture_files() -> std::collections::BTreeMap<String, Vec<u8>> {
    use super::{
        FreshMachineIdentity, MachineProfileFactory, MachineProfileServer,
        MachineUnattendedPassword,
    };
    let profile = MachineProfileFactory::prepare(
        &MachineEncryptionContext::fixture(),
        FreshMachineIdentity::generate().unwrap(),
        MachineProfileServer::new(
            "nas.fixture.local:21116".into(),
            "relay.fixture.local:21117".into(),
            sodiumoxide::base64::encode([7; 32], sodiumoxide::base64::Variant::Original),
        )
        .unwrap(),
        MachineUnattendedPassword::from_explicit_user_entry("fixture-only password".into())
            .unwrap(),
    )
    .unwrap();
    profile.files().clone()
}

#[cfg(test)]
pub(super) fn fixture_profile() -> MachineRuntimeProfile {
    let files = fixture_files();
    MachineRuntimeProfile::decode(
        MachineEncryptionContext::fixture(),
        &files["NikoDesk.toml"],
        &files["NikoDesk2.toml"],
    )
    .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;
    use sodiumoxide::{base64, crypto::secretbox, utils::memzero};
    use std::{collections::BTreeMap, path::PathBuf};

    fn decode(files: &BTreeMap<String, Vec<u8>>) -> anyhow::Result<MachineRuntimeProfile> {
        MachineRuntimeProfile::decode(
            MachineEncryptionContext::fixture(),
            &files["NikoDesk.toml"],
            &files["NikoDesk2.toml"],
        )
    }
    fn change(files: &mut BTreeMap<String, Vec<u8>>, name: &str, f: impl FnOnce(&mut toml::Value)) {
        let mut value: toml::Value =
            toml::from_str(std::str::from_utf8(&files[name]).unwrap()).unwrap();
        f(&mut value);
        files.insert(name.into(), toml::to_string(&value).unwrap().into_bytes());
    }
    fn set(value: &mut toml::Value, key: &str, field: toml::Value) {
        value.as_table_mut().unwrap().insert(key.into(), field);
    }

    #[test]
    fn machine_runtime_roundtrip_keeps_actual_identity_key_and_verifier() {
        let files = fixture_files();
        let profile = decode(&files).unwrap();
        let original: Config =
            toml::from_str(std::str::from_utf8(&files["NikoDesk.toml"]).unwrap()).unwrap();
        let config = profile.identity_snapshot();
        assert_eq!(config.key_pair, original.key_pair);
        assert_eq!(config.enc_id, original.enc_id);
        assert_eq!(config.password, original.password);
        assert_eq!(config.salt, original.salt);
        assert_eq!(profile.public_id().len(), 10);
        assert_eq!(profile.public_key(), &original.key_pair.1);
        let payload = base64::decode(&config.password[2..], base64::Variant::Original).unwrap();
        let mut plaintext = profile.crypt(&payload, false).unwrap();
        let h1 = super::super::permanent_password::decode_permanent_password_h1_from_hashed_storage(
            std::str::from_utf8(&plaintext).unwrap(),
        );
        memzero(&mut plaintext);
        assert_eq!(
            h1,
            Some(super::super::compute_permanent_password_h1(
                "fixture-only password",
                &config.salt
            ))
        );
    }

    #[test]
    fn machine_runtime_accepts_legitimate_registration_and_latency_restart_state() {
        let mut files = fixture_files();
        change(&mut files, "NikoDesk.toml", |v| {
            v["key_confirmed"] = true.into();
            set(&mut v["keys_confirmed"], "nas.fixture.local", true.into());
        });
        change(&mut files, "NikoDesk2.toml", |v| {
            v["nat_type"] = 2.into();
            v["serial"] = 123.into();
            v["rendezvous_server"] = "nas.fixture.local:21116".into();
            set(
                &mut v["options"],
                "rendezvous-servers",
                "nas.fixture.local,nas.fixture.local:21116".into(),
            );
        });
        let p = decode(&files).unwrap();
        assert!(p.identity_snapshot().key_confirmed);
        assert_eq!(
            p.identity_snapshot()
                .keys_confirmed
                .get("nas.fixture.local"),
            Some(&true)
        );
        assert_eq!(p.settings_snapshot().nat_type, 2);
        assert_eq!(p.settings_snapshot().serial, 123);
    }

    #[test]
    fn machine_runtime_rejects_wrong_context_or_corrupted_current_ciphertext() {
        let mut files = fixture_files();
        assert!(MachineRuntimeProfile::decode(
            MachineEncryptionContext::fixture_other(),
            &files["NikoDesk.toml"],
            &files["NikoDesk2.toml"]
        )
        .is_err());
        change(&mut files, "NikoDesk.toml", |v| {
            let mut payload = base64::decode(
                &v["enc_id"].as_str().unwrap()[2..],
                base64::Variant::Original,
            )
            .unwrap();
            *payload.last_mut().unwrap() ^= 1;
            v["enc_id"] =
                ("00".to_owned() + &base64::encode(payload, base64::Variant::Original)).into();
        });
        assert!(decode(&files).is_err());
    }

    #[test]
    fn machine_runtime_rejects_plain_or_legacy_identity_and_password_formats() {
        for (field, value) in [
            ("id", "1234567890"),
            ("enc_id", "1234567890"),
            ("password", "plaintext"),
            ("password", "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
        ] {
            let mut files = fixture_files();
            change(&mut files, "NikoDesk.toml", |v| {
                set(v, field, value.into());
            });
            assert!(decode(&files).is_err());
        }
        let p = fixture_profile();
        assert!(p.crypt(&[0; secretbox::MACBYTES + 10], false).is_err());
        let key = secretbox::Key([7; 32]);
        let legacy = secretbox::seal(b"old", &secretbox::Nonce([0; 24]), &key);
        assert!(p.crypt(&legacy, false).is_err());
    }

    #[test]
    fn machine_runtime_rejects_nonmatching_key_pair_salt_and_malformed_verifier() {
        for field in ["key_pair", "salt", "password"] {
            let mut files = fixture_files();
            change(&mut files, "NikoDesk.toml", |v| match field {
                "key_pair" => {
                    let first = v["key_pair"][1][0].as_integer().unwrap();
                    v["key_pair"][1][0] = (first ^ 1).into();
                }
                "salt" => {
                    v["salt"] = "!".repeat(32).into();
                }
                _ => {
                    v["password"] = "01AAAA".into();
                }
            });
            assert!(decode(&files).is_err());
        }
    }

    #[test]
    fn machine_runtime_dangerous_missing_and_unknown_options_fail_closed() {
        for (field, value) in [
            ("stop-service", "Y"),
            ("enable-tunnel", "Y"),
            ("enable-camera", "Y"),
            ("allow-remote-config-modification", "Y"),
            ("key", ""),
            ("conn-type", "outgoing"),
            ("unknown", "Y"),
            ("rendezvous-servers", "other.fixture.local:21116"),
        ] {
            let mut files = fixture_files();
            change(&mut files, "NikoDesk2.toml", |v| {
                set(&mut v["options"], field, value.into());
            });
            assert!(decode(&files).is_err());
        }
        let mut files = fixture_files();
        change(&mut files, "NikoDesk2.toml", |v| {
            v["options"].as_table_mut().unwrap().remove("stop-service");
        });
        assert!(decode(&files).is_err());
    }

    #[test]
    fn machine_runtime_proxy_unlock_trust_and_invalid_runtime_numbers_are_rejected() {
        for (field, value) in [
            ("unlock_pin", toml::Value::from("00pin")),
            ("trusted_devices", toml::Value::from("trusted")),
            ("nat_type", toml::Value::from(3)),
            ("serial", toml::Value::from(-1)),
            (
                "rendezvous_server",
                toml::Value::from("other.fixture.local:21116"),
            ),
        ] {
            let mut files = fixture_files();
            change(&mut files, "NikoDesk2.toml", |v| {
                set(v, field, value);
            });
            assert!(decode(&files).is_err());
        }
        let mut files = fixture_files();
        change(&mut files, "NikoDesk2.toml", |v| {
            set(v, "socks", toml::Value::Table(Default::default()));
        });
        assert!(decode(&files).is_err());
    }

    #[test]
    fn machine_runtime_strict_types_and_file_bounds_fail_without_config_fallback() {
        for name in ["NikoDesk.toml", "NikoDesk2.toml"] {
            for bytes in [Vec::new(), vec![0xff], vec![b'x'; 128 * 1024 + 1]] {
                let mut files = fixture_files();
                files.insert(name.into(), bytes);
                assert!(decode(&files).is_err());
            }
        }
        let mut files = fixture_files();
        change(&mut files, "NikoDesk.toml", |v| {
            v["key_confirmed"] = "true".into();
        });
        assert!(decode(&files).is_err());
        let mut files = fixture_files();
        let original = files["NikoDesk.toml"].clone();
        files.insert(
            "NikoDesk.toml".into(),
            [b"key_confirmed = false\n".as_slice(), &original].concat(),
        );
        assert!(decode(&files).is_err());
        let mut files = fixture_files();
        files
            .get_mut("NikoDesk2.toml")
            .unwrap()
            .extend_from_slice(b"\nextra = 1\n");
        assert!(decode(&files).is_err());
    }

    #[test]
    fn machine_runtime_confirmation_maps_are_bounded_and_not_permissively_coerced() {
        for bad in ["", "bad\nname"] {
            let mut files = fixture_files();
            change(&mut files, "NikoDesk.toml", |v| {
                set(&mut v["keys_confirmed"], bad, true.into());
            });
            assert!(decode(&files).is_err());
        }
        let mut files = fixture_files();
        change(&mut files, "NikoDesk.toml", |v| {
            for n in 0..257 {
                set(
                    &mut v["keys_confirmed"],
                    &format!("fixture-{n}"),
                    true.into(),
                );
            }
        });
        assert!(decode(&files).is_err());
    }

    #[test]
    fn machine_runtime_global_snapshot_avoids_second_file_read_and_uuid_fallback() {
        // Run this exact filter in a fresh test process. No OS UID getter or
        // real Config path is accessed; the selected fixture root has no files.
        let p = fixture_profile();
        let expected = p.identity_snapshot();
        let expected_settings = p.settings_snapshot();
        let root: PathBuf =
            std::env::temp_dir().join(format!("nikodesk-runtime-no-io-{}", std::process::id()));
        assert!(!root.exists());
        Config::initialize_trusted_machine_runtime(root.clone(), p).unwrap();
        for _ in 0..3 {
            assert_eq!(Config::trusted_machine_runtime_options(), Some(expected_settings.options.clone()));
            assert!(Config::load() == expected);
            assert!(Config2::load() == expected_settings);
            assert!(Config::get().key_pair == expected.key_pair);
            assert!(Config::get_key_pair() == expected.key_pair);
            assert!(Config::get_existing_key_pair() == Some(expected.key_pair.clone()));
            let mut ciphertext =
                crate::password_security::symmetric_crypt(b"fixture", true).unwrap();
            assert_eq!(
                crate::password_security::symmetric_crypt(&ciphertext, false).unwrap(),
                b"fixture"
            );
            *ciphertext.last_mut().unwrap() ^= 1;
            assert!(crate::password_security::symmetric_crypt(&ciphertext, false).is_err());
        }
        assert_eq!(
            super::super::decode_permanent_password_h1_from_storage(&expected.password),
            Some(super::super::compute_permanent_password_h1(
                "fixture-only password",
                &expected.salt
            ))
        );
        let public_key = secretbox::Key::from_slice(&expected.key_pair.1).unwrap();
        let nonce = secretbox::gen_nonce();
        let mut fallback_ciphertext = vec![1];
        fallback_ciphertext.extend_from_slice(&nonce.0);
        fallback_ciphertext.extend_from_slice(&secretbox::seal(
            b"public-key-fallback",
            &nonce,
            &public_key,
        ));
        assert!(crate::password_security::symmetric_crypt(&fallback_ciphertext, false).is_err());
        assert!(
            Config::initialize_trusted_machine_runtime(root.clone(), fixture_profile()).is_err()
        );
        assert!(!root.exists());
        let mut scratch = expected.key_pair.0;
        memzero(&mut scratch);
    }
}
