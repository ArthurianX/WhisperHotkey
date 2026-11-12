import AppKit
import CoreGraphics
import Foundation

/// Two things live here, and only one of them is diagnostics.
///
/// 1. **Functional** (`orderFront`): a hidden app cannot order any window in, and
///    ⌘⌥H in another app re-hides us at any time — so unhiding and retrying
///    before showing a panel is behaviour the overlays depend on, not debugging.
/// 2. **Diagnostics** (`OverlayDebug.log`/`probe`): the standing bug where, after
///    the machine has been up for a while, `orderFrontRegardless()` leaves
///    `isVisible == false` while timers, clipboard and CGEvent posting keep
///    working. `windowNumber` is the datum that splits the remaining
///    candidates: 0 means the window server refused to back the window at all,
///    > 0 means AppKit declined to order an existing window in.
///
/// Diagnostics are off unless `debug.overlayDiagnostics` is set, so a working
/// app writes nothing but real events to the log.
enum OverlayDebug {
    /// Set once at launch from the config; the failure path logs regardless.
    static var enabled = false

    static let launchedAt = Date()

    private static var baselineLogged: Set<String> = []

    /// Orders `panel` front, unhiding the app first if something hid it, and
    /// retries once when the order silently failed.
    static func orderFront(_ panel: NSPanel, label: String) {
        if NSApp.isHidden {
            log("\(label): NSApp was hidden; unhiding before ordering front.")
            NSApp.unhideWithoutActivation()
        }
        panel.orderFrontRegardless()
        guard !panel.isVisible else {
            if enabled, baselineLogged.insert(label).inserted {
                log(probe("\(label) first show OK", panel))
            }
            return
        }

        log("\(label) FAILED to become visible. \(probe("state", panel))")
        panel.setIsVisible(true)
        panel.orderFrontRegardless()
        log("\(label) retry \(panel.isVisible ? "recovered" : "still failed"). \(probe("state", panel))")
    }

    static func log(_ message: String) {
        Logger.shared.log("[overlay] \(message)")
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
}
