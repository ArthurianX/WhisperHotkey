import Foundation

/// Manages a resident `whisper-server` child process and talks to it over HTTP.
final class WhisperServer {
    private let install: WhisperInstall
    private let port: Int
    private let logFile: URL
    private let log: (String) -> Void
    private var process: Process?

    /// Last time the model actually computed something — loading it at startup
    /// counts, since that leaves it resident. Guarded by `stateLock` because
    /// inference runs on a background queue while warm-ups run on another.
    private let stateLock = NSLock()
    private var lastComputeAt = Date()
    private var warmUpInFlight = false

    private var pidFileURL: URL {
        logFile.deletingLastPathComponent().appendingPathComponent("whisper-server.pid")
    }

    private var secondsSinceCompute: TimeInterval {
        stateLock.lock(); defer { stateLock.unlock() }
        return Date().timeIntervalSince(lastComputeAt)
    }

    private func noteCompute() {
        stateLock.lock(); defer { stateLock.unlock() }
        lastComputeAt = Date()
    }

    init(install: WhisperInstall, port: Int, logFile: URL, log: @escaping (String) -> Void) {
        self.install = install
        self.port = port
        self.logFile = logFile
        self.log = log
    }

    func start() {
        killStale()
        let p = Process()
        p.currentDirectoryURL = install.root
        p.executableURL = install.serverURL
        p.arguments = [
            "-m", install.modelFile.path,
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
            noteCompute()
            try? "\(p.processIdentifier)".write(to: pidFileURL, atomically: true, encoding: .utf8)
            log("whisper-server started (pid \(p.processIdentifier), port \(port)).")
        } catch {
            log("Failed to launch whisper-server: \(error)")
        }
    }

    /// Fire-and-forget throwaway inference that pages the model back in while
    /// the user is still talking, so the real request doesn't stall on it.
    /// Safe to call from the main queue; returns immediately. No-op when the
    /// model was used recently enough to still be wired — see `shouldWarmUp`.
    /// Returns whether a warm-up was actually started, for the log line that
    /// pairs it with the transcription it was meant to speed up.
    @discardableResult
    func warmUp(afterSeconds threshold: TimeInterval) -> Bool {
        let idle = secondsSinceCompute
        guard shouldWarmUp(idleSeconds: idle, warmUpAfterSeconds: threshold) else { return false }

        stateLock.lock()
        if warmUpInFlight { stateLock.unlock(); return false }
        warmUpInFlight = true
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                stateLock.lock(); warmUpInFlight = false; stateLock.unlock()
            }
            let wav = logFile.deletingLastPathComponent().appendingPathComponent("warmup.wav")
            guard (try? silentWavData(seconds: 1.0, sampleRate: 16000).write(to: wav)) != nil else {
                log("Warm-up skipped: could not write \(wav.lastPathComponent).")
                return
            }
            let started = Date()
            let ok = performInference(wav: wav, language: "en", verboseJSON: false) != nil
            log(String(format: "Warm-up ping after %.0fs idle %@ in %.2fs.",
                       idle, ok ? "succeeded" : "failed", Date().timeIntervalSince(started)))
            try? FileManager.default.removeItem(at: wav)
        }
        return true
    }

    func stop() {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: pidFileURL)
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

    /// Kills the server we recorded in the PID file, if it is still ours.
    ///
    /// Deliberately narrow: a previous version killed whatever held the port,
    /// which could take out an unrelated dev server sharing the number. A PID
    /// reused by another process is left alone — `comm` tells them apart.
    private func killStale() {
        guard let raw = try? String(contentsOf: pidFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(raw), pid > 0 else { return }
        if command(of: pid)?.contains("whisper-server") == true {
            log("Stopping whisper-server left over from the previous run (pid \(pid)).")
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// The executable name `ps` reports for `pid`, nil when there is no such process.
    private func command(of pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == false ? out : nil
    }

    /// Synchronous call to /inference. The language strategy comes from
    /// `languagePlan` — see docs/superpowers/specs/2026-07-29-language-pinning-design.md.
    /// Returns nil on any failure (caller falls back to whisper-cli).
    func transcribe(wav: URL, pinnedLanguages: [String] = [], forcePrimary: Bool = false, maxSegmentChars: Int = -1) -> String? {
        switch languagePlan(pinned: pinnedLanguages, forcePrimary: forcePrimary) {
        case .autoDetect:
            return performInference(wav: wav, language: "auto", verboseJSON: false, maxSegmentChars: maxSegmentChars)?.text

        case .forced(let primary):
            return performInference(wav: wav, language: primary, verboseJSON: false, maxSegmentChars: maxSegmentChars)?.text

        case .autoDetectWithPinning(let pinned):
            guard let first = performInference(wav: wav, language: "auto", verboseJSON: true, maxSegmentChars: maxSegmentChars) else { return nil }
            guard let probabilities = first.languageProbabilities,
                  let pinnedWinner = pickPinnedLanguage(probabilities: probabilities, pinned: pinned)
            else {
                return first.text
            }
            log("Language pinning: global auto-detect disagreed with pinned set \(pinned); retrying forced to \(pinnedWinner).")
            guard let retry = performInference(wav: wav, language: pinnedWinner, verboseJSON: false, maxSegmentChars: maxSegmentChars) else {
                log("Language pinning retry failed; using original (possibly wrong-language) transcript.")
                return first.text
            }
            return retry.text
        }
    }

    private struct InferenceResult {
        let text: String
        let languageProbabilities: [String: Double]?
    }

    /// Segment shape sent with every request.
    ///
    /// whisper-server's own defaults are wrong for dictation: `server.cpp` maps
    /// `max_len 0` to a hard 60-character wrap with `split_on_word false`, so
    /// every ~60 characters becomes a new segment — and segments are emitted one
    /// per line. That is what puts a line break in the middle of a dictated
    /// sentence and can cut a word in half (`it` / `'s`).
    ///
    /// `-1` means "no wrapping": `whisper_wrap_segment` only runs when
    /// `max_len > 0`. `split_on_word` keeps breaks at word boundaries for users
    /// who do ask for a length limit.
    ///
    /// One synchronous multipart POST to /inference. Call from a background queue.
    private func performInference(wav: URL, language: String, verboseJSON: Bool, maxSegmentChars: Int = -1) -> InferenceResult? {
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
        appendField("response_format", verboseJSON ? "verbose_json" : "text")
        appendField("language", language)
        appendField("temperature", "0.0")
        appendField("max_len", "\(maxSegmentChars)")
        appendField("split_on_word", "true")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var result: InferenceResult?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { self.log("whisper-server request failed: \(error.localizedDescription)"); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                self.log("whisper-server bad response: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            if verboseJSON {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    self.log("whisper-server verbose_json response missing text field")
                    return
                }
                result = InferenceResult(text: text, languageProbabilities: json["language_probabilities"] as? [String: Double])
            } else {
                guard let text = String(data: data, encoding: .utf8) else {
                    self.log("whisper-server response not valid UTF-8")
                    return
                }
                result = InferenceResult(text: text, languageProbabilities: nil)
            }
        }.resume()
        semaphore.wait()
        if result != nil { noteCompute() }
        return result
    }
}
