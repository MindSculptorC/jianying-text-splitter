#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
ZIP="dist/jianying-text-splitter-v2.0.1-macos-universal.zip"
ditto -c -k --keepParent --norsrc "dist/剪映文本切段助手.app" "$ZIP"
cp README.md dist/使用说明.md
(cd dist && LC_ALL=C shasum -a 256 "jianying-text-splitter-v2.0.1-macos-universal.zip" "使用说明.md" > SHA256SUMS.txt)
printf '%s\n' "Packaged: $PWD/$ZIP"
