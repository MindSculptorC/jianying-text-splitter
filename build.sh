#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
VERSION=2.0.1
APP="dist/剪映文本切段助手.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/native" "$APP/Contents/Resources/ui"
# Build every helper from source; the installed Jianying engine is needed only at runtime.
xcrun clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=12.0 \
  -arch arm64 -arch x86_64 -framework Foundation \
  -Wl,-rpath,/Applications/VideoFusion-macOS.app/Contents/Frameworks \
  native/draft_decode.mm -o native/draft_decode
bash native/build_media.sh
xcrun clang -O2 -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  native/app_status.m -framework Cocoa -o native/app-status
xcrun clang -fobjc-arc -Wno-deprecated-declarations -Wno-incompatible-pointer-types -O2 \
  -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 native/App.m native/JianyingController.m \
  -framework Cocoa -framework WebKit -framework ApplicationServices -framework AVFoundation \
  -framework CoreMedia -o "$APP/Contents/MacOS/TimelineSplitter"
cp core.py register.py workflow.py iteration.py "$APP/Contents/Resources/"
cp ui/index.html "$APP/Contents/Resources/ui/"
cp native/draft_decode native/media-export native/app-status "$APP/Contents/Resources/native/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TimelineSplitter</string><key>CFBundleIdentifier</key><string>local.jianying-text-splitter</string><key>CFBundleName</key><string>剪映文本切段助手</string><key>CFBundleDisplayName</key><string>剪映文本切段助手</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>2.0.1</string><key>CFBundleVersion</key><string>201</string><key>LSMinimumSystemVersion</key><string>12.0</string><key>NSHighResolutionCapable</key><true/><key>NSPrincipalClass</key><string>NSApplication</string><key>NSHumanReadableCopyright</key><string>剪映文本切段助手 contributors</string>
</dict></plist>
PLIST
# Local ad-hoc signature, not an Apple Developer ID or notarization.
codesign --force --deep --sign - --identifier local.jianying-text-splitter "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "Built: $PWD/$APP ($VERSION)"
