# NikoDesk 1.0.3

Product version `1.0.3`, build `12`; native protocol `1.5.0`. This patch preserves the published 1.0.1 and 1.0.2 tags and packages.

## Configuration recovery

The installed macOS 1.0.2 log confirmed that background-access setup called the obsolete bulk-settings API. The NikoDesk native core rejected that write and marked the in-memory settings state unconfirmed; configuration reads then returned an empty result. The existing disk configuration remained present. Restarting the upgraded application clears this old process state.

Background setup now verifies its private-server configuration and namespace, saves the permanent password with confirmation, changes authentication through individual option patches, and verifies the same server and final authentication policy before registering background recovery. Selecting permanent-password authentication precedes changing click approval. A failed or changed read prevents background registration; completed saves are reported honestly and are not automatically rolled back. Leaving the page while saving prevents a subsequent background registration.

Private-server settings are parsed strictly. A missing, malformed or timed-out registration-status observation stays unknown without hiding readable local configuration. Unknown configuration is never replaced by a blank editable form. The network page retains its read until explicitly refreshed and provides same-page retry. It immediately listens for read failures even on narrow displays with large text. The home server card distinguishes failed reads from unconfigured settings and ignores older overlapping status results.

## Update checks

Windows update selection requires the exact portable EXE basename; the setup-validation installer cannot win because its filename shares the same prefix. A malformed successful release response reports a check failure instead of appearing to have no update. Product-version regressions verify that 1.0.2 sees 1.0.3 despite the separate native protocol version.

The existing macOS updater continues to verify release checksums, inspect and extract the ZIP, validate the complete application and stage it for manual installation. It does not automatically replace the installed application. Stable and nightly remain distinct channels.

## Delivery and verification boundaries

The v1.0.3 tag builds all seven macOS ARM64, Windows x64 and Android ARM64 packages plus SHA256SUMS after platform and packaging gates pass. Android retains its release application ID and signing certificate and advances versionCode from 11 to 12. macOS remains ad-hoc signed without Developer ID notarization; Windows remains unsigned.

Focused bridge and widget regressions exercise configuration failures, same-page retry, authentication readbacks, scope changes, lifecycle cancellation, large-text layouts and update metadata/asset selection without native password writes, agent registration or installation. The existing installed RustDesk, its services, credentials and active remote session are preserved. Package validation and same-machine historical sessions do not establish cross-device performance, actual background lifecycle or Windows/Android installation acceptance.

Local full regression: Niko Flutter 1002 passed / 2 existing skips; stock Flutter 981 passed / 6 existing skips. Native Niko-name-filter tests: 521 passed / 1 optional probe ignored / 329 upstream tests outside the filter; feature-off native lib/bins compilation passed. Packaging Python: 142 cases / 1 existing skip plus 9 portable cases. Dart analysis: 0 errors, 0 warnings, 291 informational notices. The independent before/after lifecycle and late-registration fixtures pass after repair; their original failing logs are retained in the implementation workspace. Actual public package and installed-client update discovery are verified separately after publication.
