#!/bin/sh
# Builds MicMute.app into this directory.
set -e
cd "$(dirname "$0")"

APP=MicMute.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework Combine \
    -framework CoreAudio -framework AVFoundation -framework ServiceManagement \
    -framework Carbon \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/MicMute"

codesign --force --sign - --identifier local.micmute "$APP" 2>/dev/null || true
echo "built $(pwd)/$APP"
