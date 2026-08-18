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
  <key>CFBundleIconFile</key>              <string>$APP_NAME</string>
  <key>CFBundleIconName</key>              <string>$APP_NAME</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacAmp needs audio input access to route your guitar interface to your speakers.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "[1/4] compiling C (realtime path)"
for c in RingBuffer AudioBridge; do
  $NICE clang -c -O2 -fno-objc-arc \
    -target "$TARGET" -isysroot "$SDK" \
    -o "$OUT/obj/$c.o" "$SRC/$c.c"
done

echo "[2/4] compiling Swift (UI + device layer)"
$NICE swiftc \
  -target "$TARGET" -sdk "$SDK" \
  -parse-as-library -O \
  -import-objc-header "$SRC/Bridging.h" \
  -framework SwiftUI -framework AppKit \
  -framework CoreAudio -framework AudioToolbox -framework AVFoundation \
  "$SRC/App.swift" "$SRC/Devices.swift" \
  "$OUT/obj/RingBuffer.o" "$OUT/obj/AudioBridge.o" \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "[3/4] compiling icon"
# actool ships with full Xcode, not Command Line Tools, so xcrun (which follows
# xcode-select -> CommandLineTools here) will not find it. Fall back explicitly.
ACTOOL="$(xcrun --find actool 2>/dev/null || true)"
[ -x "$ACTOOL" ] || ACTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/actool"

if [ -x "$ACTOOL" ] && [ -d "$HERE/$APP_NAME.icon" ]; then
  # The .icon is passed DIRECTLY -- not wrapped in an .xcassets.
  "$ACTOOL" "$HERE/$APP_NAME.icon" \
    --compile "$APP/Contents/Resources" \
    --app-icon "$APP_NAME" \
    --output-partial-info-plist "$OUT/icon-partial.plist" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --target-device mac \
    --enable-on-demand-resources NO \
    --output-format human-readable-text > "$OUT/actool.log" 2>&1
  echo "  Assets.car + $APP_NAME.icns -> Contents/Resources"
else
  echo "  WARNING: actool not found or $APP_NAME.icon missing; app will have no icon"
fi

echo "[4/4] signing"
cat > "$OUT/entitlements.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key> <true/>
</dict>
</plist>
ENT

# A STABLE signing identity is what stops macOS re-asking for microphone access
# on every rebuild. Ad-hoc signing pins TCC's grant to the binary's cdhash, which
# changes every build, so each rebuild looks like a brand-new app that has never
# been granted anything. Signing with a certificate makes the designated
# requirement identity-based instead, and the grant survives.
#
# The cert is self-signed and local -- no Apple Developer account. It is not
# trusted by Gatekeeper, which does not matter for an app you build yourself;
# notarisation is only needed to hand the app to someone else.
SIGN_ID="MacAmp Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "  signing as: $SIGN_ID"
else
  SIGN_ID="-"
  echo "  WARNING: '$SIGN_ID' identity not found; falling back to ad-hoc."
  echo "           macOS will re-request microphone access after every rebuild."
  echo "           Run ./make-signing-identity.sh to fix."
fi

codesign --force --sign "$SIGN_ID" --options runtime \
  --entitlements "$OUT/entitlements.plist" --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "BUILT: $APP"
