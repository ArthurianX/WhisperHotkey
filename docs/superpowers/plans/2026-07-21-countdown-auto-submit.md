# Countdown & Auto-Submit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a transcript is pasted into the focused field, show a centered countdown overlay and auto-press Return when it ends, cancellable with Esc.

**Architecture:** Add a self-contained `CountdownOverlay` class (non-activating `NSPanel` + `Timer` + global Esc monitor) to `WhisperHotkey.swift`. Hook it into `WhisperController` after the existing paste, add a `sendReturnKey()` helper and a word-count → duration function, and cancel any live overlay when a new dictation starts.

**Tech Stack:** Swift, AppKit (`NSPanel`, `NSView`, `NSTextField`, `Timer`, `NSEvent` global monitor), CoreGraphics (`CGEvent`). Single-file app, built via `./build.sh` (`swiftc`).

## Global Constraints

- Single source file: `WhisperHotkey.swift`. No new files, no package manager.
- Overlay must **never become the key window** (`.nonactivatingPanel`, no key focus) — otherwise Esc/Return go to the overlay, not the user's field.
- Esc = keyCode 53; Return = keyCode 36; existing Cmd+V uses keyCode 9.
- Durations: ≤8 words → 3s, 9–25 → 4s, >25 → 5s.
- Always-on: every non-empty pasted transcript triggers the countdown.
- Build/verify with `./build.sh` (compiles, signs, restarts the app).

---

### Task 1: `CountdownOverlay` class

**Files:**
- Modify: `WhisperHotkey.swift` (insert new class before `let controller = WhisperController()` at line 245).

**Interfaces:**
- Produces:
  - `final class CountdownOverlay`
  - `func show(duration: TimeInterval, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void)`
  - `func dismiss()` — silent teardown, fires no callbacks.

- [ ] **Step 1: Add the class.** Insert immediately before line 245 (`let controller = ...`):

```swift
final class CountdownOverlay {
    private var panel: NSPanel?
    private var timer: Timer?
    private var monitor: Any?
    private var startTime: Date?
    private var duration: TimeInterval = 0
    private var onComplete: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var titleLabel: NSTextField?
    private var track: NSView?
    private var fill: NSView?

    func show(duration: TimeInterval, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        self.duration = duration
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.startTime = Date()

        let width: CGFloat = 360, height: CGFloat = 120
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.82).cgColor
        content.layer?.cornerRadius = 16
        panel.contentView = content

        let title = NSTextField(labelWithString: "Submitting in \(Int(ceil(duration)))s")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.frame = NSRect(x: 0, y: height - 46, width: width, height: 24)
        content.addSubview(title)

        let barMargin: CGFloat = 30
        let barWidth = width - barMargin * 2
        let trackView = NSView(frame: NSRect(x: barMargin, y: 52, width: barWidth, height: 14))
        trackView.wantsLayer = true
        trackView.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        trackView.layer?.cornerRadius = 7
        content.addSubview(trackView)

        let fillView = NSView(frame: NSRect(x: 0, y: 0, width: barWidth, height: 14))
        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor.white.cgColor
        fillView.layer?.cornerRadius = 7
        trackView.addSubview(fillView)

        let hint = NSTextField(labelWithString: "press Esc to cancel")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = NSColor(white: 1.0, alpha: 0.6)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 20, width: width, height: 16)
        content.addSubview(hint)

        if let screen = NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
        }

        self.panel = panel
        self.titleLabel = title
        self.track = trackView
        self.fill = fillView
        panel.orderFrontRegardless()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let startTime, duration > 0 else { return }
        let remaining = max(0, duration - Date().timeIntervalSince(startTime))
        let fraction = CGFloat(max(0, min(1, remaining / duration)))
        if let track, let fill { fill.frame.size.width = track.bounds.width * fraction }
        titleLabel?.stringValue = "Submitting in \(Int(ceil(remaining)))s"
        if remaining <= 0 { complete() }
    }

    private func complete() { let cb = onComplete; teardown(); cb?() }
    private func cancel() { let cb = onCancel; teardown(); cb?() }
    func dismiss() { teardown() }

    private func teardown() {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil); panel = nil
        startTime = nil; onComplete = nil; onCancel = nil
        titleLabel = nil; track = nil; fill = nil
    }
}
```

- [ ] **Step 2: Compile.** Run: `./build.sh` — Expected: "Built, signed ... and restarted." with no `swiftc` errors. (Class is unused so far; that's fine.)

- [ ] **Step 3: Commit.**

```bash
git add WhisperHotkey.swift
git commit -m "feat: add CountdownOverlay panel class"
```

---

### Task 2: Wire countdown + auto-submit into the transcription flow

**Files:**
- Modify: `WhisperHotkey.swift` — `WhisperController` (add stored `overlay`, three methods; edit `keyDown` and the paste block).

**Interfaces:**
- Consumes: `CountdownOverlay.show(...)`, `CountdownOverlay.dismiss()` from Task 1.
- Produces: `sendReturnKey()`, `countdownDuration(for:)`, `startCountdown(for:)` (all private on `WhisperController`).

- [ ] **Step 1: Add the overlay property.** After `private var transcribing = false` (line 15), add:

```swift
    private let overlay = CountdownOverlay()
```

- [ ] **Step 2: Cancel any live countdown on a new dictation.** Make `keyDown()` (line 41) start with `overlay.dismiss()`:

```swift
    func keyDown() {
        overlay.dismiss()
        if transcribing {
            notify(title: "Whisper", body: "Already transcribing.")
            return
        }
        guard recorder == nil else { return }
        requestAndStartRecording()
    }
```

- [ ] **Step 3: Add the three helpers.** Insert after `pasteIntoFocusedField()` (after line 204):

```swift
    private func countdownDuration(for text: String) -> TimeInterval {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        switch words {
        case ...8: return 3
        case 9...25: return 4
        default: return 5
        }
    }

    private func startCountdown(for text: String) {
        guard !text.isEmpty else { return }
        overlay.show(duration: countdownDuration(for: text), onComplete: { [weak self] in
            self?.sendReturnKey()
            self?.log("Auto-submitted transcript.")
        }, onCancel: { [weak self] in
            self?.log("Auto-submit cancelled by user.")
        })
    }

    private func sendReturnKey() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 36
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
```

- [ ] **Step 4: Trigger it after a successful paste.** In the paste block (lines 180-186), add `startCountdown` on the success branch:

```swift
                if self.pasteIntoFocusedField() {
                    self.notify(title: "Whisper", body: "Transcript pasted.")
                    self.log("Transcript copied to clipboard and auto-pasted.")
                    self.startCountdown(for: cleaned)
                } else {
```

- [ ] **Step 5: Compile.** Run: `./build.sh` — Expected: builds and restarts with no errors.

- [ ] **Step 6: Manual verification** (per spec testing section):
  - Dictate a short (≤8 words), medium (9–25), long (>25) phrase into a chat/search box → overlay shows 3 / 4 / 5s and bar depletes.
  - Let it reach zero → the field submits (Return lands in the target field).
  - Press Esc mid-countdown → no submit, text stays, overlay disappears.
  - During the countdown, confirm the target field keeps focus (caret still there; overlay didn't steal it).
  - Start a new dictation while a countdown is running → old overlay vanishes, no stray Return.

- [ ] **Step 7: Commit.**

```bash
git add WhisperHotkey.swift
git commit -m "feat: countdown overlay + auto-submit after paste"
```

---

## Self-Review

- **Spec coverage:** always-on trigger (T2 S4), duration tiers (T2 S3 `countdownDuration`), overlay appearance/shrinking bar (T1), Esc cancel via global monitor (T1), non-activating panel (T1), auto-Return keyCode 36 (T2 `sendReturnKey`), empty-transcript skip (T2 `startCountdown` guard + only on paste-success branch), cancel-on-new-dictation (T2 S2), real-elapsed-time timing (T1 `tick`), main-screen centering (T1), teardown of timer+monitor (T1 `teardown`). All covered.
- **Placeholder scan:** none — all code is concrete.
- **Type consistency:** `show`/`dismiss`/`teardown`/`tick`/`complete`/`cancel` and `startCountdown`/`sendReturnKey`/`countdownDuration` names match across tasks. Return keyCode 36, Esc 53 consistent.
