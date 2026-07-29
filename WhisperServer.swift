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

    /// Synchronous call to /inference. Applies language pinning when
    /// `pinnedLanguages` has 2+ entries — see
    /// docs/superpowers/specs/2026-07-29-language-pinning-design.md.
    /// Returns nil on any failure (caller falls back to whisper-cli).
    func transcribe(wav: URL, pinnedLanguages: [String] = []) -> String? {
        let pinningEnabled = pinnedLanguages.count >= 2
        guard let first = performInference(wav: wav, language: "auto", verboseJSON: pinningEnabled) else {
            return nil
        }
        guard pinningEnabled,
              let probabilities = first.languageProbabilities,
              let pinnedWinner = pickPinnedLanguage(probabilities: probabilities, pinned: pinnedLanguages)
        else {
            return first.text
        }

        log("Language pinning: global auto-detect disagreed with pinned set \(pinnedLanguages); retrying forced to \(pinnedWinner).")
        guard let retry = performInference(wav: wav, language: pinnedWinner, verboseJSON: false) else {
            log("Language pinning retry failed; using original (possibly wrong-language) transcript.")
            return first.text
        }
        return retry.text
    }

    private struct InferenceResult {
        let text: String
        let languageProbabilities: [String: Double]?
    }

    /// One synchronous multipart POST to /inference. Call from a background queue.
    private func performInference(wav: URL, language: String, verboseJSON: Bool) -> InferenceResult? {
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
        return result
    }
}
