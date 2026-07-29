import CoreGraphics
import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition { print("PASS \(label)") } else { print("FAIL \(label)"); failures += 1 }
}

// --- SubmitChord.parse ---
expect(SubmitChord.parse("enter") == SubmitChord(keyCode: 36, flags: [], display: "↩"), "plain enter")
expect(SubmitChord.parse("return")?.keyCode == 36, "return alias")
expect(SubmitChord.parse("cmd+enter") == SubmitChord(keyCode: 36, flags: .maskCommand, display: "⌘↩"), "cmd+enter")
expect(SubmitChord.parse("CMD+Enter")?.display == "⌘↩", "case-insensitive")
expect(SubmitChord.parse(" shift + enter ")?.display == "⇧↩", "whitespace tolerated")
expect(SubmitChord.parse("ctrl+opt+shift+cmd+enter")?.display == "⌃⌥⇧⌘↩", "all modifiers, canonical order")
expect(SubmitChord.parse("alt+enter")?.flags == .maskAlternate, "alt alias for opt")
expect(SubmitChord.parse("cmd+f5") == nil, "unknown key rejected")
expect(SubmitChord.parse("bogus") == nil, "garbage rejected")
expect(SubmitChord.parse("") == nil, "empty rejected")
expect(SubmitChord.parse("cmd+") == nil, "trailing plus rejected")
expect(SubmitChord.enter == SubmitChord(keyCode: 36, flags: [], display: "↩"), "enter constant")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL TESTS PASSED")
