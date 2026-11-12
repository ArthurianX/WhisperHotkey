import AppKit
import CoreGraphics

/// System-wide keystrokes: the paste, and the auto-submit chord.
///
/// Every entry point answers honestly. Accessibility permission can be missing,
/// and callers must not report success when nothing was injected.
struct TextInjector {
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// ⌘V into whatever currently has focus.
    @discardableResult
    func paste() -> Bool { post(keyCode: 9, flags: .maskCommand) }

    @discardableResult
    func send(_ chord: SubmitChord) -> Bool { post(keyCode: chord.keyCode, flags: chord.flags) }

    private func post(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard isTrusted else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
        return true
    }
}
