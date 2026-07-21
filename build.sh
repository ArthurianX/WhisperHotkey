#!/bin/zsh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/WhisperHotkey.app"
BIN="$APP/Contents/MacOS/WhisperHotkey"
IDENTITY="WhisperHotkey Local Signing"

swiftc "$DIR/WhisperHotkey.swift" -o "$BIN.new"
chmod 755 "$BIN.new"
mv "$BIN.new" "$BIN"

codesign --force --deep --sign "$IDENTITY" "$APP"

launchctl kickstart -k "gui/$(id -u)/com.arthur.whisper-hotkey" 2>/dev/null \
  || /usr/bin/open -gj "$APP"

echo "Built, signed with '$IDENTITY', and restarted."
