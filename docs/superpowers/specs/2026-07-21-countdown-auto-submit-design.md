# Countdown & Auto-Submit — Design

**Date:** 2026-07-21
**App:** WhisperHotkey (`WhisperHotkey.swift`, single-file Swift AppKit accessory)

## Summary

After a dictation is transcribed and pasted into the focused field, show a
centered on-screen overlay with a shrinking progress bar and a countdown. When
the countdown reaches zero, send a Return keystroke to the focused field
(auto-submit). Pressing **Esc** during the countdown cancels the submit; the
pasted text remains in place.

This behavior is **always on** — every dictation triggers the countdown.

## Current behavior (context)

`WhisperController` already:
1. Registers a global hotkey (Cmd+Opt+Ctrl+R) with push-to-talk record.
2. On key-up, transcribes the recording with `whisper-cli`.
3. Cleans the transcript, copies it to the clipboard, and pastes it into the
   focused field via a synthetic Cmd+V (`pasteIntoFocusedField()`, `CGEvent`,
   requires Accessibility trust which the app already obtains).

The new feature hooks in **after** the paste step.

## Behavior specification

### Trigger
Always on. After a successful paste of a non-empty transcript, the countdown
overlay appears and the timer starts. There is no separate hotkey or toggle.

### Countdown duration
Computed from the word count of the cleaned transcript:

| Transcript length | Countdown |
|-------------------|-----------|
| ≤ 8 words         | 3 s       |
| 9–25 words        | 4 s       |
| > 25 words        | 5 s       |

Thresholds (8, 25) and the cap (5 s) are simple constants, easy to tune.

### Overlay appearance
Borderless panel centered on the main screen:

```
         Submitting in 3s

     ████████████░░░░░░░░░░

        press Esc to cancel
```

- Top label: `Submitting in Ns` (integer seconds remaining, updates each second).
- Middle: a horizontal bar that empties left-to-right as time elapses.
- Bottom label: `press Esc to cancel`.
- Fades out on completion or cancellation.

### Cancel
Pressing **Esc** at any time during the countdown cancels the auto-submit and
dismisses the overlay. The pasted text stays in the field. No other key cancels.

### Completion
When the countdown reaches zero, send a synthetic Return (keyCode 36) to the
focused field, then dismiss the overlay.

## Components

### `CountdownOverlay`
Owns the overlay UI and timing. Isolated from transcription logic.

- **Window:** a non-activating `NSPanel`
  (`styleMask` includes `.nonactivatingPanel`, `canBecomeKey = false`,
  `level = .floating` or higher, borderless, transparent background). It must
  **never become the key window** — otherwise Esc and the auto-Return would be
  delivered to the overlay instead of the user's target field.
- **Views:** progress bar view + two text labels.
- **Timing:** a repeating `Timer` at ~30–60 Hz for smooth bar depletion. The
  bar and remaining-seconds label are derived from **real elapsed wall-clock
  time** (start time vs. now), not from a tick counter, so total duration stays
  accurate regardless of tick jitter.
- **Esc detection:** a global key event monitor
  (`NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`) since the panel is
  not key. The monitor observes Esc (keyCode 53) and triggers cancel. Note: a
  global monitor does not consume the event, so the focused app also receives
  the Esc — acceptable and harmless in a text field.
- **API:**
  - `show(duration: TimeInterval, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void)`
  - `dismiss()` — invalidates the timer, removes the global monitor, and fades
    out / closes the panel.
- **Teardown:** on both complete and cancel, the timer is invalidated and the
  global monitor is removed. Nothing leaks.

### `WhisperController` changes
- After `pasteIntoFocusedField()` succeeds with a non-empty transcript:
  - Compute duration from word count.
  - Call `overlay.show(duration:onComplete:onCancel:)`.
  - `onComplete` → `sendReturnKey()`.
  - `onCancel` → no-op (text stays).
- Holds a single `CountdownOverlay` instance (or recreates one per use).

### `sendReturnKey()`
A small helper mirroring the existing Cmd+V paste code: post a Return key-down
and key-up via `CGEvent` (virtual keyCode 36) to `.cgSessionEventTap`.

## Edge cases

- **Empty / whitespace-only transcript:** no paste occurs today, so no overlay
  and no countdown. Skip entirely.
- **New dictation starts mid-countdown:** immediately cancel the active overlay
  and its timer before starting the new recording, so no stray Return fires into
  the new dictation.
- **Esc reaches the focused app too:** expected (global monitor is
  non-consuming); harmless in text fields. Documented, not fixed.
- **Multiple monitors:** overlay is centered on the main screen
  (`NSScreen.main`).
- **Timer accuracy:** driven by real elapsed time, capped at the computed
  duration.

## Testing

- Manual: dictate short / medium / long phrases; confirm 3 / 4 / 5 s durations.
- Manual: confirm the auto-Return lands in the focused field (e.g. a browser
  search box or chat input submits).
- Manual: press Esc mid-countdown; confirm no submit and text remains.
- Manual: confirm the overlay does not steal focus (the target field keeps its
  caret; typing still goes to the field during the countdown).
- Manual: start a second dictation during a countdown; confirm the first
  countdown is cancelled and no stray Return fires.

## Out of scope

- Per-invocation or toggle modes for enabling/disabling auto-submit (could be a
  future addition, e.g. a second hotkey).
- Configurable durations via UI/preferences (constants only for now).
- Showing the transcript text inside the overlay (user sees it in the field).
