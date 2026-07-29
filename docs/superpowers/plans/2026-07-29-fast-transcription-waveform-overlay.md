# WhisperHotkey v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Instant transcription via a resident `whisper-server`, a voice-reactive waveform overlay while recording, per-app submit key chords, and a hardened Escape-to-cancel path for the countdown.

**Architecture:** The app stays a swiftc-compiled AppKit accessory app, split from one file into a handful of focused files (`main.swift` + one file per component). `whisper-server` runs as a managed child process; transcription becomes a multipart HTTP POST with the existing `whisper-cli` path as fallback. Two overlay classes share a glass-panel factory. Pure logic (chord parsing, config) is unit-tested via a tiny swiftc-compiled test binary; UI/event-tap behavior is verified manually per task.

**Tech Stack:** Swift (AppKit, AVFoundation, Carbon hotkeys, CoreGraphics event taps), whisper.cpp (`whisper-server`/`whisper-cli` at `/Users/arthur/whisper.cpp`), zsh `build.sh` (swiftc + codesign + relaunch).

**Spec:** `docs/superpowers/specs/2026-07-29-fast-transcription-waveform-overlay-design.md`

## Global Constraints

- No external dependencies, no SwiftPM: `build.sh` compiles `"$DIR"/*.swift` with swiftc into a single binary, codesigns with identity `WhisperHotkey Local Signing`, and relaunches.
- Top-level bootstrap code must live in `main.swift` (swiftc multi-file rule).
- macOS 26 (`NSGlassEffectView` behind `#available(macOS 26.0, *)` with dark-panel fallback) — preserve this pattern in all overlay code.
- Model/language: `ggml-large-v3-turbo.bin`, language `auto` (user dictates Romanian AND English). Never hardcode a language.
- Config keys are exactly as specced: `server.enabled`, `server.port` (default `8642`), `submitKeys` (map of bundle-id → chord string, `"default"` key), `{key}` placeholder in `messages.titleFormat`.
- Countdown decisions (from grilling, recorded in spec §5): Esc swallowed via CGEventTap; submit follows focus (no cancel on focus change); any other keydown cancels and passes through; hotkey re-press dismisses silently (unchanged); tap failure falls back to observe-only global monitor; click on countdown panel cancels. RecordingOverlay is display-only (no interaction).
- Overlay failures must never block the record→transcribe→paste pipeline.
- Unit tests: `swiftc SubmitChord.swift Config.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests` (from repo root). Manual app verification: `./build.sh` then dictate with the hotkey (⌘⌥⌃R, hold to talk).
- Logs: app log at `$TMPDIR/whisper-hotkey/whisper-hotkey.log`, server log at `$TMPDIR/whisper-hotkey/whisper-server.log`.

---

### Task 1: Commit pending work; split the single file into focused files

**Files:**
- Modify: `build.sh` (compile line only)
- Create: `Config.swift` (moved code, no behavior change)
- Rename: `WhisperHotkey.swift` → `main.swift`

**Interfaces:**
- Produces: multi-file build (`swiftc "$DIR"/*.swift`); `Config.swift` containing `extension NSColor { init?(hex:) }` and `struct OverlayConfig` exactly as today; `main.swift` containing everything else unchanged.

- [ ] **Step 1: Commit the pre-existing uncommitted debug logging**

The working tree has ~28 uncommitted lines of overlay-visibility debug logging (part of an ongoing countdown-overlay bug investigation — keep them, commit them first so the refactor starts clean):

```bash
git add WhisperHotkey.swift && git commit -m "debug: add overlay visibility diagnostics"
```

- [ ] **Step 2: Rename to main.swift and split out Config.swift**

```bash
git mv WhisperHotkey.swift main.swift
```

Then cut the `extension NSColor { ... }` block (the `init?(hex:)` initializer) and the entire `struct OverlayConfig { ... }` (from `struct OverlayConfig` through its closing brace, including `load()` and `writeDefaultIfMissing()`) out of `main.swift` and paste them into a new `Config.swift` that starts with:

```swift
import AppKit
```

`main.swift` keeps all its other imports and content unchanged.

- [ ] **Step 3: Update build.sh to compile all root Swift files**

In `build.sh` change:

```sh
swiftc "$DIR/WhisperHotkey.swift" -o "$BIN.new"
```

to:

```sh
swiftc "$DIR"/*.swift -o "$BIN.new"
```

(The glob does not descend into `tests/`, which is created in Task 2.)

- [ ] **Step 4: Verify build and runtime behavior unchanged**

Run: `./build.sh`
Expected: "Built, signed ... and restarted." Then hold ⌘⌥⌃R, say a short phrase, release: transcript pastes and the countdown overlay appears, exactly as before.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "refactor: split OverlayConfig into Config.swift, multi-file build"
```

---

### Task 2: SubmitChord parser (TDD)

**Files:**
- Create: `SubmitChord.swift`
- Create: `tests/main.swift`

**Interfaces:**
- Produces: `struct SubmitChord: Equatable { let keyCode: CGKeyCode; let flags: CGEventFlags; let display: String }`, `SubmitChord.enter` (Return key, no modifiers, display `"↩"`), `SubmitChord.parse(_ raw: String) -> SubmitChord?`. Task 3's `OverlayConfig.submitChord(forBundleID:)` and Task 5's `sendChord(_:)` consume these.

- [ ] **Step 1: Write the failing tests**

Create `tests/main.swift`:

```swift
import CoreGraphics
import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition { print("PASS \(label)") } else { print("FAIL \(label)"); failures += 1 }
}

// --- SubmitChord.parse ---
expect(SubmitChord.parse("enter") == SubmitChord(keyCode: 36, flags: [], display: "↩"), "plain enter")
expect(SubmitChord.parse("return")?.keyCode == 36, "return alias")
expect(SubmitChord.parse("cmd+enter") == SubmitChord(keyCode: 36, flags: .maskCommand, display: "⌘↩"), "cmd+enter")
expect(SubmitChord.parse("CMD+Enter")?.display == "⌘↩", "case-insensitive")
expect(SubmitChord.parse(" shift + enter ")?.display == "⇧↩", "whitespace tolerated")
expect(SubmitChord.parse("ctrl+opt+shift+cmd+enter")?.display == "⌃⌥⇧⌘↩", "all modifiers, canonical order")
expect(SubmitChord.parse("alt+enter")?.flags == .maskAlternate, "alt alias for opt")
expect(SubmitChord.parse("cmd+f5") == nil, "unknown key rejected")
expect(SubmitChord.parse("bogus") == nil, "garbage rejected")
expect(SubmitChord.parse("") == nil, "empty rejected")
expect(SubmitChord.parse("cmd+") == nil, "trailing plus rejected")
expect(SubmitChord.enter == SubmitChord(keyCode: 36, flags: [], display: "↩"), "enter constant")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL TESTS PASSED")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swiftc SubmitChord.swift Config.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: FAIL — swiftc error, `SubmitChord.swift` does not exist / `cannot find 'SubmitChord' in scope`.

- [ ] **Step 3: Implement SubmitChord.swift**

```swift
import CoreGraphics

/// A parsed submit key chord, e.g. "cmd+enter" → ⌘↩.
struct SubmitChord: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let display: String

    static let enter = SubmitChord(keyCode: 36, flags: [], display: "↩")

    /// Parses strings like "enter", "cmd+enter", "ctrl+opt+enter".
    /// Modifiers: cmd/command, shift, opt/alt/option, ctrl/control.
    /// Keys: enter/return. Returns nil for anything unrecognized.
    static func parse(_ raw: String) -> SubmitChord? {
        let tokens = raw.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyToken = tokens.last, !keyToken.isEmpty else { return nil }

        let keyCode: CGKeyCode
        let keySymbol: String
        switch keyToken {
        case "enter", "return": keyCode = 36; keySymbol = "↩"
        default: return nil
        }

        var flags: CGEventFlags = []
        for token in tokens.dropLast() {
            switch token {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: return nil
            }
        }

        var symbols = ""
        if flags.contains(.maskControl) { symbols += "⌃" }
        if flags.contains(.maskAlternate) { symbols += "⌥" }
        if flags.contains(.maskShift) { symbols += "⇧" }
        if flags.contains(.maskCommand) { symbols += "⌘" }
        return SubmitChord(keyCode: keyCode, flags: flags, display: symbols + keySymbol)
    }
}
```

Note: `omittingEmptySubsequences: false` is what makes `"cmd+"` produce an empty last token and get rejected.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swiftc SubmitChord.swift Config.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: `ALL TESTS PASSED`

- [ ] **Step 5: Verify the app still builds**

Run: `./build.sh`
Expected: success (SubmitChord.swift joins the app compile; nothing references it yet).

- [ ] **Step 6: Commit**

```bash
git add SubmitChord.swift tests/main.swift && git commit -m "feat: submit key chord parser with unit tests"
```

---

### Task 3: Config extensions — server, submitKeys, {key} placeholder

**Files:**
- Modify: `Config.swift`
- Modify: `tests/main.swift` (append tests)
- Modify: `config.json` (the user's live config, tracked in git)

**Interfaces:**
- Consumes: `SubmitChord.parse(_:)`, `SubmitChord.enter` (Task 2).
- Produces: on `OverlayConfig` — `var serverEnabled: Bool` (default `true`), `var serverPort: Int` (default `8642`), `var submitKeys: [String: String]` (default `["default": "enter"]`), `func submitChord(forBundleID: String?) -> SubmitChord`, `func title(seconds: Int, keyDisplay: String = "↩") -> String` (replaces both `{seconds}` and `{key}`), `static func load(from url: URL = OverlayConfig.path) -> OverlayConfig`.

- [ ] **Step 1: Append failing tests to tests/main.swift**

Insert before the final `if failures > 0` block:

(`import Foundation` is already at the top of the file from Task 2.)

```swift
// --- OverlayConfig ---
let tmpConfig = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-config.json")
try! """
{
  "server": { "enabled": false, "port": 9999 },
  "submitKeys": { "default": "enter", "com.tinyspeck.slackmacgap": "cmd+enter", "com.broken.app": "cmd+f13" },
  "messages": { "titleFormat": "Submitting ({key}) in {seconds}s" }
}
""".write(to: tmpConfig, atomically: true, encoding: .utf8)

let cfg = OverlayConfig.load(from: tmpConfig)
expect(cfg.serverEnabled == false, "server.enabled parsed")
expect(cfg.serverPort == 9999, "server.port parsed")
expect(cfg.submitChord(forBundleID: "com.tinyspeck.slackmacgap").display == "⌘↩", "slack chord")
expect(cfg.submitChord(forBundleID: "org.mozilla.firefox") == .enter, "unmapped app falls back to default")
expect(cfg.submitChord(forBundleID: nil) == .enter, "nil bundle id falls back to default")
expect(cfg.submitChord(forBundleID: "com.broken.app") == .enter, "malformed chord falls back to enter")
expect(cfg.title(seconds: 3, keyDisplay: "⌘↩") == "Submitting (⌘↩) in 3s", "{key} and {seconds} replaced")

let defaults = OverlayConfig.load(from: URL(fileURLWithPath: "/nonexistent.json"))
expect(defaults.serverEnabled == true, "default server.enabled true")
expect(defaults.serverPort == 8642, "default server.port 8642")
expect(defaults.submitChord(forBundleID: "anything") == .enter, "default submit is enter")
expect(defaults.title(seconds: 5) == "Submitting in 5s", "default titleFormat has no {key}")
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `swiftc SubmitChord.swift Config.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: FAIL — swiftc errors: `OverlayConfig` has no member `load(from:)` / `serverEnabled` / `submitChord`.

- [ ] **Step 3: Implement in Config.swift**

Add the new stored properties to `OverlayConfig` (next to the existing defaults):

```swift
    // whisper-server (resident model)
    var serverEnabled = true
    var serverPort = 8642
    // bundle-id → chord string; "default" applies to unmapped apps
    var submitKeys: [String: String] = ["default": "enter"]
```

Replace the existing `func title(seconds:)` with:

```swift
    func title(seconds: Int, keyDisplay: String = "↩") -> String {
        titleFormat
            .replacingOccurrences(of: "{seconds}", with: "\(seconds)")
            .replacingOccurrences(of: "{key}", with: keyDisplay)
    }
```

Add:

```swift
    func submitChord(forBundleID id: String?) -> SubmitChord {
        let raw = id.flatMap { submitKeys[$0] } ?? submitKeys["default"] ?? "enter"
        return SubmitChord.parse(raw) ?? .enter
    }
```

Change `static func load() -> OverlayConfig` to `static func load(from url: URL = OverlayConfig.path) -> OverlayConfig` (and its `Data(contentsOf: path)` to `Data(contentsOf: url)`), then add inside it, after the `"glass"` block:

```swift
        if let s = json["server"] as? [String: Any] {
            if let v = s["enabled"] as? Bool { config.serverEnabled = v }
            if let v = s["port"] as? Int { config.serverPort = v }
        }
        if let k = json["submitKeys"] as? [String: String], !k.isEmpty {
            config.submitKeys = k
        }
```

In `writeDefaultIfMissing()`, add matching sections to the JSON template string (after the `"glass"` object, comma-separated):

```json
  "server": { "enabled": true, "port": 8642 },
  "submitKeys": { "default": "enter" }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swiftc SubmitChord.swift Config.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: `ALL TESTS PASSED`

- [ ] **Step 5: Fix the one call site of title(seconds:)**

In `main.swift`, `CountdownOverlay` calls `config.title(seconds:)` twice (title label creation in `show()` and in `tick()`). The default `keyDisplay: "↩"` keeps them compiling unchanged — just verify with `./build.sh` that the app builds and runs.

- [ ] **Step 6: Update the live config.json**

Add to `/Users/arthur/whisper-hotkey/config.json` (top-level keys alongside `countdown`/`messages`/`glass`):

```json
  "server": { "enabled": true, "port": 8642 },
  "submitKeys": {
    "default": "enter",
    "com.tinyspeck.slackmacgap": "cmd+enter"
  }
```

and change `messages.titleFormat` to `"Submitting ({key}) in {seconds}s"`.

- [ ] **Step 7: Commit**

```bash
git add Config.swift tests/main.swift config.json && git commit -m "feat: config for whisper-server, per-app submit keys, {key} placeholder"
```

---

### Task 4: Resident whisper-server with CLI fallback

**Files:**
- Create: `WhisperServer.swift`
- Modify: `main.swift` — `WhisperController` (`transcribe()` restructured; server property; `shutdown()`) and bootstrap (start server, SIGTERM handler)

**Interfaces:**
- Consumes: `OverlayConfig.serverEnabled` / `.serverPort` (Task 3).
- Produces: `final class WhisperServer { init(whisperRoot: URL, modelFile: URL, port: Int, logFile: URL, log: @escaping (String) -> Void); func start(); func stop(); func respawnIfNeeded(); func transcribe(wav: URL) -> String? }`; on `WhisperController`: `func startServerIfEnabled()`, `func shutdown()`, `private func runTranscription() -> String?`, `private func runWhisperCLI() -> String?`.

- [ ] **Step 1: Confirm whisper-server flags (execution-time check)**

Run: `/Users/arthur/whisper.cpp/build/bin/whisper-server --help 2>&1 | head -40`
Expected: usage listing including `--host`, `--port`, `-l/--language`. Note whether `-nt/--no-timestamps` is listed; if not, rely solely on `response_format=text` (which returns plain text) and drop `-nt` from the args below.

- [ ] **Step 2: Implement WhisperServer.swift**

```swift
import Foundation

/// Manages a resident whisper-server child process and talks to it over HTTP.
final class WhisperServer {
    private let whisperRoot: URL
    private let modelFile: URL
    private let port: Int
    private let logFile: URL
    private let log: (String) -> Void
    private var process: Process?

    init(whisperRoot: URL, modelFile: URL, port: Int, logFile: URL, log: @escaping (String) -> Void) {
        self.whisperRoot = whisperRoot
        self.modelFile = modelFile
        self.port = port
        self.logFile = logFile
        self.log = log
    }

    func start() {
        killStale()
        let p = Process()
        p.currentDirectoryURL = whisperRoot
        p.executableURL = whisperRoot.appendingPathComponent("build/bin/whisper-server")
        p.arguments = [
            "-m", modelFile.path,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "-l", "auto"
        ]
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logFile)
        p.standardOutput = handle
        p.standardError = handle
        do {
            try p.run()
            process = p
            log("whisper-server started (pid \(p.processIdentifier), port \(port)).")
        } catch {
            log("Failed to launch whisper-server: \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// Safe to call from any queue; process management happens on main.
    func respawnIfNeeded() {
        DispatchQueue.main.async {
            if self.process?.isRunning != true {
                self.log("whisper-server not running; respawning.")
                self.start()
            }
        }
    }

    /// Kills whatever holds our port (a stale server from a previous app run).
    private func killStale() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "lsof -ti tcp:\(port) | xargs kill 2>/dev/null"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Synchronous multipart POST to /inference. Call from a background queue.
    /// Returns nil on any failure (caller falls back to whisper-cli).
    func transcribe(wav: URL) -> String? {
        guard let audio = try? Data(contentsOf: wav),
              let url = URL(string: "http://127.0.0.1:\(port)/inference") else { return nil }

        let boundary = "whisper-hotkey-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        appendField("response_format", "text")
        appendField("temperature", "0.0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { self.log("whisper-server request failed: \(error.localizedDescription)"); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                  let text = String(data: data, encoding: .utf8) else {
                self.log("whisper-server bad response: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            result = text
        }.resume()
        semaphore.wait()
        return result
    }
}
```

- [ ] **Step 3: Wire into WhisperController**

In `main.swift`, add to `WhisperController`'s properties:

```swift
    private var server: WhisperServer?

    private var serverLogFile: URL {
        runtimeDir.appendingPathComponent("whisper-server.log")
    }
```

Add these methods:

```swift
    func startServerIfEnabled() {
        let config = OverlayConfig.load()
        guard config.serverEnabled else {
            log("whisper-server disabled in config; using whisper-cli.")
            return
        }
        let server = WhisperServer(
            whisperRoot: whisperRoot,
            modelFile: modelFile,
            port: config.serverPort,
            logFile: serverLogFile,
            log: { [weak self] in self?.log($0) }
        )
        self.server = server
        server.start()
    }

    func shutdown() {
        server?.stop()
    }
```

Restructure `transcribe()`: replace everything between the `guard FileManager.default.fileExists(atPath: self.wavFile.path)` block and the `let cleaned = transcript...` line with a call to the new helpers, so the body of the background block reads:

```swift
            guard FileManager.default.fileExists(atPath: self.wavFile.path) else {
                DispatchQueue.main.async {
                    self.notify(title: "Whisper", body: "No recording found.")
                }
                self.log("No recording found.")
                return
            }

            guard let transcript = self.runTranscription() else {
                DispatchQueue.main.async {
                    self.notify(title: "Whisper", body: "Transcription failed. See /tmp/whisper-hotkey.")
                }
                return
            }

            let cleaned = transcript
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            // ... existing DispatchQueue.main.async paste block unchanged
```

Add the two helpers to `WhisperController` (the CLI helper is the existing Process code, relocated verbatim):

```swift
    /// Background queue only. Tries the resident server, falls back to whisper-cli.
    private func runTranscription() -> String? {
        let config = OverlayConfig.load()
        if config.serverEnabled, let server {
            let started = Date()
            if let text = server.transcribe(wav: wavFile) {
                log(String(format: "whisper-server transcribed in %.2fs.", Date().timeIntervalSince(started)))
                return text
            }
            log("whisper-server unavailable; falling back to whisper-cli.")
            server.respawnIfNeeded()
        }
        return runWhisperCLI()
    }

    /// Background queue only. The original CLI path.
    private func runWhisperCLI() -> String? {
        try? FileManager.default.removeItem(at: transcriptFile)

        let process = Process()
        process.currentDirectoryURL = whisperRoot
        process.executableURL = whisperBin
        process.arguments = [
            "-m", modelFile.path,
            "-f", wavFile.path,
            "-otxt",
            "-of", transcriptBase.path,
            "-nt",
            "-np",
            "-l", "auto"
        ]

        let logHandle = openLogHandle()
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Failed to launch whisper-cli: \(error)")
            return nil
        }

        guard process.terminationStatus == 0,
              let transcript = try? String(contentsOf: transcriptFile, encoding: .utf8)
        else {
            log("Transcription failed with status \(process.terminationStatus).")
            return nil
        }
        return transcript
    }
```

Delete the old inline Process code from `transcribe()` (now living in `runWhisperCLI()`).

- [ ] **Step 4: Bootstrap — start server, clean shutdown**

In `main.swift` top-level code, after `let controller = WhisperController()` add:

```swift
controller.startServerIfEnabled()

// build.sh relaunches us with pkill (SIGTERM): take the child server down with us.
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    controller.shutdown()
    exit(0)
}
sigtermSource.resume()
```

- [ ] **Step 5: Build and verify fast path**

Run: `./build.sh`, wait ~15s for the model to load (watch `$TMPDIR/whisper-hotkey/whisper-server.log`), then dictate a short phrase.
Expected: transcript pastes noticeably faster than before; app log shows `whisper-server transcribed in X.XXs` with X well under 1s for a short phrase. Dictate one Romanian and one English phrase; both transcribe correctly (language auto-detect preserved).

- [ ] **Step 6: Verify fallback**

Run: `lsof -ti tcp:8642 | xargs kill` then immediately dictate again.
Expected: transcript still pastes (slower, via CLI); app log shows `whisper-server unavailable; falling back to whisper-cli.` and a respawn message; the dictation after that uses the server again.

- [ ] **Step 7: Verify no orphan on relaunch**

Run: `./build.sh` again, then `lsof -ti tcp:8642 | wc -l`
Expected: `1` — exactly one server (the stale one was killed by the new instance or SIGTERM handler).

- [ ] **Step 8: Commit**

```bash
git add WhisperServer.swift main.swift && git commit -m "feat: resident whisper-server with whisper-cli fallback"
```

---

### Task 5: Per-app submit chord + {key} in countdown title

**Files:**
- Modify: `main.swift` — `WhisperController.startCountdown(for:)`, replace `sendReturnKey()` with `sendChord(_:)`; `CountdownOverlay.show(...)` gains a `keyDisplay` provider; `tick()` uses it.

**Interfaces:**
- Consumes: `SubmitChord` (Task 2), `OverlayConfig.submitChord(forBundleID:)` and `title(seconds:keyDisplay:)` (Task 3).
- Produces: `CountdownOverlay.show(duration:config:keyDisplay:onComplete:onCancel:)` where `keyDisplay: @escaping () -> String`. Task 7 modifies this same `show()` further.

- [ ] **Step 1: Replace sendReturnKey with sendChord**

In `WhisperController`, delete `sendReturnKey()` and add:

```swift
    private func sendChord(_ chord: SubmitChord) {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true)
        down?.flags = chord.flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
        up?.flags = chord.flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
```

- [ ] **Step 2: Resolve chord at submit time; live {key} display**

Replace `startCountdown(for:)` with:

```swift
    private func startCountdown(for text: String) {
        guard !text.isEmpty else { return }
        let config = OverlayConfig.load()
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        // Spec error handling: malformed chord strings fall back to enter, with a warning.
        for (app, raw) in config.submitKeys where SubmitChord.parse(raw) == nil {
            log("Invalid submitKeys chord \"\(raw)\" for \(app); using enter.")
        }
        // Chord is resolved against the frontmost app both for display (each tick)
        // and at fire time — submit follows focus (spec §5, Q2).
        let currentChord = {
            config.submitChord(forBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        overlay.show(
            duration: config.duration(forWordCount: words),
            config: config,
            keyDisplay: { currentChord().display },
            onComplete: { [weak self] in
                let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let chord = currentChord()
                self?.sendChord(chord)
                self?.log("Auto-submitted transcript with \(chord.display) to \(bundleID ?? "unknown app").")
            },
            onCancel: { [weak self] in
                self?.log("Auto-submit cancelled by user.")
            }
        )
    }
```

- [ ] **Step 3: Thread keyDisplay through CountdownOverlay**

In `CountdownOverlay`:

- Add property: `private var keyDisplay: (() -> String) = { "↩" }`
- Change `show()` signature to `func show(duration: TimeInterval, config: OverlayConfig, keyDisplay: @escaping () -> String = { "↩" }, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void)` and set `self.keyDisplay = keyDisplay` next to the other assignments.
- Title label creation becomes: `NSTextField(labelWithString: config.title(seconds: Int(ceil(duration)), keyDisplay: keyDisplay()))`
- In `tick()`: `titleLabel?.stringValue = config.title(seconds: Int(ceil(remaining)), keyDisplay: keyDisplay())`
- In `teardown()`: add `keyDisplay = { "↩" }`

- [ ] **Step 4: Build and verify**

Run: `./build.sh`, then:
1. Dictate into TextEdit, let the countdown expire. Expected: title reads `Submitting (↩) in Ns`, plain Return is sent.
2. Dictate into Slack (desktop), let it expire. Expected: title reads `Submitting (⌘↩) in Ns` and the message is sent (⌘↩).
3. Dictate into TextEdit, then click Slack mid-countdown. Expected: title switches to `(⌘↩)` live; on expiry Slack receives ⌘↩ (submit follows focus).

- [ ] **Step 5: Commit**

```bash
git add main.swift && git commit -m "feat: per-app submit chord, live {key} in countdown title"
```

---

### Task 6: Glass panel factory + voice-reactive RecordingOverlay + flow polish

**Files:**
- Create: `OverlayPanel.swift` (shared factory)
- Create: `RecordingOverlay.swift`
- Modify: `main.swift` — `CountdownOverlay.show()` uses the factory; `WhisperController` recording flow (metering timer, overlay states, notification removal)

**Interfaces:**
- Consumes: `OverlayConfig` glass fields (existing).
- Produces: `func makeGlassPanel(width: CGFloat, height: CGFloat, config: OverlayConfig, ignoresMouseEvents: Bool = true) -> (panel: NSPanel, content: NSView)`; `final class RecordingOverlay { func show(config: OverlayConfig); func push(level: CGFloat); func setTranscribing(); func dismiss() }`. Task 7 changes CountdownOverlay's factory call to `ignoresMouseEvents: false`.

- [ ] **Step 1: Extract the glass panel factory**

Create `OverlayPanel.swift` with the construction code currently inlined in `CountdownOverlay.show()` (main.swift lines ~426–455), parameterized:

```swift
import AppKit

/// Builds the floating Liquid Glass panel both overlays share.
/// Returns the panel and the content view to add subviews to.
func makeGlassPanel(width: CGFloat, height: CGFloat, config: OverlayConfig,
                    ignoresMouseEvents: Bool = true) -> (panel: NSPanel, content: NSView) {
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
    panel.ignoresMouseEvents = ignoresMouseEvents
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    content.wantsLayer = true

    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        glass.style = config.glassStyle.lowercased() == "clear" ? .clear : .regular
        glass.cornerRadius = config.cornerRadius
        if let hex = config.tintColorHex, let tint = NSColor(hex: hex) { glass.tintColor = tint }
        glass.contentView = content
        panel.contentView = glass
    } else {
        content.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.82).cgColor
        content.layer?.cornerRadius = config.cornerRadius
        panel.contentView = content
    }
    return (panel, content)
}
```

In `CountdownOverlay.show()`, replace those inlined lines with:

```swift
        let (panel, content) = makeGlassPanel(width: width, height: height, config: config)
```

(keep the `let width` / `let height` clamps and everything after the construction block unchanged; delete `let cornerRadius = config.cornerRadius` which is now unused).

Run `./build.sh` and dictate once — countdown overlay must look and behave exactly as before (this touches the code under the open visibility-bug investigation; if anything renders differently, stop and compare against the pre-refactor commit).

- [ ] **Step 2: Implement RecordingOverlay.swift**

```swift
import AppKit

/// Display-only waveform overlay shown while recording (spec §2).
/// No keyboard or mouse interaction of any kind.
final class RecordingOverlay {
    private static let barCount = 24
    private static let barWidth: CGFloat = 6
    private static let barGap: CGFloat = 4
    private static let panelWidth: CGFloat = 300
    private static let panelHeight: CGFloat = 100
    private static let maxBarHeight: CGFloat = 44
    private static let minBarHeight: CGFloat = 3

    private var panel: NSPanel?
    private var barLayers: [CALayer] = []
    private var levels = [CGFloat](repeating: 0, count: RecordingOverlay.barCount)
    private var statusLabel: NSTextField?
    private var transcribing = false

    func show(config: OverlayConfig) {
        dismiss()
        transcribing = false
        levels = [CGFloat](repeating: 0, count: Self.barCount)

        let width = Self.panelWidth
        let height = Self.panelHeight
        let (panel, content) = makeGlassPanel(width: width, height: height, config: config)

        let totalBarsWidth = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barGap
        let barsX = (width - totalBarsWidth) / 2
        let barsMidY = height / 2 + 8
        let fillColor = config.fillColorHex.flatMap { NSColor(hex: $0) } ?? .controlAccentColor

        barLayers = []
        for i in 0..<Self.barCount {
            let layer = CALayer()
            layer.backgroundColor = fillColor.cgColor
            layer.cornerRadius = Self.barWidth / 2
            layer.frame = NSRect(
                x: barsX + CGFloat(i) * (Self.barWidth + Self.barGap),
                y: barsMidY - Self.minBarHeight / 2,
                width: Self.barWidth,
                height: Self.minBarHeight
            )
            content.layer?.addSublayer(layer)
            barLayers.append(layer)
        }

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = Self.statusText("Recording…")
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 12, width: width, height: 16)
        content.addSubview(label)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.minY + f.height * 0.15))
        }

        self.panel = panel
        self.statusLabel = label
        panel.orderFrontRegardless()
    }

    private static func statusText(_ text: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 12)
        ])
        s.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12)
        ]))
        return s
    }

    /// level in 0...1; newest sample enters at the right, history scrolls left.
    func push(level: CGFloat) {
        guard panel != nil, !transcribing else { return }
        levels.removeFirst()
        levels.append(max(0, min(1, level)))

        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 30.0)
        for (i, layer) in barLayers.enumerated() {
            let h = Self.minBarHeight + (Self.maxBarHeight - Self.minBarHeight) * levels[i]
            var frame = layer.frame
            let midY = frame.midY
            frame.size.height = h
            frame.origin.y = midY - h / 2
            layer.frame = frame
        }
        CATransaction.commit()
    }

    func setTranscribing() {
        transcribing = true
        statusLabel?.attributedStringValue = Self.statusText("Transcribing…")
        for layer in barLayers { layer.opacity = 0.35 }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        barLayers = []
        statusLabel = nil
        transcribing = false
    }
}
```

- [ ] **Step 3: Wire metering and overlay states into WhisperController**

Add properties:

```swift
    private let recordingOverlay = RecordingOverlay()
    private var meterTimer: Timer?
```

In `startRecording()`, after `recorder = nextRecorder` / `recordingStartTime = Date()`:
- add `nextRecorder.isMeteringEnabled = true` (before `nextRecorder.record()`)
- replace `notify(title: "Whisper", body: "Recording... release the hotkey to stop.")` with:

```swift
            recordingOverlay.show(config: OverlayConfig.load())
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)  // -160...0 dBFS
                let level = max(0, min(1, (CGFloat(db) + 50) / 50))
                self.recordingOverlay.push(level: level)
            }
```

In `stopRecording()`:
- first lines: `meterTimer?.invalidate(); meterTimer = nil`
- in the too-short-hold branch, add `recordingOverlay.dismiss()` before `return`
- replace `notify(title: "Whisper", body: "Transcribing...")` with `recordingOverlay.setTranscribing()`

In `transcribe()`'s main-queue completion blocks:
- happy path: add `self.recordingOverlay.dismiss()` as the first line; delete `self.notify(title: "Whisper", body: "Transcript pasted.")` (log line stays; error/no-accessibility notifies stay)
- both failure paths (`No recording found.` and `Transcription failed...`): add `self.recordingOverlay.dismiss()` before the notify.

In `keyDown()`, after `overlay.dismiss()` nothing extra is needed — `recordingOverlay.show()` self-dismisses any stale panel.

In `startRecording()`'s catch block, add `recordingOverlay.dismiss()` before the notify (overlay must never outlive a failed start).

- [ ] **Step 4: Build and verify the full visual arc**

Run: `./build.sh`, then hold ⌘⌥⌃R and speak with pauses.
Expected:
1. Waveform pill appears lower-center immediately; bars dance with voice, flatten in pauses.
2. Release: label flips to "● Transcribing…", bars freeze dimmed. No notifications.
3. Transcript pastes; waveform disappears; countdown appears centered.
4. Too-short tap (<0.3s): waveform appears and vanishes, nothing else happens.
5. Speak very quietly vs loudly: bar amplitude visibly differs (if everything pegs high/low, tune the `+50)/50` mapping constant).

- [ ] **Step 5: Commit**

```bash
git add OverlayPanel.swift RecordingOverlay.swift main.swift && git commit -m "feat: voice-reactive waveform overlay; waveform->transcribing->countdown flow"
```

---

### Task 7: Countdown cancel hardening — Esc swallow, typing cancels, click cancels

**Files:**
- Modify: `main.swift` — `CountdownOverlay` only

**Interfaces:**
- Consumes: `makeGlassPanel(..., ignoresMouseEvents:)` (Task 6).
- Produces: no new public API; `show()` installs interceptor, `teardown()` removes it.

- [ ] **Step 1: Add the click-catcher view and enable mouse**

In `main.swift`, above `final class CountdownOverlay`, add:

```swift
/// Transparent view that turns any click into a cancel (keyboard-independent
/// cancel path — spec §5 Q6).
private final class ClickCatcherView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}
```

In `CountdownOverlay.show()`:
- change the factory call to `makeGlassPanel(width: width, height: height, config: config, ignoresMouseEvents: false)`
- after the hint label is added, add:

```swift
        let clickCatcher = ClickCatcherView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        clickCatcher.onClick = { [weak self] in self?.cancel() }
        content.addSubview(clickCatcher)
```

- [ ] **Step 2: Replace the global monitor with a CGEventTap (+ fallback)**

Add properties to `CountdownOverlay`:

```swift
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
```

In `show()`, replace the `monitor = NSEvent.addGlobalMonitorForEvents...` block with `installKeyInterceptor()`, and add the method:

```swift
    /// Spec §5: Esc is swallowed and cancels; any other keydown cancels but
    /// passes through (user is editing — Q3). Tap re-enables itself if the OS
    /// disables it; if the tap can't be created at all, fall back to an
    /// observe-only monitor (Esc leaks but cancel still works — Q6).
    private func installKeyInterceptor() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let overlay = Unmanaged<CountdownOverlay>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = overlay.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 {  // Esc: cancel and swallow
                DispatchQueue.main.async { overlay.cancel() }
                return nil
            }
            // Any other key: user took over — cancel, let the key through.
            DispatchQueue.main.async { overlay.cancel() }
            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let eventTap {
            tapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            debugLog("CGEventTap unavailable; falling back to global monitor (Esc will leak through).")
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
                self?.cancel()
            }
        }
    }
```

In `teardown()`, before the existing monitor removal lines, add:

```swift
        if let tapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes) }
        tapRunLoopSource = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        eventTap = nil
```

Lifetime note (why `passUnretained` is safe): the tap only exists between `show()` and `teardown()`, and `CountdownOverlay` is owned for the app's lifetime by `WhisperController`. The submit chord itself is posted by `onComplete` *after* `teardown()` removes the tap, so the app never intercepts its own synthesized keystrokes.

- [ ] **Step 3: Build and run the cancel-path checklist**

Run: `./build.sh`, then verify each (spec Testing §4):
1. **Esc swallowed:** In Slack, open a thread pane, dictate, press Esc during countdown. Expected: countdown cancels AND the thread pane stays open (Esc did not reach Slack).
2. **Typing cancels:** dictate into TextEdit, type a letter during countdown. Expected: countdown disappears, the letter appears in the text, no Enter is ever sent.
3. **Click cancels:** dictate, click the countdown pill. Expected: cancels, no submit.
4. **Expiry still fires:** dictate into TextEdit, touch nothing. Expected: Return sent as usual.
5. **Hotkey re-press:** dictate, then re-hold ⌘⌥⌃R mid-countdown. Expected: countdown vanishes, new recording starts, no submit of chunk 1 (note: the hotkey's own keydown now cancels via the tap — same net effect as the old `dismiss()`, just logged as a cancel).
6. Check `$TMPDIR/whisper-hotkey/whisper-hotkey.log` for `Auto-submit cancelled by user.` entries matching 1–3.

- [ ] **Step 4: Commit**

```bash
git add main.swift && git commit -m "feat: countdown cancel hardening - Esc swallow via event tap, typing/click cancel"
```

---

### Task 8: Full integration pass

**Files:**
- None modified (verification only; fix-forward if anything fails)

- [ ] **Step 1: Unit tests green**

Run: `swiftc SubmitChord.swift Config.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: `ALL TESTS PASSED`

- [ ] **Step 2: Spec testing checklist, end to end**

Run `./build.sh`, wait for the server model load, then walk the spec's Testing section in order:
1. Romanian phrase, then English phrase — both transcribe correctly, each returning in well under a second after release (check `whisper-server transcribed in` log lines).
2. `lsof -ti tcp:8642 | xargs kill` → next dictation works via CLI fallback, failover logged, server respawns for the one after.
3. Full visual arc: waveform (reactive) → "Transcribing…" (frozen, dimmed) → countdown (centered) — zero notifications on the happy path.
4. Countdown: Esc swallowed (Slack thread stays open), typing cancels, click cancels, expiry in Slack sends ⌘↩, expiry in TextEdit sends ↩.
5. Countdown title shows the live chord: `Submitting (⌘↩) in 3s` over Slack, `(↩)` elsewhere, switching if you change apps mid-countdown.

- [ ] **Step 3: Memory-footprint sanity check**

Run: `ps -o rss= -p "$(lsof -ti tcp:8642)" | awk '{printf "%.1f GB\n", $1/1048576}'`
Expected: roughly 1.5–2 GB (the accepted trade-off from the spec; if it's wildly more, investigate before closing out).

- [ ] **Step 4: Close out**

If any step failed, fix forward and re-run this task's checklist. Then report results against the spec, including actual transcription latency numbers observed.
