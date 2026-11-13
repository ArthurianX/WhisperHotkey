import AppKit
import Carbon
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

// --- HotKey.parse ---
expect(HotKey.parse(key: "r", modifiers: ["cmd", "opt", "ctrl"]) == HotKey.default, "default hotkey ⌃⌥⌘R round-trips")
expect(HotKey.parse(key: "R", modifiers: ["Command", "Option", "Control"]) == HotKey.default, "long modifier aliases")
expect(HotKey.parse(key: "r", modifiers: ["ctrl", "cmd"])?.display == "⌃⌘R", "glyphs in canonical order regardless of config order")
expect(HotKey.parse(key: "space", modifiers: ["cmd", "shift"])?.display == "⇧⌘␣", "space key glyph")
expect(HotKey.parse(key: "f5", modifiers: ["cmd"])?.display == "⌘F5", "function key display")
expect(HotKey.parse(key: "7", modifiers: [])?.display == "7", "bare digit, no modifiers")
expect(HotKey.parse(key: "f13", modifiers: ["cmd"]) == nil, "f13 is not bindable")
expect(HotKey.parse(key: "r", modifiers: ["fn"]) == nil, "fn is rejected — RegisterEventHotKey cannot use it")
expect(HotKey.parse(key: "", modifiers: ["cmd"]) == nil, "empty key rejected")
expect(HotKey.parse(key: "r", modifiers: ["cmd", "cmd"]) == HotKey.parse(key: "r", modifiers: ["cmd"]), "duplicate modifier collapses")
expect(HotKey.parse(key: "r", modifiers: ["cmd"]) == HotKey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(cmdKey), display: "⌘R"), "single modifier is exactly cmd+R")

// --- OverlayConfig.duration ---
let durations = OverlayConfig()
expect(durations.duration(forWordCount: 1) == durations.shortSeconds, "one word is short")
expect(durations.duration(forWordCount: durations.shortWordMax) == durations.shortSeconds, "at shortWordMax still short")
expect(durations.duration(forWordCount: durations.shortWordMax + 1) == durations.mediumSeconds, "just past shortWordMax is medium")
expect(durations.duration(forWordCount: durations.mediumWordMax) == durations.mediumSeconds, "at mediumWordMax still medium")
expect(durations.duration(forWordCount: durations.mediumWordMax + 1) == durations.longSeconds, "past mediumWordMax is long")

// --- NSColor(hex:) ---
expect(NSColor(hex: "#3478F6") != nil, "6-digit hex with hash")
expect(NSColor(hex: "3478F6") != nil, "6-digit hex without hash")
expect(NSColor(hex: "3478F680") != nil, "8-digit hex carries alpha")
expect(NSColor(hex: "3478F") == nil, "5 digits rejected")
expect(NSColor(hex: "zzzzzz") == nil, "non-hex characters rejected")
expect(NSColor(hex: "") == nil, "empty rejected")

// --- OverlayConfig.load: parsing, and warnings instead of silence ---
func warnings(_ json: String, _ name: String) -> [String] {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-\(name).json")
    try! json.write(to: url, atomically: true, encoding: .utf8)
    var captured: [String] = []
    _ = OverlayConfig.load(from: url) { captured.append($0) }
    return captured
}

let tmpConfig = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-config.json")
try! """
{
  "server": { "enabled": false, "port": 9999, "warmUpAfterSeconds": 45 },
  "submitKeys": { "default": "enter", "com.tinyspeck.slackmacgap": "cmd+enter", "com.broken.app": "cmd+f13" },
  "messages": { "titleFormat": "Submitting ({key}) in {seconds}s" },
  "text": { "maxSegmentChars": 120, "joinSegments": false },
  "whisper": { "root": "~/other-whisper", "model": "custom.bin" },
  "hotkey": { "key": "h", "modifiers": ["cmd", "shift"] },
  "paste": { "requireUnchangedFocus": false },
  "debug": { "overlayDiagnostics": true },
  "forcePrimaryLanguage": true
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
expect(cfg.whisperRootPath.hasSuffix("other-whisper"), "whisper.root expanded out of ~")
expect(cfg.modelFileName == "custom.bin", "whisper.model parsed")
expect(cfg.hotKey().display == "⇧⌘H", "hotkey parsed from config")
expect(cfg.requireUnchangedFocus == false, "paste.requireUnchangedFocus parsed")
expect(cfg.overlayDiagnostics == true, "debug.overlayDiagnostics parsed")
expect(cfg.forcePrimaryLanguage == true, "forcePrimaryLanguage parsed")
expect(cfg.textMaxSegmentChars == 120, "text.maxSegmentChars parsed")
expect(cfg.joinSegments == false, "text.joinSegments parsed")
expect(cfg.invalidSubmitKeys.map { $0.app } == ["com.broken.app"], "invalid chord surfaced for reporting")
expect(warnings(try! String(contentsOf: tmpConfig), "chord-warning").contains { $0.contains("cmd+f13") },
       "invalid submitKeys chord is reported when loaded")

let defaults = OverlayConfig.load(from: URL(fileURLWithPath: "/nonexistent.json"))
expect(defaults.serverEnabled == true, "default server.enabled true")
expect(defaults.serverPort == 8642, "default server.port 8642")
expect(defaults.serverWarmUpAfterSeconds == 120, "default warm-up threshold sits under ggml's 180s residency keep-alive")
expect(defaults.submitChord(forBundleID: "anything") == .enter, "default submit is enter")
expect(defaults.title(seconds: 5) == "Submitting in 5s", "default titleFormat has no {key}")
expect(defaults.hotKey() == HotKey.default, "default hotkey is ⌃⌥⌘R")
expect(defaults.requireUnchangedFocus == true, "default focus guard is on")
expect(defaults.overlayDiagnostics == false, "default overlay diagnostics off")
expect(defaults.whisperRootPath.hasSuffix("whisper.cpp"), "default whisper root")
expect(defaults.textMaxSegmentChars == -1, "no segment cap by default — whisper-server's own default is a 60-char wrap")
expect(defaults.joinSegments == false, "segment lines are kept by default — separation on pauses is wanted, arbitrary 60-char breaks are not")
expect(OverlayConfig.load(from: URL(fileURLWithPath: "/nonexistent.json")) { _ in }.invalidSubmitKeys.isEmpty,
       "defaults contain no invalid chords")

let brokenURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-broken.json")
try! "{ \"server\": { \"port\": 9999".write(to: brokenURL, atomically: true, encoding: .utf8)
var brokenWarnings: [String] = []
let brokenCfg = OverlayConfig.load(from: brokenURL) { brokenWarnings.append($0) }
expect(brokenCfg.serverPort == 8642, "unparseable JSON falls back to defaults rather than half-applying")
expect(brokenWarnings.count == 1 && brokenWarnings[0].contains("not a JSON object"),
       "unparseable JSON is reported instead of silently ignored")

let arrayURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-array.json")
try! "[1, 2]".write(to: arrayURL, atomically: true, encoding: .utf8)
var arrayWarnings: [String] = []
_ = OverlayConfig.load(from: arrayURL) { arrayWarnings.append($0) }
expect(arrayWarnings.contains { $0.contains("not a JSON object") }, "a JSON array is reported as unusable")

let maxlenZeroURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-maxlen-zero.json")
try! "{ \"text\": { \"maxSegmentChars\": 0 } }".write(to: maxlenZeroURL, atomically: true, encoding: .utf8)
var maxlenWarnings: [String] = []
let maxlenCfg = OverlayConfig.load(from: maxlenZeroURL) { maxlenWarnings.append($0) }
expect(maxlenCfg.textMaxSegmentChars == -1, "text.maxSegmentChars 0 is replaced with no cap")
expect(maxlenWarnings.contains { $0.contains("60-character") }, "because whisper-server turns max_len 0 into its 60-character wrap")

expect(warnings("{ \"hotkey\": { \"key\": \"r\", \"modifiers\": [\"fn\"] } }", "hotkey")
    .contains { $0.contains("⌃⌥⌘R") }, "unbindable hotkey is reported and falls back")
expect(warnings("{ \"glass\": { \"style\": \"frosted\" } }", "glass")
    .contains { $0.contains("frosted") }, "unknown glass.style is reported")
expect(warnings("{ \"glass\": { \"tintColorHex\": \"nope\" } }", "tint")
    .contains { $0.contains("tintColorHex") }, "invalid tint hex is reported")
expect(warnings("{ \"forcePrimaryLanguage\": true }", "force-without-pins")
    .contains { $0.contains("pinnedLanguages") }, "forcing a primary language with nothing pinned is reported")

// --- writeDefaultIfMissing produces a config that loads back unchanged ---
let freshURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-fresh-config.json")
try? FileManager.default.removeItem(at: freshURL)
OverlayConfig.writeDefaultIfMissing(to: freshURL)
let roundTrip = OverlayConfig.load(from: freshURL)
expect(FileManager.default.fileExists(atPath: freshURL.path), "first run writes a config file")
expect(roundTrip.serverPort == OverlayConfig().serverPort, "written defaults round-trip: port")
expect(roundTrip.hotKey() == OverlayConfig().hotKey(), "written defaults round-trip: hotkey")
expect(roundTrip.titleFormat == OverlayConfig().titleFormat, "written defaults round-trip: title")
expect(roundTrip.pinnedLanguages == [], "written defaults round-trip: pinnedLanguages")
expect(roundTrip.textMaxSegmentChars == -1 && roundTrip.joinSegments == false, "written defaults round-trip: text keys")

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

// --- languagePlan / CLI -l ---
expect(languagePlan(pinned: [], forcePrimary: false) == .autoDetect, "nothing pinned: plain auto-detect")
expect(languagePlan(pinned: ["ro"], forcePrimary: false) == .autoDetect, "one pinned language: pinning needs two to compare")
expect(languagePlan(pinned: ["ro", "en"], forcePrimary: false) == .autoDetectWithPinning(pinned: ["ro", "en"]), "two pinned: auto-detect then retry")
expect(languagePlan(pinned: ["ro", "en"], forcePrimary: true) == .forced(primary: "ro"), "forcePrimary trades detection for one forced pass")
expect(languagePlan(pinned: [], forcePrimary: true) == .autoDetect, "forcePrimary with nothing pinned changes nothing")
expect(CLILanguageSetting(pinned: ["ro", "en"], forcePrimary: false) == "auto", "CLI keeps auto-detect when pinning")
expect(CLILanguageSetting(pinned: ["ro", "en"], forcePrimary: true) == "ro", "CLI forces the primary language")

// --- shouldWarmUp ---
expect(shouldWarmUp(idleSeconds: 300, warmUpAfterSeconds: 120) == true, "long idle warrants a warm-up")
expect(shouldWarmUp(idleSeconds: 30, warmUpAfterSeconds: 120) == false, "recent activity needs no warm-up")
expect(shouldWarmUp(idleSeconds: 120, warmUpAfterSeconds: 120) == true, "idle exactly at threshold warms up")
expect(shouldWarmUp(idleSeconds: 99999, warmUpAfterSeconds: 0) == false, "zero threshold disables warm-up")
expect(shouldWarmUp(idleSeconds: 99999, warmUpAfterSeconds: -1) == false, "negative threshold disables warm-up")

// --- cleanTranscript ---
expect(cleanTranscript("  hello world  ") == "hello world", "surrounding whitespace trimmed")
expect(cleanTranscript("\n\nline one\n\nline two\n") == "line one\nline two", "blank lines dropped, content lines kept in order")
expect(cleanTranscript("one\n   two   \n") == "one\ntwo", "per-line whitespace trimmed")
expect(cleanTranscript("") == "", "empty stays empty")
expect(cleanTranscript(" \n \n") == "", "whitespace-only becomes empty")
expect(cleanTranscript("Whenever I dictate, text gets\ninterrupted at some moments,\nlike you will see in this\nchat.\n", joinSegments: true)
    == "Whenever I dictate, text gets interrupted at some moments, like you will see in this chat.",
       "joining segments reflows whisper's segment lines into one line")
expect(cleanTranscript("it\n's broken\n", joinSegments: true) == "it 's broken", "joined segments are separated by a space")
expect(cleanTranscript("first\nsecond\n", joinSegments: false) == "first\nsecond", "joinSegments false keeps the segment lines")

// --- shouldAutoPaste ---
expect(shouldAutoPaste(startBundleID: "com.apple.TextEdit", currentBundleID: "com.apple.TextEdit"), "same app: paste")
expect(!shouldAutoPaste(startBundleID: "com.apple.TextEdit", currentBundleID: "com.slack.Slack"), "focus moved: do not paste")
expect(shouldAutoPaste(startBundleID: nil, currentBundleID: "com.slack.Slack"), "focus unknown at record start: paste anyway")
expect(!shouldAutoPaste(startBundleID: "com.apple.TextEdit", currentBundleID: nil), "no frontmost app now: do not paste")

// --- Notifier AppleScript escaping ---
expect(Notifier.appleScriptString("plain") == "\"plain\"", "plain text quoted")
expect(Notifier.appleScriptString("say \"hi\"") == "\"say \\\"hi\\\"\"", "inner quotes escaped")
expect(Notifier.appleScriptString("a\\b") == "\"a\\\\b\"", "backslash escaped first")
expect(Notifier.appleScriptString("line1\nline2") == "\"line1 line2\"", "newline flattened into the one-line script")

// --- RecordingOverlay.level ---
expect(RecordingOverlay.level(fromDB: 0) == 1, "0 dBFS is a full bar")
expect(RecordingOverlay.level(fromDB: -55) == 0, "at the noise floor the bar is flat")
expect(RecordingOverlay.level(fromDB: -160) == 0, "digital silence is flat")
expect(RecordingOverlay.level(fromDB: -27.5) == 0.5, "halfway between floor and ceiling is half height")
expect(RecordingOverlay.level(fromDB: 6) == 1, "above ceiling clamps rather than exceeding the panel")

// --- Clipboard ---
Clipboard.setString("first")
let captured = Clipboard.currentString()
Clipboard.setString("transcript")
Clipboard.restoreIfUntouched(previous: captured, ours: "transcript")
expect(Clipboard.currentString() == "first", "untouched pasteboard is restored after the paste")
Clipboard.setString("transcript")
Clipboard.setString("user copied something else")
Clipboard.restoreIfUntouched(previous: captured, ours: "transcript")
expect(Clipboard.currentString() == "user copied something else", "the user's newer copy is never overwritten")

// --- Logger ---
let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test.log")
try? FileManager.default.removeItem(at: logURL)
let logger = Logger(fileURL: logURL)
logger.log("first line")
logger.log("second line")
Thread.sleep(forTimeInterval: 0.2)  // writes are serialised off the calling thread
let logged = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
expect(logged.contains("first line") && logged.contains("second line"), "both lines landed in one file")
expect(logged.hasPrefix("[2"), "lines are timestamped")

// --- WhisperInstall.missingParts ---
let emptyRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-empty-install")
try? FileManager.default.removeItem(at: emptyRoot)
try! FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
let bareInstall = WhisperInstall(root: emptyRoot, modelFileName: "model.bin")
expect(bareInstall.missingParts.count == 2, "missing cli and model are both reported")
expect(!bareInstall.isUsable, "an empty root is not usable")
try! FileManager.default.createDirectory(at: emptyRoot.appendingPathComponent("build/bin"), withIntermediateDirectories: true)
try! Data([0x00]).write(to: emptyRoot.appendingPathComponent("build/bin/whisper-cli"))
try! FileManager.default.createDirectory(at: emptyRoot.appendingPathComponent("models"), withIntermediateDirectories: true)
try! Data([0x00]).write(to: emptyRoot.appendingPathComponent("models/model.bin"))
expect(WhisperInstall(root: emptyRoot, modelFileName: "model.bin").isUsable, "cli + model present: usable")

// --- TranscribingPipeline fallback ---
let wavURL = URL(fileURLWithPath: "/tmp/whisper-test-unused.wav")
struct StubTranscriber: Transcriber {
    let result: String?
    func transcribe(wav: URL, config: OverlayConfig) -> String? { result }
}
var fallbackLogs: [String] = []
var respawnCalls = 0
let serverWorks = TranscribingPipeline(
    server: StubTranscriber(result: "from server"),
    cli: StubTranscriber(result: "from cli"),
    log: { fallbackLogs.append($0) },
    onServerFailure: { respawnCalls += 1 }
)
expect(serverWorks.transcribe(wav: wavURL, config: defaults) == "from server", "server result wins when it answers")
expect(fallbackLogs.isEmpty && respawnCalls == 0, "a healthy server neither logs a fallback nor respawns")

fallbackLogs = []
let serverDown = TranscribingPipeline(
    server: StubTranscriber(result: nil),
    cli: StubTranscriber(result: "from cli"),
    log: { fallbackLogs.append($0) },
    onServerFailure: { respawnCalls += 1 }
)
expect(serverDown.transcribe(wav: wavURL, config: defaults) == "from cli", "a failed server falls back to whisper-cli")
expect(fallbackLogs.contains { $0.contains("falling back") }, "the fallback is logged")
expect(respawnCalls == 1, "the dead server is marked for respawn")

let cliOnly = TranscribingPipeline(server: nil, cli: StubTranscriber(result: "from cli"), log: { fallbackLogs.append($0) })
expect(cliOnly.transcribe(wav: wavURL, config: defaults) == "from cli", "server disabled: straight to whisper-cli")

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
