#!/bin/bash
# Build /Applications/Victor Net.app from this checkout.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

APP_NAME="Victor Net"
BUNDLE_ID="ro.victorrentea.victor-net"
# APP_DIR=<path> builds somewhere else (tools/release.sh builds into dist/);
# UNIVERSAL=1 builds arm64 + x86_64; CODESIGN_IDENTITY=- signs ad-hoc.
APP_DIR="${APP_DIR:-/Applications/$APP_NAME.app}"
CONTENTS="$APP_DIR/Contents"
BUILD_CONFIG="release"

BUILD_TIMESTAMP=$(date "+%b %-d, %H:%M")
sed -i '' "s/static let time = .*/static let time = \"$BUILD_TIMESTAMP\"/" "$DIR/Sources/VictorNet/BuildInfo.swift"
echo "Build timestamp: $BUILD_TIMESTAMP"

# Tests first: a build that fails them is not deployed.
# SKIP_TESTS=1 forces a build anyway.
if [ "${SKIP_TESTS:-0}" != "1" ]; then
    echo "Running tests..."
    TESTLOG="$(mktemp -t victor-net-tests)"
    if ! swift test > "$TESTLOG" 2>&1; then
        grep -E "error:|failed \(" "$TESTLOG" | head -20
        echo ""
        echo "❌ Tests failed — NOT deploying (full log: $TESTLOG)."
        echo "   Fix them, or force with: SKIP_TESTS=1 ./build-app.sh"
        exit 1
    fi
    grep -E "Executed [0-9]+ tests" "$TESTLOG" | tail -1
    rm -f "$TESTLOG"
fi

if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
else
    ARCHS=()
fi
swift build -c "$BUILD_CONFIG" "${ARCHS[@]}"
# Ask SwiftPM where it put the binary: the Swift Build backend (Swift 6.4) moved it
# to .build/out/Products/Release, and a hardcoded path silently installed a stale one.
BINARY="$(swift build -c "$BUILD_CONFIG" "${ARCHS[@]}" --show-bin-path)/VictorNet"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Victor Net opens a Bluetooth channel to your phone to ask it for its hotspot when this Mac has no internet, and how much roaming data is left.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>macOS shows the Wi-Fi network's name only to apps with Location access; Victor Net also uses it to know when you are at home or abroad.</string>
</dict>
</plist>
PLIST

# A stable identity when there is one (export CODESIGN_IDENTITY=…); ad-hoc
# otherwise. With ad-hoc signing every rebuild is a new app to macOS, and the
# Bluetooth and Location grants have to be given again.
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    for CANDIDATE in "Victor Addons Local Code Signing"; do
        if security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" | grep -Fq "$CANDIDATE"; then
            SIGNING_IDENTITY="$CANDIDATE"
            break
        fi
    done
fi
codesign --force --sign "${SIGNING_IDENTITY:--}" "$APP_DIR"

echo "✅ Installed $APP_DIR"
echo "   Restart it with: pkill -f \"$APP_NAME\"; open \"$APP_DIR\""
