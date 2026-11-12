import AppKit

/// Pasteboard ownership.
///
/// A dictation writes the transcript to the clipboard, which otherwise eats
/// whatever the user had copied. `restoreIfUntouched` puts it back once the
/// paste has been delivered — unless the user copied something in the meantime,
/// in which case their copy wins and we leave it alone.
enum Clipboard {
    static func currentString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func setString(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Restores `previous` only while the pasteboard still holds `ours`.
    static func restoreIfUntouched(previous: String?, ours: String) {
        guard let previous, currentString() == ours else { return }
        setString(previous)
    }
}
