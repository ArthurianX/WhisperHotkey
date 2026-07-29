import CoreGraphics

/// A parsed submit key chord, e.g. "cmd+enter" → ⌘↩.
struct SubmitChord: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let display: String

    static let enter = SubmitChord(keyCode: 36, flags: [], display: "↩")

    /// Parses strings like "enter", "cmd+enter", "ctrl+opt+enter".
    /// Modifiers: cmd/command, shift, opt/alt/option, ctrl/control.
    /// Keys: enter/return. Returns nil for anything unrecognized.
    static func parse(_ raw: String) -> SubmitChord? {
        let tokens = raw.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyToken = tokens.last, !keyToken.isEmpty else { return nil }

        let keyCode: CGKeyCode
        let keySymbol: String
        switch keyToken {
        case "enter", "return": keyCode = 36; keySymbol = "↩"
        default: return nil
        }

        var flags: CGEventFlags = []
        for token in tokens.dropLast() {
            switch token {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: return nil
            }
        }

        var symbols = ""
        if flags.contains(.maskControl) { symbols += "⌃" }
        if flags.contains(.maskAlternate) { symbols += "⌥" }
        if flags.contains(.maskShift) { symbols += "⇧" }
        if flags.contains(.maskCommand) { symbols += "⌘" }
        return SubmitChord(keyCode: keyCode, flags: flags, display: symbols + keySymbol)
    }
}
