#!/usr/bin/env bash

set -euo pipefail

app_path=$1
identity=$2
entitlements=$3

sign_args=(--force --options runtime --sign "$identity")
if [[ "$identity" != "-" ]]; then
  # The fixed NikoDesk certificate is self-signed; Apple's timestamp service only
  # serves Apple-issued identities. NIKODESK_CODESIGN_TIMESTAMP=apple restores it
  # for a future Developer ID.
  if [[ "${NIKODESK_CODESIGN_TIMESTAMP:-none}" == apple ]]; then
    sign_args+=(--timestamp)
  else
    sign_args+=(--timestamp=none)
  fi
fi

frameworks_path="$app_path/Contents/Frameworks"
if [[ -d "$frameworks_path" ]]; then
  while IFS= read -r -d '' code; do
    if file -b "$code" | grep -q 'Mach-O'; then
      codesign "${sign_args[@]}" "$code"
    fi
  done < <(find "$frameworks_path" -type f -print0)

  while IFS= read -r -d '' framework; do
    codesign "${sign_args[@]}" "$framework"
  done < <(find "$frameworks_path" -depth -type d -name '*.framework' -print0)
fi

service_path="$app_path/Contents/MacOS/service"
if [[ -f "$service_path" ]]; then
  codesign "${sign_args[@]}" "$service_path"
fi

watchdog_path="$app_path/Contents/Helpers/NikoDeskPrivacyWatchdog"
if [[ -f "$watchdog_path" ]]; then
  codesign "${sign_args[@]}" --identifier io.nikodesk.privacy-watchdog "$watchdog_path"
fi

# The privileged service's daemon; root runs it only if it carries this
# identifier and the fixed certificate.
nikodesk_service_path="$app_path/Contents/MacOS/nikodesk-service"
if [[ -f "$nikodesk_service_path" ]]; then
  codesign "${sign_args[@]}" --identifier io.nikodesk.service "$nikodesk_service_path"
fi

codesign "${sign_args[@]}" --generate-entitlement-der \
  --entitlements "$entitlements" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

actual_entitlements=$(codesign -d --entitlements :- "$app_path" 2>/dev/null)
audio_input=$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw - \
  <<<"$actual_entitlements")
if [[ "$audio_input" != "true" ]]; then
  echo "Missing com.apple.security.device.audio-input entitlement" >&2
  exit 1
fi
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
if [[ "$bundle_id" == "io.nikodesk.macos" ]] && \
  /usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$app_path/Contents/Info.plist" >/dev/null 2>&1; then
  camera=$(plutil -extract 'com\.apple\.security\.device\.camera' raw - <<<"$actual_entitlements")
  if [[ "$camera" != "true" ]]; then
    echo "Missing com.apple.security.device.camera entitlement" >&2
    exit 1
  fi
fi

# A pinned certificate (given as its SHA-1) must end up in every designated
# requirement, otherwise macOS would key privacy grants to something else.
if [[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  pinned=$(tr '[:upper:]' '[:lower:]' <<<"$identity")
  check_requirement() {
    local requirement
    requirement=$(codesign -d -r- "$1" 2>&1)
    if [[ "$requirement" != *"certificate root = H\"$pinned\""* ]]; then
      echo "Designated requirement of $1 is not bound to the pinned certificate" >&2
      exit 1
    fi
  }
  check_requirement "$app_path"
  for code in "$watchdog_path" "$service_path" "$nikodesk_service_path"; do
    if [[ -f "$code" ]]; then
      check_requirement "$code"
    fi
  done
fi
