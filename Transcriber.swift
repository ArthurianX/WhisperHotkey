import Foundation

/// Where whisper.cpp lives and which model to use.
///
/// Centralised so a missing build or model is reported once at launch instead of
/// surfacing as a bare "Transcription failed" after the user has already spoken.
struct WhisperInstall {
    let root: URL
    let modelFileName: String

    var cliURL: URL { root.appendingPathComponent("build/bin/whisper-cli") }
    var serverURL: URL { root.appendingPathComponent("build/bin/whisper-server") }
    var modelFile: URL { root.appendingPathComponent("models/\(modelFileName)") }

    /// Human-readable list of what is not there, empty when everything is.
    var missingParts: [String] {
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.fileExists(atPath: cliURL.path) { missing.append("whisper-cli at \(cliURL.path)") }
        if !fm.fileExists(atPath: modelFile.path) { missing.append("model at \(modelFile.path)") }
        return missing
    }

    var isUsable: Bool { missingParts.isEmpty }
}

/// Turns a WAV into text.
protocol Transcriber {
    func transcribe(wav: URL, config: OverlayConfig) -> String?
}

/// The resident `whisper-server` path.
final class ServerTranscriber: Transcriber {
    private let server: WhisperServer

    init(server: WhisperServer) { self.server = server }

    func transcribe(wav: URL, config: OverlayConfig) -> String? {
        server.transcribe(wav: wav, pinnedLanguages: config.pinnedLanguages, forcePrimary: config.forcePrimaryLanguage)
    }
}

/// The original path: one `whisper-cli` process per dictation.
struct WhisperCLITranscriber: Transcriber {
    let install: WhisperInstall
    let transcriptBase: URL
    let logFile: URL
    let log: (String) -> Void

    func transcribe(wav: URL, config: OverlayConfig) -> String? {
        let fm = FileManager.default
        try? fm.removeItem(at: transcriptBase.appendingPathExtension("txt"))

        let process = Process()
        process.currentDirectoryURL = install.root
        process.executableURL = install.cliURL
        process.arguments = [
            "-m", install.modelFile.path,
            "-f", wav.path,
            "-otxt",
            "-of", transcriptBase.path,
            "-nt",
            "-np",
            "-l", CLILanguageSetting(pinned: config.pinnedLanguages, forcePrimary: config.forcePrimaryLanguage)
        ]

        let logHandle = Self.openAppendHandle(for: logFile)
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
              let transcript = try? String(contentsOf: transcriptBase.appendingPathExtension("txt"), encoding: .utf8)
        else {
            log("whisper-cli failed with status \(process.terminationStatus).")
            return nil
        }
        return transcript
    }

    /// Appends to `url`, creating it first. nil on any failure, which leaves the
    /// child process with no redirect rather than a broken one.
    private static func openAppendHandle(for url: URL) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// Server when it is running, `whisper-cli` otherwise — and also as the rescue
/// when the server answers with an error. Split out of the controller so the
/// fallback decision is a type, not a branch nobody can test.
final class TranscribingPipeline: Transcriber {
    private let server: Transcriber?
    private let cli: Transcriber
    private let log: (String) -> Void
    /// Called on the caller's queue when the server failed and should be restarted.
    private let onServerFailure: (() -> Void)?

    init(server: Transcriber?, cli: Transcriber, log: @escaping (String) -> Void, onServerFailure: (() -> Void)? = nil) {
        self.server = server
        self.cli = cli
        self.log = log
        self.onServerFailure = onServerFailure
    }

    func transcribe(wav: URL, config: OverlayConfig) -> String? {
        if let server {
            if let text = server.transcribe(wav: wav, config: config) { return text }
            log("whisper-server unavailable; falling back to whisper-cli.")
            onServerFailure?()
        }
        return cli.transcribe(wav: wav, config: config)
    }
}
