#!/bin/bash
set -euo pipefail
media_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
media_flags=(-O2 -fobjc-arc -Wno-deprecated-declarations -Wno-incompatible-pointer-types
  -mmacosx-version-min=11.0 -arch arm64 -arch x86_64
  -framework Foundation -framework AVFoundation -framework CoreGraphics -framework CoreMedia)
xcrun clang "${media_flags[@]}" "$media_dir/media_export.m" -o "$media_dir/media-export"
xcrun clang "${media_flags[@]}" -framework CoreVideo -framework AudioToolbox \
  "$media_dir/media_fixture.m" -o "$media_dir/media-fixture"
echo "Built media-export and media-fixture (arm64 + x86_64)"
