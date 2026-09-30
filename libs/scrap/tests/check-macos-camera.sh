#!/usr/bin/env bash
# Runs only in-memory frame/provider tests. Never opens a device or requests TCC.
set -euo pipefail
repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workspace="$(dirname "$repository")"
source "$workspace/scripts/env.sh"
output="${1:-$workspace/artifacts/m6-camera}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
cd "$repository"
native="$workspace/.tools/vcpkg-nikodesk/installed/arm64-osx"
flags=(-std=c++17 -fobjc-arc -fblocks -mmacosx-version-min=12.3 -Wall -Wextra -Werror -Wno-unused-parameter)
frameworks=(-framework AVFoundation -framework Foundation -framework CoreMedia -framework CoreVideo)
xcrun clang++ "${flags[@]}" -c libs/scrap/src/common/macos_camera.mm -o "$output/macos_camera-production.o"
if nm -gU "$output/macos_camera-production.o" | rg 'NKCameraTest'; then
  echo 'Test-provider symbol in production object' >&2; exit 1
fi
xcrun clang++ "${flags[@]}" -DNIKODESK_CAMERA_TEST_HOOKS \
  libs/scrap/src/common/macos_camera.mm libs/scrap/tests/macos_camera_native.mm \
  -I"$native/include" "$native/lib/libyuv.a" "$native/lib/libvpx.a" "${frameworks[@]}" \
  -o "$output/native-buffer-tests"
"$output/native-buffer-tests" | tee "$output/native-buffer-tests.log"
xcrun clang++ "${flags[@]}" -DNIKODESK_CAMERA_TEST_HOOKS -c \
  libs/scrap/src/common/macos_camera.mm -o "$output/macos_camera-test.o"
RUSTUP_TOOLCHAIN=1.88.0 rustc --edition=2018 --test --cfg nikodesk_camera_native_tests \
  libs/scrap/src/common/macos_camera.rs -C "link-arg=$output/macos_camera-test.o" \
  -l framework=AVFoundation -l framework=Foundation -l framework=CoreMedia -l framework=CoreVideo -l c++ \
  -o "$output/rust-buffer-tests"
"$output/rust-buffer-tests" --nocapture | tee "$output/rust-buffer-tests.log"
