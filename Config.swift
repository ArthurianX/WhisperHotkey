import AppKit
import Foundation

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let val = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((val >> 24) & 0xFF) / 255
            g = CGFloat((val >> 16) & 0xFF) / 255
            b = CGFloat((val >> 8) & 0xFF) / 255
            a = CGFloat(val & 0xFF) / 255
        } else {
            r = CGFloat((val >> 16) & 0xFF) / 255
            g = CGFloat((val >> 8) & 0xFF) / 255
            b = CGFloat(val & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// User-editable settings, read from `config.json` (see `RuntimePaths.configFile`
/// for which file that is). Any missing key falls back to the default below.
///
/// A file that exists but does not parse is reported through `log` rather than
/// silently replaced by defaults — otherwise a stray comma turns the user's
/// settings off with no trace.
struct OverlayConfig {
    // countdown durations (seconds) by transcript word count
    var shortWordMax = 8
    var mediumWordMax = 25
    var shortSeconds: TimeInterval = 3
    var mediumSeconds: TimeInterval = 4
    var longSeconds: TimeInterval = 5
    // on-screen text ({seconds} is replaced with the remaining whole seconds)
    var titleFormat = "Submitting in {seconds}s"
    var cancelHint = "press Esc to cancel"
    // Liquid Glass appearance
    var glassStyle = "regular"        // "regular" or "clear"
    var cornerRadius: CGFloat = 20
    var width: CGFloat = 360
    var height: CGFloat = 120
    var tintColorHex: String? = nil   // e.g. "#3478F6"; null = no tint
    var fillColorHex: String? = nil   // progress bar fill; null = system accent
    // whisper.cpp install
    var whisperRootPath = (NSString(string: "~/whisper.cpp")).expandingTildeInPath
    var modelFileName = "ggml-large-v3-turbo.bin"
    // whisper-server (resident model)
    var serverEnabled = true
    var serverPort = 8642
    // idle seconds after which recording fires a warm-up inference; 0 disables.
    // Kept under ggml's 180s Metal residency keep-alive — see WarmUp.swift.
    var serverWarmUpAfterSeconds: TimeInterval = 120
    // bundle-id → chord string; "default" applies to unmapped apps
    var submitKeys: [String: String] = ["default": "enter"]
    // language codes (e.g. "ro", "en") to restrict auto-detect to; empty/single-entry = disabled
    var pinnedLanguages: [String] = []
    // trade the two-pass auto-detect for one pass forced to pinnedLanguages[0]
    var forcePrimaryLanguage = false
    // how whisper cuts the transcript into segments/lines
    // -1 = no length cap (whisper-server's own default is a hard 60-char wrap)
    var textMaxSegmentChars = -1
    // join whisper's segments into one line before pasting; newline is "send" in
    // many chat fields, so a segment break there submits the message early
    var joinSegments = true
    // hold-to-dictate hotkey
    var hotKeyKey = "r"
    var hotKeyModifiers = ["cmd", "opt", "ctrl"]
    // refuse to type the transcript when the focused app changed mid-dictation
    var requireUnchangedFocus = true
    // verbose overlay diagnostics; off unless someone is chasing a visibility bug
    var overlayDiagnostics = false

    static var path: URL { RuntimePaths.configFile }

    func duration(forWordCount words: Int) -> TimeInterval {
        if words <= shortWordMax { return shortSeconds }
        if words <= mediumWordMax { return mediumSeconds }
        return longSeconds
    }

    func title(seconds: Int, keyDisplay: String = "↩") -> String {
        titleFormat
            .replacingOccurrences(of: "{seconds}", with: "\(seconds)")
            .replacingOccurrences(of: "{key}", with: keyDisplay)
    }

    func submitChord(forBundleID id: String?) -> SubmitChord {
        let raw = id.flatMap { submitKeys[$0] } ?? submitKeys["default"] ?? "enter"
        return SubmitChord.parse(raw) ?? .enter
    }

    /// The registered hotkey. An unbindable config value falls back to ⌃⌥⌘R.
    func hotKey() -> HotKey {
        HotKey.parse(key: hotKeyKey, modifiers: hotKeyModifiers) ?? .default
    }

    var whisperInstall: WhisperInstall {
        WhisperInstall(root: URL(fileURLWithPath: whisperRootPath), modelFileName: modelFileName)
    }

    /// Chord strings that will never fire, e.g. `"cmd+f13"`. Reported once per
    /// load instead of once per countdown.
    var invalidSubmitKeys: [(app: String, raw: String)] {
        submitKeys.compactMap { key, raw in SubmitChord.parse(raw) == nil ? (key, raw) : nil }
    }

    /// Loads settings, reporting anything unreadable or unusable through `log`.
    /// `log` is a parameter rather than a global so tests can assert on warnings.
    static func load(from url: URL = RuntimePaths.configFile, log: ((String) -> Void)? = nil) -> OverlayConfig {
        var config = OverlayConfig()
        let warn: (String) -> Void = { message in log?(message) }

        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) {
                warn("Config at \(url.path) exists but could not be read; using defaults.")
            }
            return config
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            warn("Config at \(url.path) is not a JSON object; using defaults.")
            return config
        }

        if let c = json["countdown"] as? [String: Any] {
            if let v = c["shortWordMax"] as? Int { config.shortWordMax = v }
            if let v = c["mediumWordMax"] as? Int { config.mediumWordMax = v }
            if let v = c["shortSeconds"] as? Double { config.shortSeconds = v }
            if let v = c["mediumSeconds"] as? Double { config.mediumSeconds = v }
            if let v = c["longSeconds"] as? Double { config.longSeconds = v }
        }
        if let m = json["messages"] as? [String: Any] {
            if let v = m["titleFormat"] as? String { config.titleFormat = v }
            if let v = m["cancelHint"] as? String { config.cancelHint = v }
        }
        if let g = json["glass"] as? [String: Any] {
            if let v = g["style"] as? String {
                if v.lowercased() == "regular" || v.lowercased() == "clear" {
                    config.glassStyle = v
                } else {
                    warn("Unknown glass.style \"\(v)\"; using \"regular\".")
                }
            }
            if let v = g["cornerRadius"] as? Double { config.cornerRadius = CGFloat(v) }
            if let v = g["width"] as? Double { config.width = CGFloat(v) }
            if let v = g["height"] as? Double { config.height = CGFloat(v) }
            if let v = g["tintColorHex"] as? String, NSColor(hex: v) == nil {
                warn("Invalid glass.tintColorHex \"\(v)\"; no tint.")
            } else {
                config.tintColorHex = g["tintColorHex"] as? String
            }
            if let v = g["fillColorHex"] as? String, NSColor(hex: v) == nil {
                warn("Invalid glass.fillColorHex \"\(v)\"; using system accent.")
            } else {
                config.fillColorHex = g["fillColorHex"] as? String
            }
        }
        if let w = json["whisper"] as? [String: Any] {
            if let v = w["root"] as? String, !v.isEmpty {
                config.whisperRootPath = (NSString(string: v)).expandingTildeInPath
            }
            if let v = w["model"] as? String, !v.isEmpty { config.modelFileName = v }
        }
        if let s = json["server"] as? [String: Any] {
            if let v = s["enabled"] as? Bool { config.serverEnabled = v }
            if let v = s["port"] as? Int { config.serverPort = v }
            if let v = s["warmUpAfterSeconds"] as? Double { config.serverWarmUpAfterSeconds = v }
        }
        if let k = json["submitKeys"] as? [String: String], !k.isEmpty {
            config.submitKeys = k
        }
        if let langs = json["pinnedLanguages"] as? [String] {
            config.pinnedLanguages = langs
        }
        if let v = json["forcePrimaryLanguage"] as? Bool { config.forcePrimaryLanguage = v }
        if let t = json["text"] as? [String: Any] {
            if let v = t["maxSegmentChars"] as? Int { config.textMaxSegmentChars = v }
            if let v = t["joinSegments"] as? Bool { config.joinSegments = v }
        }
        if config.textMaxSegmentChars == 0 {
            // whisper-server rewrites max_len 0 to its own 60-character wrap —
            // the exact default that breaks words in half. Say so, and cap nothing.
            warn("text.maxSegmentChars of 0 means whisper-server's 60-character wrap; using -1 (no cap) instead.")
            config.textMaxSegmentChars = -1
        }
        if let h = json["hotkey"] as? [String: Any] {
            if let v = h["key"] as? String { config.hotKeyKey = v }
            if let v = h["modifiers"] as? [String] { config.hotKeyModifiers = v }
            if HotKey.parse(key: config.hotKeyKey, modifiers: config.hotKeyModifiers) == nil {
                warn("Unbindable hotkey \(config.hotKeyKey) + \(config.hotKeyModifiers); using ⌃⌥⌘R.")
            }
        }
        if let p = json["paste"] as? [String: Any], let v = p["requireUnchangedFocus"] as? Bool {
            config.requireUnchangedFocus = v
        }
        if let d = json["debug"] as? [String: Any], let v = d["overlayDiagnostics"] as? Bool {
            config.overlayDiagnostics = v
        }

        for (app, raw) in config.invalidSubmitKeys {
            warn("Invalid submitKeys chord \"\(raw)\" for \(app); using enter.")
        }
        if config.forcePrimaryLanguage && config.pinnedLanguages.isEmpty {
            warn("forcePrimaryLanguage is on but pinnedLanguages is empty; auto-detect stays in charge.")
        }
        return config
    }

    /// The defaults as JSON, written to the config path on first run so the
    /// user has something to edit. Built from the struct's own defaults, so the
    /// two can't drift apart.
    static func writeDefaultIfMissing(to url: URL = RuntimePaths.writableConfigFile) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let defaults = OverlayConfig()
        let json: [String: Any] = [
            "countdown": [
                "shortWordMax": defaults.shortWordMax,
                "mediumWordMax": defaults.mediumWordMax,
                "shortSeconds": defaults.shortSeconds,
                "mediumSeconds": defaults.mediumSeconds,
                "longSeconds": defaults.longSeconds,
            ],
            "messages": ["titleFormat": defaults.titleFormat, "cancelHint": defaults.cancelHint],
            "glass": [
                "style": defaults.glassStyle,
                "cornerRadius": defaults.cornerRadius,
                "width": defaults.width,
                "height": defaults.height,
                "tintColorHex": NSNull(),
                "fillColorHex": NSNull(),
            ],
            "whisper": ["root": "~/whisper.cpp", "model": defaults.modelFileName],
            "server": [
                "enabled": defaults.serverEnabled,
                "port": defaults.serverPort,
                "warmUpAfterSeconds": defaults.serverWarmUpAfterSeconds,
            ],
            "submitKeys": ["default": "enter"],
            "pinnedLanguages": [String](),
            "forcePrimaryLanguage": false,
            "text": ["maxSegmentChars": defaults.textMaxSegmentChars, "joinSegments": defaults.joinSegments],
            "hotkey": ["key": defaults.hotKeyKey, "modifiers": defaults.hotKeyModifiers],
            "paste": ["requireUnchangedFocus": true],
            "debug": ["overlayDiagnostics": false],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }
}
