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

// --- OverlayConfig ---
let tmpConfig = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-config.json")
try! """
{
  "server": { "enabled": false, "port": 9999 },
  "submitKeys": { "default": "enter", "com.tinyspeck.slackmacgap": "cmd+enter", "com.broken.app": "cmd+f13" },
  "messages": { "titleFormat": "Submitting ({key}) in {seconds}s" }
}
""".write(to: tmpConfig, atomically: true, encoding: .utf8)

let cfg = OverlayConfig.load(from: tmpConfig)
expect(cfg.serverEnabled == false, "server.enabled parsed")
expect(cfg.serverPort == 9999, "server.port parsed")
expect(cfg.submitChord(forBundleID: "com.tinyspeck.slackmacgap").display == "⌘↩", "slack chord")
expect(cfg.submitChord(forBundleID: "org.mozilla.firefox") == .enter, "unmapped app falls back to default")
expect(cfg.submitChord(forBundleID: nil) == .enter, "nil bundle id falls back to default")
expect(cfg.submitChord(forBundleID: "com.broken.app") == .enter, "malformed chord falls back to enter")
expect(cfg.title(seconds: 3, keyDisplay: "⌘↩") == "Submitting (⌘↩) in 3s", "{key} and {seconds} replaced")

let defaults = OverlayConfig.load(from: URL(fileURLWithPath: "/nonexistent.json"))
expect(defaults.serverEnabled == true, "default server.enabled true")
expect(defaults.serverPort == 8642, "default server.port 8642")
expect(defaults.submitChord(forBundleID: "anything") == .enter, "default submit is enter")
expect(defaults.title(seconds: 5) == "Submitting in 5s", "default titleFormat has no {key}")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL TESTS PASSED")
