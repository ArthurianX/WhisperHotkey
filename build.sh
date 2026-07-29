#!/bin/zsh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/WhisperHotkey.app"
BIN="$APP/Contents/MacOS/WhisperHotkey"
IDENTITY="WhisperHotkey Local Signing"

swiftc "$DIR"/*.swift -o "$BIN.new"
chmod 755 "$BIN.new"
mv "$BIN.new" "$BIN"

codesign --force --deep --sign "$IDENTITY" "$APP"

pkill -f "WhisperHotkey.app/Contents/MacOS/WhisperHotkey" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/com.arthur.whisper-hotkey" 2>/dev/null \
  || /usr/bin/open -gj "$APP"

echo "Built, signed with '$IDENTITY', and restarted."
