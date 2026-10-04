#!/usr/bin/env bash
# Starts the packaged app with a throwaway home directory and checks that it
# reaches its running state: the process stays up, the core starts its local
# IPC server, and nothing panics. A package that cannot start, or dies while
# reading its first configuration, fails here instead of on a user's machine.
# No private server is configured, so the app registers nowhere.
set -euo pipefail

app=$1
wait_seconds=${2:-40}
home=$(mktemp -d)
# Every macOS account has these; the app creates only its own folder inside.
mkdir -p "$home/Library/Preferences" "$home/Library/Logs" \
  "$home/Library/Application Support" "$home/Library/Caches"
logs="$home/Library/Logs/NikoDesk"
output="$home/output.log"

HOME="$home" "$app/Contents/MacOS/NikoDesk" > "$output" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

report() {
  echo "$1" >&2
  echo '--- process output ---' >&2
  tail -40 "$output" >&2 || true
  echo '--- application log ---' >&2
  find "$logs" -name '*.log' -exec tail -40 {} + >&2 2>/dev/null || true
  exit 1
}

started=0
for _ in $(seq 1 "$wait_seconds"); do
  kill -0 "$pid" 2>/dev/null || report 'NikoDesk exited during startup.'
  if grep -rqs 'Started ipc server' "$logs"; then
    started=1
    break
  fi
  sleep 1
done
[[ $started == 1 ]] || report "NikoDesk did not start its core within ${wait_seconds}s."

# A start that survives the first second can still die while the interface
# and the first settings read come up.
sleep 8
kill -0 "$pid" 2>/dev/null || report 'NikoDesk exited shortly after starting.'
if grep -rqsi 'panicked at' "$logs" "$output"; then
  report 'NikoDesk logged a panic during startup.'
fi
echo "NikoDesk started and stayed up: $(grep -rhs 'Started ipc server' "$logs" | head -1 | sed -E 's/^\[[^]]*\] *//')"
