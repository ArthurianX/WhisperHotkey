import AppKit
import Foundation
import UserNotifications

/// User-facing notifications.
///
/// Prefers the UserNotifications framework — the app is a real bundle with an
/// identifier — and falls back to `osascript`, escaping the text so a stray
/// quote in a message can't break the AppleScript it is interpolated into.
/// Authorization is asked for once at launch and cached; until it resolves, or
/// if it comes back denied, notifications go through `osascript`.
enum Notifier {
    /// nil while the prompt is still outstanding.
    private static var alertsAllowed: Bool?
    private static var authorizationRequested = false

    static func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil, !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async {
                alertsAllowed = granted
                Logger.shared.log(granted
                    ? "Notification permission granted."
                    : "Notification permission not granted; notifications go through osascript.")
            }
        }
    }

    static func notify(title: String, body: String) {
        if alertsAllowed == true {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
                withCompletionHandler: nil
            )
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(appleScriptString(body)) with title \(appleScriptString(title))"]
        try? process.run()
    }

    /// A quoted AppleScript string literal: `\` and `"` escaped, newlines
    /// flattened so the one-line `-e` script stays one line.
    static func appleScriptString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
