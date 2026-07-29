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
            try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
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
            nextRecorder.prepareToRecord()
            nextRecorder.record()
            recorder = nextRecorder
            recordingStartTime = Date()
            notify(title: "Whisper", body: "Recording... release the hotkey to stop.")
            log("Recording started.")
        } catch {
            notify(title: "Whisper", body: "Could not start recording.")
            log("Recording start failed: \(error)")
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        let startTime = recordingStartTime
        recordingStartTime = nil

        if let startTime, Date().timeIntervalSince(startTime) < Self.minimumHoldDuration {
            log("Hold too short (\(Date().timeIntervalSince(startTime))s); discarding recording.")
            try? FileManager.default.removeItem(at: wavFile)
            return
        }

        notify(title: "Whisper", body: "Transcribing...")
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
                    self.notify(title: "Whisper", body: "No recording found.")
                }
                self.log("No recording found.")
                return
            }

            try? FileManager.default.removeItem(at: self.transcriptFile)

            let process = Process()
            process.currentDirectoryURL = self.whisperRoot
            process.executableURL = self.whisperBin
            process.arguments = [
                "-m", self.modelFile.path,
                "-f", self.wavFile.path,
                "-otxt",
                "-of", self.transcriptBase.path,
                "-nt",
                "-np",
                "-l", "auto"
            ]

            let logHandle = self.openLogHandle()
            process.standardOutput = logHandle
            process.standardError = logHandle

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                self.log("Failed to launch whisper-cli: \(error)")
                DispatchQueue.main.async {
                    self.notify(title: "Whisper", body: "Could not run whisper-cli.")
                }
                return
            }

            guard process.terminationStatus == 0,
                  let transcript = try? String(contentsOf: self.transcriptFile, encoding: .utf8)
            else {
                self.log("Transcription failed with status \(process.terminationStatus).")
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

            DispatchQueue.main.async {
                self.copyToClipboard(cleaned)
                if self.pasteIntoFocusedField() {
                    self.notify(title: "Whisper", body: "Transcript pasted.")
                    self.log("Transcript copied to clipboard and auto-pasted.")
                    self.startCountdown(for: cleaned)
                } else {
                    self.notify(title: "Whisper", body: "Transcript copied to clipboard. Enable Accessibility permission to auto-paste.")
                    self.log("Transcript copied to clipboard; auto-paste skipped (Accessibility permission not granted).")
                }
            }
        }
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
        overlay.show(duration: config.duration(forWordCount: words), config: config, onComplete: { [weak self] in
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

final class CountdownOverlay {
    private static let debugLogFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("whisper-hotkey", isDirectory: true)
        .appendingPathComponent("whisper-hotkey.log")

    private func debugLog(_ message: String) {
        try? FileManager.default.createDirectory(at: Self.debugLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] [overlay-debug] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: Self.debugLogFile.path) {
            FileManager.default.createFile(atPath: Self.debugLogFile.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: Self.debugLogFile) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

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
    private var config = OverlayConfig()

    func show(duration: TimeInterval, config: OverlayConfig, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        self.config = config
        self.duration = duration
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.startTime = Date()

        let screens = NSScreen.screens
        debugLog("show() called. screens=\(screens.count) main=\(NSScreen.main?.frame.debugDescription ?? "nil") appActive=\(NSApp.isActive) activationPolicy=\(NSApp.activationPolicy().rawValue) occlusionState=\(NSApp.occlusionState.rawValue)")

        // Clamp to minimums so a small config value can't collapse the overlay out of view.
        let width = max(config.width, 220)
        let height = max(config.height, 110)
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

        let cornerRadius = config.cornerRadius
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            glass.style = config.glassStyle.lowercased() == "clear" ? .clear : .regular
            glass.cornerRadius = cornerRadius
            if let hex = config.tintColorHex, let tint = NSColor(hex: hex) { glass.tintColor = tint }
            glass.contentView = content
            panel.contentView = glass
        } else {
            content.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.82).cgColor
            content.layer?.cornerRadius = cornerRadius
            panel.contentView = content
        }

        let title = NSTextField(labelWithString: config.title(seconds: Int(ceil(duration))))
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

        if let screen = NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
        }

        self.panel = panel
        self.titleLabel = title
        self.track = trackView
        self.fill = fillView
        panel.orderFrontRegardless()

        debugLog("after orderFrontRegardless: isVisible=\(panel.isVisible) frame=\(panel.frame.debugDescription) screen=\(panel.screen?.frame.debugDescription ?? "nil") occlusionState=\(panel.occlusionState.rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak panel] in
            guard let panel else { return }
            self?.debugLog("300ms later: isVisible=\(panel.isVisible) frame=\(panel.frame.debugDescription) screen=\(panel.screen?.frame.debugDescription ?? "nil") occlusionState=\(panel.occlusionState.rawValue) screens=\(NSScreen.screens.count)")
        }

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
        titleLabel?.stringValue = config.title(seconds: Int(ceil(remaining)))
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

OverlayConfig.writeDefaultIfMissing()
let controller = WhisperController()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

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
