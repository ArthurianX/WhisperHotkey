#!/bin/zsh
# Compiles and runs the unit tests. The testable parts of the app — config,
# chords, hotkeys, language planning, warm-up, transcript cleanup, the paste
# decision, the transcription pipeline — are compiled here without the app's
# UI or entry point.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)/whisper-hotkey-tests"

SOURCES=(
  Config.swift
  Clipboard.swift
  FocusGuard.swift
  HotKey.swift
  LanguagePinning.swift
  Logger.swift
  Notifier.swift
  OverlayDebug.swift
  OverlayPanel.swift
  RecordingOverlay.swift
  RuntimePaths.swift
  SubmitChord.swift
  TextInjector.swift
  TranscriptText.swift
  Transcriber.swift
  WarmUp.swift
  WhisperServer.swift
)

swiftc "${SOURCES[@]}" "$DIR/tests/main.swift" -o "$OUT"
"$OUT"
