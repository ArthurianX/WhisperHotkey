import AppKit

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

/// User-editable settings for the countdown overlay, loaded from `config.json`.
/// Any missing or malformed key falls back to the default value below.
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

    static let path = URL(fileURLWithPath: "/Users/arthur/whisper-hotkey/config.json")

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

    static func load(from url: URL = OverlayConfig.path) -> OverlayConfig {
        var config = OverlayConfig()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
            if let v = g["style"] as? String { config.glassStyle = v }
            if let v = g["cornerRadius"] as? Double { config.cornerRadius = CGFloat(v) }
            if let v = g["width"] as? Double { config.width = CGFloat(v) }
            if let v = g["height"] as? Double { config.height = CGFloat(v) }
            config.tintColorHex = g["tintColorHex"] as? String
            config.fillColorHex = g["fillColorHex"] as? String
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
        return config
    }

    static func writeDefaultIfMissing() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        let defaults = """
        {
          "countdown": {
            "shortWordMax": 8,
            "mediumWordMax": 25,
            "shortSeconds": 3,
            "mediumSeconds": 4,
            "longSeconds": 5
          },
          "messages": {
            "titleFormat": "Submitting in {seconds}s",
            "cancelHint": "press Esc to cancel"
          },
          "glass": {
            "style": "regular",
            "cornerRadius": 20,
            "width": 360,
            "height": 120,
            "tintColorHex": null,
            "fillColorHex": null
          },
          "server": { "enabled": true, "port": 8642, "warmUpAfterSeconds": 120 },
          "submitKeys": { "default": "enter" },
          "pinnedLanguages": []
        }
        """
        try? defaults.write(to: path, atomically: true, encoding: .utf8)
    }
}
