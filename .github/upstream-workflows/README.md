# Preserved upstream workflows

These original workflows are archived as `.disabled` and are not discovered by GitHub Actions. They include upstream release/upload/signing operations and secrets inappropriate for NikoDesk. No automatic publishing, upstream credential use, external build, or artifact upload is authorized.

The tested local macOS build entry point is `../../scripts/build-macos.sh nikodesk` from the parent implementation workspace. Windows/Android builds are not currently verified; NikoDesk core intentionally rejects non-macOS initialization until platform isolation is implemented and tested.
