import AVFoundation
import AppKit

/// Orchestrates one dictation: hold to record, release to transcribe, paste,
/// then auto-submit. The parts it delegates to — transcription, keystrokes,
/// clipboard, notifications, logging — each live behind their own type, so this
/// file is the flow and nothing else.
final class WhisperController: NSObject, AVAudioRecorderDelegate {
    private static let minimumHoldDuration: TimeInterval = 0.3

    private let runtimeDir = RuntimePaths.runtimeDir
    private var recorder: AVAudioRecorder?
    private var recordingStartTime: Date?
    /// The app the user was dictating into, captured when recording starts.
    private var recordingBundleID: String?
    /// Whether the hotkey is currently down. The microphone permission prompt can
    /// resolve after the release; starting on a released key produces a
    /// recording nobody can stop.
    private var hotKeyHeld = false
    private var transcribing = false
    private let overlay = CountdownOverlay()
    private let recordingOverlay = RecordingOverlay()
    private var meterTimer: Timer?
    private var server: WhisperServer?
    private var pipeline: Transcriber?
    private let injector = TextInjector()

    /// Set by AppBootstrap so a config change re-registers the hotkey.
    var configChanged: ((OverlayConfig) -> Void)?
    /// Set by StatusMenu to show what the app is doing.
    var stateChanged: ((String) -> Void)?

    /// The hotkey is ignored while paused; a recording in progress still finishes.
    var isPaused = false

    /// For the log line correlating first-use-after-a-gap with transcription time.
    private var lastDictationAt: Date?
    private var warmedThisDictation = false

    private var wavFile: URL { runtimeDir.appendingPathComponent("recording.wav") }
    private var transcriptBase: URL { runtimeDir.appendingPathComponent("transcript") }
    private var serverLogFile: URL { runtimeDir.appendingPathComponent("whisper-server.log") }
    private var cliLogFile: URL { runtimeDir.appendingPathComponent("whisper-cli.log") }

    private func log(_ message: String) { Logger.shared.log(message) }
    private func notify(_ body: String) { Notifier.notify(title: "Whisper", body: body) }
    private func setState(_ text: String) { stateChanged?(text) }
    private var readyState: String { isPaused ? "Paused" : "Ready" }

    /// (Re)starts the resident server from `config`. Called at launch and after
    /// the user edits the config while the app is running.
    func restartServer(config: OverlayConfig) {
        server?.stop()
        server = nil

        let cli = WhisperCLITranscriber(
            install: config.whisperInstall,
            transcriptBase: transcriptBase,
            logFile: cliLogFile,
            log: log
        )

        guard config.serverEnabled else {
            log("whisper-server disabled in config; using whisper-cli.")
            pipeline = TranscribingPipeline(server: nil, cli: cli, log: log)
            return
        }

        let server = WhisperServer(
            install: config.whisperInstall,
            port: config.serverPort,
            logFile: serverLogFile,
            log: log
        )
        server.start()
        self.server = server
        pipeline = TranscribingPipeline(
            server: ServerTranscriber(server: server),
            cli: cli,
            log: log,
            onServerFailure: { server.respawnIfNeeded() }
        )
    }

    func shutdown() {
        server?.stop()
    }

    func hotkeyPressed() {
        if isPaused { return }
        // A new dictation supersedes a countdown still counting down.
        overlay.dismiss()
        if transcribing {
            notify("Already transcribing.")
            return
        }
        guard recorder == nil else { return }

        hotKeyHeld = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self.hotKeyHeld = false
                        self.notify("Microphone access is required.")
                        self.log("Microphone permission denied.")
                        return
                    }
                    if self.hotKeyHeld {
                        self.startRecording()
                    } else {
                        self.log("Microphone permission granted after the hotkey was released; this press was dropped.")
                        self.notify("Microphone access granted — press the hotkey again.")
                    }
                }
            }
        case .denied, .restricted:
            notify("Microphone access is denied. Enable it in System Settings → Privacy & Security.")
            log("Microphone permission denied; recording is unavailable.")
        @unknown default:
            notify("Microphone access is required.")
        }
    }

    func hotkeyReleased() {
        hotKeyHeld = false
        guard let recorder, recorder.isRecording else { return }
        stopRecording()
    }

    /// The recorder failing mid-dictation is otherwise silent: the file just
    /// comes out short or empty and the user is told "no speech detected".
    func recorder(_ recorder: AVAudioRecorder, encodeErrorForRecordAt time: TimeInterval, error: (any Error)?, shouldComplete: Bool) {
        log("Recording encode error at \(time)s: \(error?.localizedDescription ?? "unknown").")
    }

    private func currentConfig() -> OverlayConfig {
        let config = OverlayConfig.load(log: log)
        configChanged?(config)
        return config
    }

    private func startRecording() {
        do {
            let config = currentConfig()
            try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

            // The model's Metal buffers unwire after ~180s idle and can then be
            // swapped out, which is what makes the first dictation of the day
            // slow. Page them back in now, while the user is still talking.
            warmedThisDictation = server?.warmUp(afterSeconds: config.serverWarmUpAfterSeconds) ?? false

            try? FileManager.default.removeItem(at: wavFile)
            try? FileManager.default.removeItem(at: transcriptBase.appendingPathExtension("txt"))

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
            recordingBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            recordingOverlay.show(config: config)
            setState("Recording…")

            // `.common` so the waveform keeps scrolling while a tracking
            // runloop elsewhere would pause the default mode.
            let tick = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                self.recordingOverlay.push(level: RecordingOverlay.level(fromDB: Double(recorder.averagePower(forChannel: 0))))
            }
            RunLoop.main.add(tick, forMode: .common)
            meterTimer = tick
            log("Recording started.")
        } catch {
            recordingOverlay.dismiss()
            notify("Could not start recording. See \(Logger.shared.path).")
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
        let dictationBundleID = recordingBundleID
        recordingBundleID = nil

        if let startTime, Date().timeIntervalSince(startTime) < Self.minimumHoldDuration {
            log(String(format: "Hold too short (%.2fs); discarding recording.", Date().timeIntervalSince(startTime)))
            recordingOverlay.dismiss()
            setState(readyState)
            try? FileManager.default.removeItem(at: wavFile)
            return
        }

        recordingOverlay.setTranscribing()
        log("Recording stopped.")
        transcribe(config: currentConfig(), dictationBundleID: dictationBundleID)
    }

    private func transcribe(config: OverlayConfig, dictationBundleID: String?) {
        guard let pipeline else {
            recordingOverlay.dismiss()
            notify("No transcription backend is configured.")
            log("Transcribe called with no pipeline configured.")
            setState(readyState)
            return
        }
        transcribing = true
        setState("Transcribing…")

        DispatchQueue.global(qos: .userInitiated).async {
            // Every path below sets its own state; clearing the flag is all this
            // needs to do, so it cannot overwrite the "Auto-submitting…" state
            // the countdown has just set.
            defer { DispatchQueue.main.async { self.transcribing = false } }

            guard FileManager.default.fileExists(atPath: self.wavFile.path) else {
                DispatchQueue.main.async {
                    self.recordingOverlay.dismiss()
                    self.setState(self.readyState)
                    self.notify("No recording found.")
                }
                self.log("No recording found.")
                return
            }

            guard let transcript = self.runTranscription(pipeline: pipeline, config: config) else {
                DispatchQueue.main.async {
                    self.recordingOverlay.dismiss()
                    self.setState(self.readyState)
                    self.notify("Transcription failed. See \(Logger.shared.path).")
                }
                return
            }

            let cleaned = cleanTranscript(transcript)
            DispatchQueue.main.async {
                self.recordingOverlay.dismiss()
                self.deliver(cleaned, config: config, dictationBundleID: dictationBundleID)
            }
        }
    }

    /// Main queue. Clipboard, paste, and the auto-submit countdown.
    private func deliver(_ text: String, config: OverlayConfig, dictationBundleID: String?) {
        cleanupAudio()

        guard !text.isEmpty else {
            setState(readyState)
            notify("No speech detected.")
            log("Transcript was empty; nothing to paste.")
            return
        }

        let previousClipboard = Clipboard.currentString()
        Clipboard.setString(text)

        guard injector.isTrusted else {
            setState(readyState)
            notify("Transcript is on the clipboard. Grant Accessibility to auto-paste.")
            log("Transcript copied to clipboard; auto-paste skipped (Accessibility permission not granted).")
            return
        }

        let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if config.requireUnchangedFocus && !shouldAutoPaste(startBundleID: dictationBundleID, currentBundleID: currentBundleID) {
            setState(readyState)
            notify("Focus changed during transcription — transcript is on the clipboard.")
            log("Auto-paste skipped: focus changed from \(dictationBundleID ?? "unknown") to \(currentBundleID ?? "none").")
            return
        }

        guard injector.paste() else {
            setState(readyState)
            notify("Could not paste the transcript.")
            log("Auto-paste failed: keystroke injection was refused.")
            return
        }

        log("Transcript pasted into \(currentBundleID ?? "unknown app"); clipboard keeps it as a fallback.")
        startCountdown(for: text, config: config, previousClipboard: previousClipboard)
    }

    /// Dictation audio is regenerable and sensitive: it goes away as soon as the
    /// transcript is in hand.
    private func cleanupAudio() {
        try? FileManager.default.removeItem(at: wavFile)
        try? FileManager.default.removeItem(at: transcriptBase.appendingPathExtension("txt"))
    }

    /// Background queue only. Server first, `whisper-cli` as the rescue.
    private func runTranscription(pipeline: Transcriber, config: OverlayConfig) -> String? {
        let gap = lastDictationAt.map { Date().timeIntervalSince($0) }
        lastDictationAt = Date()
        let started = Date()
        guard let text = pipeline.transcribe(wav: wavFile, config: config) else {
            log("Transcription failed on both the server and whisper-cli.")
            return nil
        }
        log(String(format: "Transcribed in %.2fs (gap since last dictation: %@, warmed: %@).",
                   Date().timeIntervalSince(started),
                   gap.map { String(format: "%.0fs", $0) } ?? "first since launch",
                   warmedThisDictation ? "yes" : "no"))
        return text
    }

    private func startCountdown(for text: String, config: OverlayConfig, previousClipboard: String?) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        // Chord is resolved against the frontmost app both for display (each tick)
        // and at fire time — submit follows focus (spec §5, Q2).
        let currentChord = {
            config.submitChord(forBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        setState("Auto-submitting…")
        overlay.show(
            duration: config.duration(forWordCount: words),
            config: config,
            keyDisplay: { currentChord().display },
            onComplete: { [weak self] in
                guard let self else { return }
                let chord = currentChord()
                let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if self.injector.send(chord) {
                    self.log("Auto-submitted transcript with \(chord.display) to \(bundleID ?? "unknown app").")
                } else {
                    self.notify("Could not submit: Accessibility permission is not granted.")
                    self.log("Auto-submit skipped: Accessibility permission is not granted.")
                }
                Clipboard.restoreIfUntouched(previous: previousClipboard, ours: text)
                self.setState(self.readyState)
            },
            onCancel: { [weak self] in
                self?.log("Auto-submit cancelled by user.")
                Clipboard.restoreIfUntouched(previous: previousClipboard, ours: text)
                self?.setState(self?.readyState ?? "Ready")
            }
        )
    }
}
