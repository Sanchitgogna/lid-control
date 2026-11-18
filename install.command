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

open "$DEST"
echo
echo "Lid Control is installed. Look for the laptop icon in your menu bar."
echo "Tip: click \"Set up\" in the panel to skip password prompts, then press ⌥⌘L anywhere to switch Keep awake."
echo "     Turn on \"Start at login\" in the panel to launch it automatically."
