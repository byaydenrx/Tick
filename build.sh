#!/bin/zsh
# Builds Tick.app into ./build (signed ad hoc for local use).
set -e
cd "$(dirname "$0")"
ARCHS=(--arch arm64 --arch x86_64)  # universal: Apple silicon and Intel
swift build -c release $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)
APP=build/Tick.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Tick" "$APP/Contents/MacOS/Tick"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
