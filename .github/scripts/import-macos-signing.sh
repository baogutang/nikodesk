#!/usr/bin/env bash
# Import the fixed NikoDesk self-signed code-signing identity into a temporary
# keychain for this job. Fails closed: a release build must never fall back to
# an ad-hoc signature, because that would drop users' macOS privacy grants.
set -euo pipefail
umask 077

: "${P12_BASE64:?NIKODESK_MACOS_CODESIGN_P12_BASE64 secret is missing}"
: "${P12_PASSWORD:?NIKODESK_MACOS_CODESIGN_P12_PASSWORD secret is missing}"
: "${NIKODESK_MACOS_CODESIGN_SHA1:?pinned certificate SHA-1 is missing}"
: "${RUNNER_TEMP:?}"

keychain="$RUNNER_TEMP/nikodesk-signing.keychain-db"
p12="$RUNNER_TEMP/nikodesk-codesign.p12"
keychain_password=$(openssl rand -hex 32)

printf '%s' "$P12_BASE64" | base64 --decode >"$p12"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -f pkcs12 -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -f "$p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$keychain"

if ! security find-identity -p codesigning "$keychain" | grep -q "$NIKODESK_MACOS_CODESIGN_SHA1"; then
  echo "The imported identity does not match the pinned NikoDesk certificate" >&2
  exit 1
fi
echo "NIKODESK_CODESIGN_KEYCHAIN=$keychain" >>"$GITHUB_ENV"
