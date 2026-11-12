import Foundation

/// One append-only log for the whole app: one file to read, one place to cap
/// the growth. Rewrites rotate into a single `.old` generation past `maxBytes`.
///
/// Writes are serialised on a private queue so inference threads, the warm-up
/// thread and the main thread can all log without interleaving partial lines.
final class Logger {
    static let shared = Logger(fileURL: RuntimePaths.runtimeDir.appendingPathComponent("whisper-hotkey.log"))

    private let fileURL: URL
    private let queue = DispatchQueue(label: "whisper-hotkey.log")
    private static let maxBytes = 1_000_000

    init(fileURL: URL) { self.fileURL = fileURL }

    var path: String { fileURL.path }

    func log(_ message: String) {
        queue.async { Self.append(message, to: self.fileURL, maxBytes: Self.maxBytes) }
    }

    private static func append(_ message: String, to fileURL: URL, maxBytes: Int) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes {
            let rotated = URL(fileURLWithPath: fileURL.path + ".old")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
