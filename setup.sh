#!/bin/zsh
# One-shot setup for a fresh machine: settings, whisper.cpp, the model, the
# codesigning identity, and the LaunchAgent. Idempotent — every step checks
# whether it is already done. Non-interactive: it never asks questions, it just
# reports what it did and what still needs a human (the two permission grants).
#
#   ./setup.sh              everything
#   ./setup.sh --cert       only create the codesigning identity, if missing
#   ./setup.sh --skip-whisper / --skip-model / --skip-agent
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_URL="$HOME/.config/whisper-hotkey/config.json"
WHISPER_ROOT="${WHISPER_ROOT:-$HOME/whisper.cpp}"
MODEL="${WHISPER_HOTKEY_MODEL:-ggml-large-v3-turbo.bin}"
IDENTITY="${WHISPER_HOTKEY_SIGNING_IDENTITY:-WhisperHotkey Local Signing}"
LABEL="com.arthur.whisper-hotkey"
AGENT_URL="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNTIME_DIR="$HOME/Library/Caches/whisper-hotkey"

skip_whisper=0; skip_model=0; skip_agent=0; cert_only=0
for arg in "$@"; do
  case "$arg" in
    --cert) cert_only=1 ;;
    --skip-whisper) skip_whisper=1 ;;
    --skip-model) skip_model=1 ;;
    --skip-agent) skip_agent=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

say() { print "==> $1" }

# --- Settings ------------------------------------------------------------
if [[ ! -f "$CONFIG_URL" ]]; then
  say "Writing $CONFIG_URL"
  mkdir -p "$(dirname "$CONFIG_URL")"
  if [[ -f "$DIR/config.json.example" ]]; then
    cp "$DIR/config.json.example" "$CONFIG_URL"
  else
    print "  no config.json.example here — the app writes defaults on its first run instead"
  fi
fi
print "  settings: $CONFIG_URL"

# --- Codesigning identity -------------------------------------------------
# A stable identity is what keeps the Accessibility and microphone grants
# attached to the binary across rebuilds; ad-hoc signing resets them every time.
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  print "  signing identity: present"
elif [[ -n "$WHISPER_HOTKEY_NO_CERT" ]]; then
  print "  ! No signing identity '$IDENTITY' (WHISPER_HOTKEY_NO_CERT is set); rebuilds keep losing TCC grants."
else
  say "Creating the self-signed codesigning identity '$IDENTITY'"
  # Keep private signing material out of the checkout and remove it on exit.
  umask 077
  SETUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whisper-hotkey-signing.XXXXXX")"
  trap 'rm -rf -- "$SETUP_DIR"' EXIT
  openssl req -x509 -newkey rsa:2048 -keyout "$SETUP_DIR/key.pem" -out "$SETUP_DIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" \
    -addext "keyUsage = critical, digitalSignature" \
    -addext "extendedKeyUsage = critical, codeSigning" \
    -addext "basicConstraints = critical, CA:false"
  openssl pkcs12 -export -out "$SETUP_DIR/cert.p12" -inkey "$SETUP_DIR/key.pem" -in "$SETUP_DIR/cert.pem" -passout pass:
  security import "$SETUP_DIR/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -T /usr/bin/codesign -P ""
  security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$SETUP_DIR/cert.pem"
  print "  Trusting it is a keychain write — expect a password prompt."
fi
[[ $cert_only -eq 1 ]] && exit 0

# --- whisper.cpp ----------------------------------------------------------
if [[ $skip_whisper -eq 0 ]]; then
  if [[ ! -x "$WHISPER_ROOT/build/bin/whisper-cli" ]]; then
    if [[ ! -d "$WHISPER_ROOT" ]]; then
      say "Cloning whisper.cpp into $WHISPER_ROOT"
      git clone https://github.com/ggml-org/whisper.cpp "$WHISPER_ROOT"
    fi
    if ! command -v cmake >/dev/null; then
      print "  ! cmake is missing. Install it (brew install cmake) and re-run ./setup.sh."
      exit 1
    fi
    say "Building whisper.cpp (Metal is on by default on Apple Silicon)"
    cmake -S "$WHISPER_ROOT" -B "$WHISPER_ROOT/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$WHISPER_ROOT/build" --config Release -j
  else
    print "  whisper-cli: present"
  fi
fi

# --- Model ----------------------------------------------------------------
if [[ $skip_model -eq 0 && ! -f "$WHISPER_ROOT/models/$MODEL" ]]; then
  say "Downloading $MODEL (~1.6 GB)"
  mkdir -p "$WHISPER_ROOT/models"
  curl -L --fail -o "$WHISPER_ROOT/models/$MODEL" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL" \
    || curl -L --fail -o "$WHISPER_ROOT/models/$MODEL" \
    "https://huggingface.co/ggml-org/whisper.cpp/resolve/main/$MODEL"
fi

# --- LaunchAgent ----------------------------------------------------------
if [[ $skip_agent -eq 0 ]]; then
  say "Installing $AGENT_URL"
  mkdir -p "$HOME/Library/LaunchAgents" "$RUNTIME_DIR"
  cat > "$AGENT_URL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <!-- -g only: never add -j. A hidden app cannot order its overlay panels in;
         the app unhides itself at launch without stealing focus. -->
    <string>-g</string>
    <string>$DIR/WhisperHotkey.app</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$RUNTIME_DIR/stdout.log</string>
  <key>StandardErrorPath</key><string>$RUNTIME_DIR/stderr.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_URL"
fi

say "Done."
print "Two grants cannot be scripted and must be done in System Settings:"
print "  · Microphone  — System Settings → Privacy & Security → Microphone"
print "  · Accessibility — System Settings → Privacy & Security → Accessibility (WhisperHotkey)"
print "Then: ./build.sh, and hold ⌃⌥⌘R (or your config's hotkey) to dictate."
