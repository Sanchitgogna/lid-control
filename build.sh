#!/bin/bash
# Builds "Lid Control.app" and "Lid Control.dmg" next to this script.
# Needs Xcode Command Line Tools (xcode-select --install).
# UNIVERSAL=1 bash build.sh  -> one app that runs on both Apple Silicon and Intel Macs.
set -euo pipefail
cd "$(dirname "$0")"

APP="Lid Control.app"
BIN="$APP/Contents/MacOS/LidControl"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() { swiftc -O -parse-as-library -target "$1-apple-macos13.0" Sources/*.swift -o "$2"; }

echo "Compiling…"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  TMP="$(mktemp -d)"
  compile arm64  "$TMP/arm64"
  compile x86_64 "$TMP/x86_64"
  lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
  rm -rf "$TMP"
else
  compile "$(uname -m)" "$BIN"
fi

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"

# Disk image for sharing: the app plus an Applications shortcut to drag it onto.
echo "Making disk image…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "Lid Control.dmg"
hdiutil create -quiet -volname "Lid Control" -srcfolder "$STAGE" -ov -format UDZO "Lid Control.dmg"
rm -rf "$STAGE"

echo "Built: $(pwd)/$APP"
echo "       $(pwd)/Lid Control.dmg"
