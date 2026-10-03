# Native serializer fixtures

These tracked JSON files make Flutter tests independent of local build artifacts
and checkout layout. Run Flutter tests from `flutter/`, as required by Flutter.
The fixtures contain deterministic synthetic test inputs serialized by the actual
production Rust types. They are contract fixtures, not remote-session evidence.

| File | Producing Rust test | Production serializer |
| --- | --- | --- |
| `tunnel-flow-serde.json` | `nikodesk::tunnel_flow::tests::actual_serde_contract_fixture_contains_pending_and_queued_not_fake_running` | `src/nikodesk/tunnel_flow.rs`: `Status`, `Command`, `Reply` |
| `tunnel-controller-serde.json` | `client::nikodesk_tunnel::ui::tests::controller_status_fixture_uses_production_serializer` | `src/client/nikodesk_tunnel_ui.rs`: `Publisher` status |
| `unattended-install-serde.json` | `nikodesk::unattended_install::tests::install_status_fixture_uses_actual_reply_serializer` | `src/nikodesk/unattended_install.rs`: `Reply::json` |

The inputs come only from the listed Rust tests: namespace `a` repeated 64 times,
peer IDs `123456789`/`1234567890`, fixed `01`/`02` nonces, loopback addresses, and
the fixed test job UUID `f2ee6922-ce2e-4bb4-82df-0b8c2bcc0498`. No server
configuration, credential, private key, log, clipboard or screen content is used.
The installation fixture records status only and does not install or launch a
service. The tunnel fixtures do not open a remote connection.

To regenerate on the configured macOS build environment, run these commands from
the repository root. Configure the pinned Rust/native dependencies as described in
`docs/BUILDING.md` first. Each exact filter must report one passing test.

```bash
cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,nikodesk nikodesk::tunnel_flow::tests::actual_serde_contract_fixture_contains_pending_and_queued_not_fake_running -- --exact --nocapture > /tmp/nikodesk-tunnel-flow-serde.log
python3 - <<'PY'
import json
from pathlib import Path
marker = 'NIKODESK_TUNNEL_ACTUAL_SERDE:'
lines = Path('/tmp/nikodesk-tunnel-flow-serde.log').read_text().splitlines()
outputs = [line.split(marker, 1)[1] for line in lines if marker in line]
assert len(outputs) == 1
Path('flutter/test/fixtures/nikodesk/tunnel-flow-serde.json').write_text(
    json.dumps(json.loads(outputs[0]), indent=2, sort_keys=True) + '\n')
PY
NIKODESK_TUNNEL_CONTROLLER_FIXTURE="$PWD/flutter/test/fixtures/nikodesk/tunnel-controller-serde.json" cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,nikodesk client::nikodesk_tunnel::ui::tests::controller_status_fixture_uses_production_serializer -- --exact --nocapture
NIKODESK_INSTALL_STATUS_FIXTURE="$PWD/flutter/test/fixtures/nikodesk/unattended-install-serde.json" cargo test --locked --lib --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,nikodesk nikodesk::unattended_install::tests::install_status_fixture_uses_actual_reply_serializer -- --exact --nocapture
```

Review serializer/input changes before updating these files. Preserve the Flutter
boundary assertions; do not replace these fixtures with runtime exports or weaken
the tests to accept missing files.
