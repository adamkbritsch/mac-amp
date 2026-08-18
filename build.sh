#!/bin/bash
# Builds MacAmp.app using only Command Line Tools -- no Xcode, no xcodebuild.
set -euo pipefail

APP_NAME="MacAmp"
BUNDLE_ID="com.adambritsch.macamp"
VERSION="1.0"
BUILD="1"
MIN_MACOS="13.0"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
OUT="$HERE/build"
APP="$OUT/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos$MIN_MACOS"

# Compiles are niced so they yield to WindowServer; this machine often has a
# video encode running and an unniced parallel build can starve the desktop.
NICE="nice -n 20"

rm -rf "$APP" "$OUT/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>     <string>en</string>
  <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>CFBundleName</key>                  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>           <string>MacAmp</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
  <key>CFBundleVersion</key>               <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>        <string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>NSPrincipalClass</key>              <string>NSApplication</string>
  <key>LSApplicationCategoryType</key>     <string>public.app-category.music</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacAmp needs audio input access to route your guitar interface to your speakers.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "[1/3] compiling C (realtime path)"
for c in RingBuffer AudioBridge; do
  $NICE clang -c -O2 -fno-objc-arc \
    -target "$TARGET" -isysroot "$SDK" \
    -o "$OUT/obj/$c.o" "$SRC/$c.c"
done

echo "[2/3] compiling Swift (UI + device layer)"
$NICE swiftc \
  -target "$TARGET" -sdk "$SDK" \
  -parse-as-library -O \
  -import-objc-header "$SRC/Bridging.h" \
  -framework SwiftUI -framework AppKit \
  -framework CoreAudio -framework AudioToolbox -framework AVFoundation \
  "$SRC/App.swift" "$SRC/Devices.swift" \
  "$OUT/obj/RingBuffer.o" "$OUT/obj/AudioBridge.o" \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "[3/3] signing"
cat > "$OUT/entitlements.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key> <true/>
</dict>
</plist>
ENT

codesign --force --sign - --options runtime \
  --entitlements "$OUT/entitlements.plist" --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "BUILT: $APP"
