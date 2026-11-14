#!/bin/bash
# One-step installer: builds Lid Control, puts it in /Applications and opens it.
set -euo pipefail
cd "$(dirname "$0")"

bash build.sh

DEST="/Applications/Lid Control.app"
pkill -x LidControl 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "Lid Control.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
read -r -p "Start Lid Control automatically when you log in? [y/N] " ans
if [[ "$ans" =~ ^[Yy] ]]; then
  osascript -e 'tell application "System Events"
    if not (exists login item "Lid Control") then make login item at end with properties {path:"/Applications/Lid Control.app", hidden:false}
  end tell' >/dev/null && echo "Added to login items."
fi

open "$DEST"
echo
echo "Lid Control is installed. Look for the laptop icon in your menu bar."
echo "Tip: turn on \"Don't ask for my password\" in the panel, then press ⌥⌘L anywhere to flip the lid setting."
