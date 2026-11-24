#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[ -d "$SDK_PATH" ] || SDK_PATH="$(xcrun --show-sdk-path)"

MODULE_CACHE_DIR="$(pwd)/.build/module-cache"
TEST_BIN="$(pwd)/.build/SoundAlertTests"
mkdir -p "$MODULE_CACHE_DIR"

echo "Compiling SoundAlert unit tests..."
/usr/bin/swiftc \
    -sdk "$SDK_PATH" \
    -module-cache-path "$MODULE_CACHE_DIR" \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    Sources/Models.swift \
    Sources/KeychainHelper.swift \
    Sources/StorageManager.swift \
    Sources/AudioFeatureExtractor.swift \
    Sources/DiscordNotifier.swift \
    Tests/SoundAlertTests.swift \
    -framework Foundation \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework Accelerate \
    -framework Security \
    -o "$TEST_BIN"

echo "Running SoundAlert unit tests..."
"$TEST_BIN"
