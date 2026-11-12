import Carbon
import Foundation

/// The hold-to-dictate hotkey: one key plus Carbon modifiers, parsed from
/// config so the binding is not welded into the binary.
struct HotKey: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String

    static let `default` = HotKey(
        keyCode: UInt32(kVK_ANSI_R),
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey),
        display: "⌃⌥⌘R"
    )

    /// `key` is "r", "f5", "space", "enter"…; `modifiers` are cmd/opt/ctrl/shift
    /// with command/alt/option/control aliases. nil for anything unbindable —
    /// fn cannot be used with `RegisterEventHotKey`, so it is not accepted.
    static func parse(key: String, modifiers: [String]) -> HotKey? {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmedKey.isEmpty == false, let (keyCode, glyph) = virtualKey(for: trimmedKey) else { return nil }

        let wanted = Set(modifiers.map { Self.canonicalModifier($0) })
        var carbon: UInt32 = 0
        var glyphs = ""
        // Canonical glyph order, matching SubmitChord's display.
        for (name, flag, glyph) in [
            ("ctrl", controlKey, "⌃"),
            ("opt", optionKey, "⌥"),
            ("shift", shiftKey, "⇧"),
            ("cmd", cmdKey, "⌘"),
        ] {
            if wanted.contains(name) {
                carbon |= UInt32(flag)
                glyphs += glyph
            }
        }
        guard wanted.subtracting(["ctrl", "opt", "shift", "cmd"]).isEmpty else { return nil }
        return HotKey(keyCode: keyCode, carbonModifiers: carbon, display: glyphs + glyph)
    }

    private static func canonicalModifier(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "cmd", "command": return "cmd"
        case "opt", "alt", "option": return "opt"
        case "ctrl", "control": return "ctrl"
        case "shift": return "shift"
        default: return raw.lowercased()
        }
    }

    /// Virtual key code plus the glyph to show in the countdown overlay.
    /// Uses Carbon's own constants, so the codes are correct whatever the
    /// underlying layout numbers turn out to be.
    private static func virtualKey(for name: String) -> (UInt32, String)? {
        let letters: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "s": UInt32(kVK_ANSI_S), "d": UInt32(kVK_ANSI_D),
            "f": UInt32(kVK_ANSI_F), "h": UInt32(kVK_ANSI_H), "g": UInt32(kVK_ANSI_G),
            "z": UInt32(kVK_ANSI_Z), "x": UInt32(kVK_ANSI_X), "c": UInt32(kVK_ANSI_C),
            "v": UInt32(kVK_ANSI_V), "b": UInt32(kVK_ANSI_B), "q": UInt32(kVK_ANSI_Q),
            "w": UInt32(kVK_ANSI_W), "e": UInt32(kVK_ANSI_E), "r": UInt32(kVK_ANSI_R),
            "y": UInt32(kVK_ANSI_Y), "t": UInt32(kVK_ANSI_T), "o": UInt32(kVK_ANSI_O),
            "u": UInt32(kVK_ANSI_U), "i": UInt32(kVK_ANSI_I), "p": UInt32(kVK_ANSI_P),
            "m": UInt32(kVK_ANSI_M), "l": UInt32(kVK_ANSI_L), "n": UInt32(kVK_ANSI_N),
            "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K),
        ]
        if let code = letters[name] { return (code, name.uppercased()) }

        let digits: [String: UInt32] = [
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9),
        ]
        if let code = digits[name] { return (code, name) }

        let functionKeys: [String: UInt32] = [
            "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3),
            "f4": UInt32(kVK_F4), "f5": UInt32(kVK_F5), "f6": UInt32(kVK_F6),
            "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8), "f9": UInt32(kVK_F9),
            "f10": UInt32(kVK_F10), "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12),
        ]
        if let code = functionKeys[name] { return (code, name.uppercased()) }

        switch name {
        case "space": return (UInt32(kVK_Space), "␣")
        case "enter", "return": return (UInt32(kVK_Return), "↩")
        case "tab": return (UInt32(kVK_Tab), "⇥")
        case "delete", "backspace": return (UInt32(kVK_Delete), "⌫")
        case "escape", "esc": return (UInt32(kVK_Escape), "⎋")
        case "left": return (UInt32(kVK_LeftArrow), "←")
        case "right": return (UInt32(kVK_RightArrow), "→")
        case "up": return (UInt32(kVK_UpArrow), "↑")
        case "down": return (UInt32(kVK_DownArrow), "↓")
        default: return nil
        }
    }
}
