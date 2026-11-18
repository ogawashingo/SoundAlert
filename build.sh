#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP_BUNDLE="SoundAlert.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp Info.plist "$CONTENTS_DIR/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"

SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[ -d "$SDK_PATH" ] || SDK_PATH="$(xcrun --show-sdk-path)"

echo "Compiling SoundAlert for Apple Silicon (arm64)..."
/usr/bin/swiftc \
    -O \
    -sdk "$SDK_PATH" \
    -module-cache-path /tmp/swift-module-cache \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    Sources/Models.swift \
    Sources/AudioFeatureExtractor.swift \
    Sources/DiscordNotifier.swift \
    Sources/AudioMonitorEngine.swift \
    Sources/Views.swift \
    Sources/SoundAlertApp.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework Accelerate \
    -o "$MACOS_DIR/SoundAlert"

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
echo "Build complete: $(pwd)/$APP_BUNDLE"
