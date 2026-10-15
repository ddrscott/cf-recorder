#!/bin/sh
# Builds build/Recorder.app from the Swift package and signs it.
# Signing with a real identity keeps macOS from re-asking for mic and audio
# permissions on every rebuild. Override with CODESIGN_IDENTITY=- for ad-hoc.
set -eu
cd "$(dirname "$0")/.."

config="${CONFIG:-release}"
swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/CFRecorder"

app="build/Recorder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/CFRecorder"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity="${CODESIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/CFRecorder.entitlements \
  --sign "${identity:--}" "$app"

echo "$app"
