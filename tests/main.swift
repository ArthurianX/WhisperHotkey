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
  "server": { "enabled": false, "port": 9999, "warmUpAfterSeconds": 45 },
  "submitKeys": { "default": "enter", "com.tinyspeck.slackmacgap": "cmd+enter", "com.broken.app": "cmd+f13" },
  "messages": { "titleFormat": "Submitting ({key}) in {seconds}s" }
}
""".write(to: tmpConfig, atomically: true, encoding: .utf8)

let cfg = OverlayConfig.load(from: tmpConfig)
expect(cfg.serverEnabled == false, "server.enabled parsed")
expect(cfg.serverPort == 9999, "server.port parsed")
expect(cfg.serverWarmUpAfterSeconds == 45, "server.warmUpAfterSeconds parsed")
expect(cfg.submitChord(forBundleID: "com.tinyspeck.slackmacgap").display == "⌘↩", "slack chord")
expect(cfg.submitChord(forBundleID: "org.mozilla.firefox") == .enter, "unmapped app falls back to default")
expect(cfg.submitChord(forBundleID: nil) == .enter, "nil bundle id falls back to default")
expect(cfg.submitChord(forBundleID: "com.broken.app") == .enter, "malformed chord falls back to enter")
expect(cfg.title(seconds: 3, keyDisplay: "⌘↩") == "Submitting (⌘↩) in 3s", "{key} and {seconds} replaced")

let defaults = OverlayConfig.load(from: URL(fileURLWithPath: "/nonexistent.json"))
expect(defaults.serverEnabled == true, "default server.enabled true")
expect(defaults.serverPort == 8642, "default server.port 8642")
expect(defaults.serverWarmUpAfterSeconds == 120, "default warm-up threshold sits under ggml's 180s residency keep-alive")
expect(defaults.submitChord(forBundleID: "anything") == .enter, "default submit is enter")
expect(defaults.title(seconds: 5) == "Submitting in 5s", "default titleFormat has no {key}")

// --- OverlayConfig.pinnedLanguages ---
let tmpPinnedConfig = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-pinned-config.json")
try! """
{ "pinnedLanguages": ["ro", "en"] }
""".write(to: tmpPinnedConfig, atomically: true, encoding: .utf8)

let pinnedCfg = OverlayConfig.load(from: tmpPinnedConfig)
expect(pinnedCfg.pinnedLanguages == ["ro", "en"], "pinnedLanguages parsed from config")
expect(defaults.pinnedLanguages == [], "default pinnedLanguages is empty (pinning disabled)")

// --- pickPinnedLanguage ---
expect(pickPinnedLanguage(probabilities: ["ro": 0.9, "en": 0.05, "ru": 0.9], pinned: []) == nil, "empty pinned list disables pinning")
expect(pickPinnedLanguage(probabilities: ["ro": 0.9, "en": 0.05], pinned: ["ro"]) == nil, "single-entry pinned list disables pinning")
expect(pickPinnedLanguage(probabilities: ["ro": 0.9, "en": 0.05], pinned: ["ro", "en"]) == nil, "global winner already matches pinned winner")
expect(pickPinnedLanguage(probabilities: ["ru": 0.6, "ro": 0.3, "en": 0.1], pinned: ["ro", "en"]) == "ro", "global winner is a third language; retries to higher-scoring pinned language")
expect(pickPinnedLanguage(probabilities: ["fr": 0.5, "en": 0.4, "ro": 0.1], pinned: ["ro", "en"]) == "en", "global winner is a third language; retries to en when en scores higher than ro")
expect(pickPinnedLanguage(probabilities: ["ru": 0.6, "ro": 0.3], pinned: ["ro", "en"]) == "ro", "missing pinned entry (en absent) treated as 0")
expect(pickPinnedLanguage(probabilities: ["ru": 1.0], pinned: ["ro", "en"]) == "ro", "both pinned entries missing; ro wins tie as first in pinned order")
expect(pickPinnedLanguage(probabilities: [:], pinned: ["ro", "en"]) == nil, "empty probabilities dict; nothing to compare, no retry")

// --- shouldWarmUp ---
expect(shouldWarmUp(idleSeconds: 300, warmUpAfterSeconds: 120) == true, "long idle warrants a warm-up")
expect(shouldWarmUp(idleSeconds: 30, warmUpAfterSeconds: 120) == false, "recent activity needs no warm-up")
expect(shouldWarmUp(idleSeconds: 120, warmUpAfterSeconds: 120) == true, "idle exactly at threshold warms up")
expect(shouldWarmUp(idleSeconds: 99999, warmUpAfterSeconds: 0) == false, "zero threshold disables warm-up")
expect(shouldWarmUp(idleSeconds: 99999, warmUpAfterSeconds: -1) == false, "negative threshold disables warm-up")

// --- silentWavData ---
func le16(_ d: Data, _ offset: Int) -> UInt16 {
    UInt16(d[d.startIndex + offset]) | UInt16(d[d.startIndex + offset + 1]) << 8
}
func le32(_ d: Data, _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + offset + $1]) << (8 * UInt32($1)) }
}
func ascii(_ d: Data, _ offset: Int) -> String {
    String(decoding: d[(d.startIndex + offset)..<(d.startIndex + offset + 4)], as: UTF8.self)
}

let wav = silentWavData(seconds: 1.0, sampleRate: 16000)
expect(wav.count == 44 + 32000, "1s of 16kHz mono 16-bit silence is a 44-byte header plus 32000 bytes")
expect(ascii(wav, 0) == "RIFF", "RIFF magic")
expect(ascii(wav, 8) == "WAVE", "WAVE format")
expect(ascii(wav, 12) == "fmt ", "fmt chunk")
expect(ascii(wav, 36) == "data", "data chunk")
expect(le32(wav, 4) == UInt32(36 + 32000), "RIFF size is 36 + payload")
expect(le32(wav, 16) == 16, "PCM fmt chunk is 16 bytes")
expect(le16(wav, 20) == 1, "format tag 1 = uncompressed PCM")
expect(le16(wav, 22) == 1, "mono")
expect(le32(wav, 24) == 16000, "16kHz sample rate, matching what the recorder produces")
expect(le32(wav, 28) == 32000, "byte rate = rate * channels * 2")
expect(le16(wav, 32) == 2, "block align = channels * 2")
expect(le16(wav, 34) == 16, "16-bit samples")
expect(le32(wav, 40) == 32000, "data size matches payload")
expect(wav[(wav.startIndex + 44)...].allSatisfy { $0 == 0 }, "payload is silence")
expect(silentWavData(seconds: 0.5, sampleRate: 16000).count == 44 + 16000, "half a second is half the payload")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL TESTS PASSED")
