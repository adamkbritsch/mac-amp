#!/bin/bash
# Installs MacAmp.app to /Applications.
#
# The lsregister step is not optional. Replacing an app bundle in place leaves
# the old registration behind, and LaunchServices accumulates stale entries --
# `open` will then launch a broken instance that runs with no window at all,
# while running the binary directly still works fine. That failure looks exactly
# like an app bug and is not one.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/MacAmp.app"
DEST=/Applications/MacAmp.app
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$APP" ] || { echo "build it first: ./build.sh"; exit 1; }

for pid in $(pgrep -f "^$DEST/Contents/MacOS/MacAmp" 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
sleep 2

"$LSR" -u "$DEST" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
"$LSR" -f "$DEST" 2>/dev/null || true

echo "installed: $DEST"
