import AppKit
import CoreGraphics

/// Diagnostics for the standing bug where, after the machine has been up for a
/// while, neither overlay composites any more: `orderFrontRegardless()` leaves
/// `isVisible == false`, yet timers, clipboard and CGEvent posting all keep
/// working, and it stays that way for days until the app is relaunched.
///
/// The earlier round of logging established it is app-wide (not specific to the
/// countdown) and not caused by usage accumulation. `windowNumber` is the datum
/// that splits the remaining candidates: 0 means the window server refused to
/// back the window at all, > 0 means AppKit declined to order an existing
/// window in.
enum OverlayDebug {
    static let launchedAt = Date()

    private static let logFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("whisper-hotkey", isDirectory: true)
        .appendingPathComponent("whisper-hotkey.log")

    static func log(_ message: String) {
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] [overlay-debug] \(message)\n".data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    /// True when our login session owns the console — a window server that has
    /// handed the console to another session will not show our windows.
    private static var onConsole: String {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return "no-session" }
        let value = session["kCGSSessionOnConsoleKey"] as? Bool
        return value.map(String.init) ?? "unknown"
    }

    /// Everything that could plausibly explain a panel not appearing, on one line.
    static func probe(_ label: String, _ panel: NSPanel) -> String {
        let uptime = Date().timeIntervalSince(launchedAt)
        return String(
            format: "%@: isVisible=%@ windowNumber=%d alpha=%.2f onActiveSpace=%@ "
                + "panelScreen=%@ panelOcclusion=%d | appHidden=%@ appActive=%@ appRunning=%@ "
                + "appWindows=%d appOcclusion=%d | screens=%d onConsole=%@ appUptime=%.0fs",
            label,
            String(panel.isVisible),
            panel.windowNumber,
            panel.alphaValue,
            String(panel.isOnActiveSpace),
            panel.screen?.frame.debugDescription ?? "nil",
            panel.occlusionState.rawValue,
            String(NSApp.isHidden),
            String(NSApp.isActive),
            String(NSApp.isRunning),
            NSApp.windows.count,
            NSApp.occlusionState.rawValue,
            NSScreen.screens.count,
            onConsole,
            uptime
        )
    }

    private static var baselineLogged: Set<String> = []

    /// Orders `panel` front and, if that silently fails, retries once and
    /// reports whether the retry took. On the happy path it logs only the
    /// first show of each overlay per launch, as a healthy baseline to compare
    /// against; a `FAILED` line means the bug just reproduced.
    static func orderFrontLogging(_ panel: NSPanel, _ label: String) {
        // A hidden app cannot order any window in. We unhide once at launch,
        // but ⌘⌥H ("Hide Others") in any other app re-hides us at any time.
        if NSApp.isHidden {
            log("\(label): NSApp was hidden; unhiding before ordering front.")
            NSApp.unhideWithoutActivation()
        }
        panel.orderFrontRegardless()
        guard !panel.isVisible else {
            if baselineLogged.insert(label).inserted {
                log(probe("\(label) first show OK", panel))
            }
            return
        }

        log("\(label) FAILED to become visible. \(probe("state", panel))")
        panel.setIsVisible(true)
        panel.orderFrontRegardless()
        log("\(label) retry \(panel.isVisible ? "recovered" : "still failed"). \(probe("state", panel))")
    }
}
