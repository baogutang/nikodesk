//! Build-time release pins. Runtime CLI/JSON never creates this authority.
use super::policy::{self, ReleaseManifest};
use hbb_common::{
    anyhow::{anyhow, bail, Result},
    serde_derive::Deserialize,
};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum TrustMode {
    SignedProduction,
    ReviewedLocalUnsignedValidation,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UiPin {
    name: String,
    sha256: String,
    length: u64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    schema: u32,
    product_version: String,
    product_build: u32,
    trust_mode: String,
    ui_runner: UiPin,
    service_payload: ReleaseManifest,
}

pub(super) struct EmbeddedRelease {
    document: Document,
    mode: TrustMode,
    ui_sha: [u8; 32],
}
impl EmbeddedRelease {
    pub(super) fn compiled() -> Result<Self> {
        let bytes = option_env!("NIKODESK_SETUP_RELEASE_JSON")
            .ok_or_else(|| anyhow!("install_fixed_windows_release_unavailable"))?;
        Self::parse_compiled(bytes)
    }
    fn parse_compiled(text: &str) -> Result<Self> {
        if text.is_empty() || text.len() > 128 * 1024 {
            bail!("install_embedded_release_invalid");
        }
        let document: Document =
            serde_json::from_str(text).map_err(|_| anyhow!("install_embedded_release_invalid"))?;
        document.service_payload.validate()?;
        if document.schema != 1
            || document.product_version != document.service_payload.version
            || document.product_build != document.service_payload.build
            || !policy::leaf(&document.ui_runner.name)
            || !document
                .ui_runner
                .name
                .to_ascii_lowercase()
                .ends_with(".exe")
            || !policy::hex(&document.ui_runner.sha256)
            || document.ui_runner.length == 0
            || document.ui_runner.length > policy::MAX_PAYLOAD_BYTES
        {
            bail!("install_embedded_release_invalid");
        }
        let mode = match document.trust_mode.as_str() {
            "signed-production" => TrustMode::SignedProduction,
            "reviewed-local-unsigned-validation" => TrustMode::ReviewedLocalUnsignedValidation,
            _ => bail!("install_embedded_trust_mode_invalid"),
        };
        let mut ui_sha = [0; 32];
        for (index, byte) in ui_sha.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&document.ui_runner.sha256[index * 2..index * 2 + 2], 16)
                .map_err(|_| anyhow!("install_embedded_release_invalid"))?;
        }
        if ui_sha == [0; 32] {
            bail!("install_embedded_release_invalid");
        }
        Ok(Self {
            document,
            mode,
            ui_sha,
        })
    }
    pub(super) fn mode(&self) -> TrustMode {
        self.mode
    }
    pub(super) fn ui_sha(&self) -> [u8; 32] {
        self.ui_sha
    }
    pub(super) fn ui_length(&self) -> u64 {
        self.document.ui_runner.length
    }
    pub(super) fn ui_path(&self, directory: &Path) -> PathBuf {
        directory.join(&self.document.ui_runner.name)
    }
    pub(super) fn payload(&self) -> &ReleaseManifest {
        &self.document.service_payload
    }
    pub(super) fn version(&self) -> &str {
        &self.document.product_version
    }
    pub(super) fn build(&self) -> u32 {
        self.document.product_build
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn document() -> serde_json::Value {
        serde_json::json!({
        "schema":1,"product_version":"1.1.0","product_build":6,
        "trust_mode":"reviewed-local-unsigned-validation",
        "ui_runner":{"name":"NikoDesk.exe","sha256":"a".repeat(64),"length":100},
        "service_payload":{"version":"1.1.0","build":6,"files":{
            "nikodesk-host.exe":{"sha256":"b".repeat(64),"length":100}}}})
    }
    #[test]
    fn compiled_missing_release_never_uses_fixture_or_sidecar() {
        if option_env!("NIKODESK_SETUP_RELEASE_JSON").is_none() {
            assert!(EmbeddedRelease::compiled().is_err());
        }
    }
    #[test]
    fn fixed_manifest_requires_exact_product_and_payload_pins() {
        let mut value = document();
        assert!(EmbeddedRelease::parse_compiled(&value.to_string()).is_ok());
        for field in ["product_build", "schema"] {
            value = document();
            value[field] = 0.into();
            assert!(EmbeddedRelease::parse_compiled(&value.to_string()).is_err());
        }
        value = document();
        value["ui_runner"]["sha256"] = "0".repeat(64).into();
        assert!(EmbeddedRelease::parse_compiled(&value.to_string()).is_err());
        value = document();
        value["trust_mode"] = "skip-signature".into();
        assert!(EmbeddedRelease::parse_compiled(&value.to_string()).is_err());
    }
}
