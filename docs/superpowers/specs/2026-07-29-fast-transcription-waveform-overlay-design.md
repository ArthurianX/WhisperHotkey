# WhisperHotkey v2 — Instant Transcription, Waveform Overlay, Per-App Submit

**Date:** 2026-07-29
**Status:** Approved design, pending implementation plan

## Goals

1. Eliminate the 2–4 s per-dictation latency caused by reloading the 1.5 GB
   `ggml-large-v3-turbo` model on every hotkey release.
2. Give live visual feedback while dictating: an animated waveform that reacts
   to voice level.
3. Per-app submit key: e.g. Slack needs ⌘↩ to send, not ↩.
4. Harden the countdown's Escape-to-cancel path (grilled 2026-07-29; decisions
   recorded below).

Non-goals: model swap (Parakeet/Moonshine/SpeechAnalyzer), Esc-to-abort while
recording, per-site submit keys inside browsers, streaming transcription.

## 1. Persistent model via `whisper-server`

**Now:** each dictation spawns `whisper-cli`, which loads the model from disk
before transcribing.

**Design:** at app launch, spawn `whisper-server` (already present in
`/Users/arthur/whisper.cpp/build/bin/`) as a managed child process:

```
whisper-server -m models/ggml-large-v3-turbo.bin --host 127.0.0.1 --port 8642
```

Transcription becomes a multipart `POST /inference` (fields: `file` = wav,
`response_format=text`, `language=auto`, `no_timestamps=true`) via
`URLSession`. The model stays resident (~1.5–2 GB RAM while the app runs).

- **Lifecycle:** on startup, kill any stale process bound to the port, then
  spawn fresh. Terminate the child on app exit.
- **Fallback:** if the POST fails for any reason (server crashed, still
  warming up, disabled), run the existing `whisper-cli` path unchanged.
  Dictation must never break because the server is down.
- **Config (`config.json`):**

```json
"server": { "enabled": true, "port": 8642 }
```

## 2. Voice-reactive recording overlay

New `RecordingOverlay` class alongside `CountdownOverlay`, reusing the same
Liquid Glass panel construction and `glass` config (style, corner radius,
tint/fill colors).

- Appears when recording starts; positioned lower-center of the main screen
  (countdown overlay stays centered, unchanged).
- `recorder.isMeteringEnabled = true`; a 30 fps timer calls `updateMeters()`
  and maps `averagePower(forChannel: 0)` (dB) to a 0–1 level.
- ~24 rounded `CALayer` bars render a scrolling history: each tick shifts
  levels left, the newest sample enters at the right; heights animate
  smoothly. "● Recording…" label beneath the bars.
- **Display-only.** No keyboard or mouse interaction. Hotkey release stops
  recording exactly as today. No Esc behavior while recording.

## 3. Flow polish

On hotkey release the waveform overlay switches to a "Transcribing…" state
(bars stop, label changes) instead of posting the `osascript` notification.
It dismisses when the countdown overlay appears (or on error). Full visual
arc: **waveform → transcribing → countdown**. Notifications remain for error
paths only.

## 4. Per-app submit key

`sendReturnKey()` generalizes to `sendSubmitChord(_:)`. When the countdown
completes, look up the frontmost app at **submit time** (submit follows
focus — decided in grilling Q2) via
`NSWorkspace.shared.frontmostApplication?.bundleIdentifier`:

```json
"submitKeys": {
  "default": "enter",
  "com.tinyspeck.slackmacgap": "cmd+enter"
}
```

- Chord parser: tokens `cmd`, `shift`, `opt`/`alt`, `ctrl` + terminal key
  `enter` (extensible later). Maps to `CGEvent` virtual key + flags.
- Unknown apps use `default`; behavior is unchanged until entries are added.
- **Browsers are never mapped** (grilling Q5): Slack-in-Chrome is
  indistinguishable from any other tab, and a browser-wide ⌘↩ would trigger
  submit accelerators in other web apps. Browsers fall through to `default`.
- Countdown title gains a `{key}` placeholder (e.g.
  `"Submitting ({key}) in {seconds}s"` → `Submitting (⌘↩) in 3s`) so the
  pending chord is always visible before deciding whether to cancel.

## 5. Countdown cancel hardening (grilling decisions)

| Decision | Behavior |
|---|---|
| Esc swallow (Q1) | While the countdown panel is visible, a `CGEventTap` intercepts keyCode 53, cancels the countdown, and returns `nil` so the focused app never receives the Esc. Tap exists only for the countdown's lifetime. |
| Focus change (Q2) | No cancellation on focus change. The submit chord fires into, and is chosen for, whatever app is frontmost at expiry. |
| Typing cancels (Q3) | Any character-producing keydown other than Esc during the countdown cancels auto-submit (user has taken over, e.g. to fix a transcription error). Modifier-only presses and mouse clicks elsewhere do not cancel. Pass these keys through unmodified. |
| Hotkey re-press (Q4) | Unchanged: `keyDown()` dismisses the countdown without submitting, enabling chained dictation. Mitigate the expiry race by tuning countdown durations in config, not code. |
| Tap failure (Q6) | If tap creation fails or the tap reports `kCGEventTapDisabledByTimeout`/`ByUserInput`, re-enable it; if unavailable, fall back to the current observe-only global monitor (Esc leaks to the app but cancel still works). Additionally, the countdown panel accepts a direct mouse click as cancel (`ignoresMouseEvents = false`) — a cancel path independent of the keyboard pipeline. Secure-input contexts (password fields) are accepted as blind spots. |

## Error handling

- Server unreachable → silent fallback to `whisper-cli`; log the failover.
- Server child dies mid-session → next dictation falls back; attempt one
  respawn in the background.
- Malformed `submitKeys` chord string → treat as `enter`, log a warning.
- Overlay failures must never block the record→transcribe→paste pipeline.

## Testing

Manual verification via `build.sh` relaunch:

1. Dictate short Romanian and English phrases; confirm transcription returns
   in well under a second after release (server warm).
2. `kill` the `whisper-server` process; confirm next dictation still works
   via CLI fallback and the failover is logged.
3. Waveform overlay appears on record, reacts to voice, morphs to
   "Transcribing…", hands off to countdown.
4. During countdown: Esc cancels and does **not** reach the focused app
   (verify in a TextEdit dialog / Slack thread); typing a letter cancels;
   clicking the overlay cancels; letting it expire in Slack (desktop) sends
   ⌘↩; letting it expire in TextEdit sends ↩.
5. Countdown title shows the pending chord via `{key}`.

## Config example (full new sections)

```json
{
  "server": { "enabled": true, "port": 8642 },
  "submitKeys": {
    "default": "enter",
    "com.tinyspeck.slackmacgap": "cmd+enter"
  },
  "messages": {
    "titleFormat": "Submitting ({key}) in {seconds}s",
    "cancelHint": "press Esc to cancel"
  }
}
```
