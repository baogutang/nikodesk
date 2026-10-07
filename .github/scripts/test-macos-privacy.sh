#!/usr/bin/env bash
# Test the production monitor callbacks with in-memory providers only.
set -euo pipefail
cd "$(dirname "$0")/../.."
privacy_test_dir=$(mktemp -d)
trap 'rm -rf "$privacy_test_dir"' EXIT
xcrun clang++ -std=c++17 -I src/platform \
  .github/scripts/tests/native/test-macos-privacy-transaction.cpp \
  -o "$privacy_test_dir/transaction"
"$privacy_test_dir/transaction"
xcrun clang++ -std=c++17 -fblocks -I src/platform \
  .github/scripts/tests/native/test-macos-privacy-monitor.mm \
  -framework AppKit -framework CoreGraphics -framework ColorSync -framework Security \
  -o "$privacy_test_dir/monitor"
"$privacy_test_dir/monitor"
