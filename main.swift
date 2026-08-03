import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import CoreGraphics
import Foundation

final class WhisperController: NSObject, AVAudioRecorderDelegate {
    private static let minimumHoldDuration: TimeInterval = 0.3

    private let whisperRoot = URL(fileURLWithPath: "/Users/arthur/whisper.cpp")
    private let runtimeDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-hotkey", isDirectory: true)
    private var recorder: AVAudioRecorder?
    private var recordingStartTime: Date?
    private var transcribing = false
    private let overlay = CountdownOverlay()
    private let recordingOverlay = RecordingOverlay()
    private var meterTimer: Timer?
    private var server: WhisperServer?
    /// For the log line correlating first-use-after-a-gap with transcription time.
    private var lastDictationAt: Date?
    private var warmedThisDictation = false

    private var whisperBin: URL {
        whisperRoot.appendingPathComponent("build/bin/whisper-cli")
    }

    private var modelFile: URL {
        whisperRoot.appendingPathComponent("models/ggml-large-v3-turbo.bin")
    }

    private var wavFile: URL {
        runtimeDir.appendingPathComponent("recording.wav")
    }

    private var transcriptBase: URL {
        runtimeDir.appendingPathComponent("transcript")
    }

    private var transcriptFile: URL {
        runtimeDir.appendingPathComponent("transcript.txt")
    }

    private var logFile: URL {
        runtimeDir.appendingPathComponent("whisper-hotkey.log")
    }

    private var serverLogFile: URL {
        runtimeDir.appendingPathComponent("whisper-server.log")
    }

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

    func keyDown() {
        overlay.dismiss()
        if transcribing {
            notify(title: "Whisper", body: "Already transcribing.")
            return
        }
        guard recorder == nil else { return }
        requestAndStartRecording()
    }

    func keyUp() {
        guard let recorder, recorder.isRecording else { return }
        stopRecording()
    }

    private func requestAndStartRecording() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.startRecording()
                } else {
                    self.notify(title: "Whisper", body: "Microphone access is required.")
                    self.log("Microphone permission denied.")
                }
            }
        }
    }

    private func startRecording() {
        do {
            let config = OverlayConfig.load()
            try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

            // The model's Metal buffers unwire after ~180s idle and can then be
            // swapped out, which is what makes the first dictation of the day
            // slow. Page them back in now, while the user is still talking.
            warmedThisDictation = server?.warmUp(afterSeconds: config.serverWarmUpAfterSeconds) ?? false

            try? FileManager.default.removeItem(at: wavFile)
            try? FileManager.default.removeItem(at: transcriptFile)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]

            let nextRecorder = try AVAudioRecorder(url: wavFile, settings: settings)
            nextRecorder.delegate = self
            nextRecorder.isMeteringEnabled = true
            nextRecorder.prepareToRecord()
            nextRecorder.record()
            recorder = nextRecorder
            recordingStartTime = Date()
            recordingOverlay.show(config: config)
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)  // -160...0 dBFS
                let level = max(0, min(1, (CGFloat(db) + 50) / 50))
                self.recordingOverlay.push(level: level)
            }
            log("Recording started.")
        } catch {
            recordingOverlay.dismiss()
            notify(title: "Whisper", body: "Could not start recording.")
            log("Recording start failed: \(error)")
        }
    }

    private func stopRecording() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        let startTime = recordingStartTime
        recordingStartTime = nil

        if let startTime, Date().timeIntervalSince(startTime) < Self.minimumHoldDuration {
            log("Hold too short (\(Date().timeIntervalSince(startTime))s); discarding recording.")
            recordingOverlay.dismiss()
            try? FileManager.default.removeItem(at: wavFile)
            return
        }

        recordingOverlay.setTranscribing()
        log("Recording stopped.")
        transcribe()
    }

    private func transcribe() {
        transcribing = true

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async {
                    self.transcribing = false
                }
            }

            guard FileManager.default.fileExists(atPath: self.wavFile.path) else {
                DispatchQueue.main.async {
                    self.recordingOverlay.dismiss()
                    self.notify(title: "Whisper", body: "No recording found.")
                }
                self.log("No recording found.")
                return
            }

            guard let transcript = self.runTranscription() else {
                DispatchQueue.main.async {
                    self.recordingOverlay.dismiss()
                    self.notify(title: "Whisper", body: "Transcription failed. See /tmp/whisper-hotkey.")
                }
                return
            }

            let cleaned = transcript
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            DispatchQueue.main.async {
                self.recordingOverlay.dismiss()
                self.copyToClipboard(cleaned)
                if self.pasteIntoFocusedField() {
                    self.log("Transcript copied to clipboard and auto-pasted.")
                    self.startCountdown(for: cleaned)
                } else {
                    self.notify(title: "Whisper", body: "Transcript copied to clipboard. Enable Accessibility permission to auto-paste.")
                    self.log("Transcript copied to clipboard; auto-paste skipped (Accessibility permission not granted).")
                }
            }
        }
    }

    /// Background queue only. Tries the resident server, falls back to whisper-cli.
    private func runTranscription() -> String? {
        let config = OverlayConfig.load()
        let gap = lastDictationAt.map { Date().timeIntervalSince($0) }
        lastDictationAt = Date()
        if config.serverEnabled, let server {
            let started = Date()
            if let text = server.transcribe(wav: wavFile, pinnedLanguages: config.pinnedLanguages) {
                log(String(format: "whisper-server transcribed in %.2fs (gap since last dictation: %@, warmed: %@).",
                           Date().timeIntervalSince(started),
                           gap.map { String(format: "%.0fs", $0) } ?? "first since launch",
                           warmedThisDictation ? "yes" : "no"))
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

    private func pasteIntoFocusedField() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9
        let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDownEvent?.flags = .maskCommand
        let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUpEvent?.flags = .maskCommand

        keyDownEvent?.post(tap: .cgSessionEventTap)
        keyUpEvent?.post(tap: .cgSessionEventTap)
        return true
    }

    private func startCountdown(for text: String) {
        guard !text.isEmpty else { return }
        let config = OverlayConfig.load()
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        // Malformed submitKeys chord strings fall back to enter; warn once per countdown.
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

    private func openLogHandle() -> FileHandle? {
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logFile)
        try? handle?.seekToEnd()
        return handle
    }

    private func notify(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(body)\" with title \"\(title)\""]
        try? process.run()
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func log(_ message: String) {
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: logFile) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }
}

/// Transparent view that turns any click into a cancel (keyboard-independent
/// cancel path — spec §5 Q6).
private final class ClickCatcherView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class CountdownOverlay {
    private func debugLog(_ message: String) { OverlayDebug.log(message) }

    private var panel: NSPanel?
    private var timer: Timer?
    private var monitor: Any?
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var startTime: Date?
    private var duration: TimeInterval = 0
    private var onComplete: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var titleLabel: NSTextField?
    private var track: NSView?
    private var fill: NSView?
    private var config = OverlayConfig()
    private var keyDisplay: (() -> String) = { "↩" }

    func show(duration: TimeInterval, config: OverlayConfig, keyDisplay: @escaping () -> String = { "↩" }, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        self.config = config
        self.duration = duration
        self.keyDisplay = keyDisplay
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.startTime = Date()

        // Clamp to minimums so a small config value can't collapse the overlay out of view.
        let width = max(config.width, 220)
        let height = max(config.height, 110)
        let (panel, content) = makeGlassPanel(width: width, height: height, config: config, ignoresMouseEvents: false)

        let title = NSTextField(labelWithString: config.title(seconds: Int(ceil(duration)), keyDisplay: keyDisplay()))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: height - 40, width: width, height: 24)
        content.addSubview(title)

        let barMargin: CGFloat = 30
        let barWidth = width - barMargin * 2
        let trackView = NSView(frame: NSRect(x: barMargin, y: (height - 14) / 2, width: barWidth, height: 14))
        trackView.wantsLayer = true
        trackView.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        trackView.layer?.cornerRadius = 7
        content.addSubview(trackView)

        let fillView = NSView(frame: NSRect(x: 0, y: 0, width: barWidth, height: 14))
        fillView.wantsLayer = true
        let fillColor = config.fillColorHex.flatMap { NSColor(hex: $0) } ?? .controlAccentColor
        fillView.layer?.backgroundColor = fillColor.cgColor
        fillView.layer?.cornerRadius = 7
        trackView.addSubview(fillView)

        let hint = NSTextField(labelWithString: config.cancelHint)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 18, width: width, height: 16)
        content.addSubview(hint)

        let clickCatcher = ClickCatcherView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        clickCatcher.onClick = { [weak self] in self?.cancel() }
        content.addSubview(clickCatcher)

        if let screen = NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
        }

        self.panel = panel
        self.titleLabel = title
        self.track = trackView
        self.fill = fillView
        OverlayDebug.orderFrontLogging(panel, "countdown")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak panel] in
            guard let panel, !panel.isVisible else { return }
            OverlayDebug.log(OverlayDebug.probe("countdown 300ms later", panel))
        }

        installKeyInterceptor()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

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

    private func tick() {
        guard let startTime, duration > 0 else { return }
        let remaining = max(0, duration - Date().timeIntervalSince(startTime))
        let fraction = CGFloat(max(0, min(1, remaining / duration)))
        if let track, let fill { fill.frame.size.width = track.bounds.width * fraction }
        titleLabel?.stringValue = config.title(seconds: Int(ceil(remaining)), keyDisplay: keyDisplay())
        if remaining <= 0 { complete() }
    }

    private func complete() { let cb = onComplete; teardown(); cb?() }
    private func cancel() { let cb = onCancel; teardown(); cb?() }
    func dismiss() { teardown() }

    private func teardown() {
        timer?.invalidate(); timer = nil
        if let tapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes) }
        tapRunLoopSource = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        eventTap = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil); panel = nil
        startTime = nil; onComplete = nil; onCancel = nil
        titleLabel = nil; track = nil; fill = nil
        keyDisplay = { "↩" }
    }
}

OverlayConfig.writeDefaultIfMissing()
let controller = WhisperController()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

// The LaunchAgent starts us with `open -gj`, and `-j` means "launch hidden".
// While NSApp is hidden AppKit backs our panels with real window-server windows
// but refuses to order them in, so no overlay ever appears while every other
// code path (timers, clipboard, CGEvent posting) keeps working. Undo it without
// activating, so we never steal focus from whatever the user is typing into.
app.unhideWithoutActivation()

controller.startServerIfEnabled()

// build.sh relaunches us with pkill (SIGTERM): take the child server down with us.
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    controller.shutdown()
    exit(0)
}
sigtermSource.resume()

func fourCharCode(_ value: String) -> OSType {
    var result: OSType = 0
    for byte in value.utf8 {
        result = (result << 8) + OSType(byte)
    }
    return result
}

let handler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr && hotKeyID.signature == fourCharCode("WSPR") && hotKeyID.id == 1 else {
        return noErr
    }

    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
        controller.keyDown()
    case UInt32(kEventHotKeyReleased):
        controller.keyUp()
    default:
        break
    }

    return noErr
}

var eventTypes = [
    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
]
InstallEventHandler(GetApplicationEventTarget(), handler, eventTypes.count, &eventTypes, nil, nil)

var hotKeyRef: EventHotKeyRef?
let modifiers = UInt32(cmdKey | optionKey | controlKey)
let keyCode = UInt32(kVK_ANSI_R)
let hotKeyID = EventHotKeyID(signature: fourCharCode("WSPR"), id: 1)
let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

if status != noErr {
    fputs("Could not register hotkey. OSStatus: \(status)\n", stderr)
    exit(1)
}

if !AXIsProcessTrusted() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
}

app.run()
