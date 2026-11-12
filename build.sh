#!/bin/zsh
# Builds the app bundle, signs it with a stable identity, and restarts it.
# Tests run first: a build that ships a red test is not a build.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/WhisperHotkey.app"
BIN="$APP/Contents/MacOS/WhisperHotkey"
IDENTITY="${WHISPER_HOTKEY_SIGNING_IDENTITY:-WhisperHotkey Local Signing}"

"$DIR/test.sh"

mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

swiftc -O "$DIR"/*.swift -o "$BIN.new"
chmod 755 "$BIN.new"
mv "$BIN.new" "$BIN"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  cat >&2 <<EOF
No codesigning identity named "$IDENTITY".

A stable identity is what keeps the Accessibility and microphone grants
attached to this binary across rebuilds; ad-hoc signing ("-") works but resets
them every build. See README.md ("Signing") for creating the self-signed cert.
Set WHISPER_HOTKEY_SIGNING_IDENTITY to use a different one.
EOF
  exit 1
fi

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

pkill -f "WhisperHotkey.app/Contents/MacOS/WhisperHotkey" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/com.arthur.whisper-hotkey" 2>/dev/null \
  || /usr/bin/open -g "$APP"

echo "Built, signed with '$IDENTITY', and restarted."
