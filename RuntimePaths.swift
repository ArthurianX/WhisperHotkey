import Foundation

/// Everything the app reads and writes, derived from `$HOME` and the binary's
/// own location so a checkout can live anywhere and still work.
enum RuntimePaths {
    /// Logs, in-flight recordings and transcripts. `~/Library/Caches` is the
    /// right place for regenerable files; the audio is deleted after each
    /// dictation rather than left for the OS to clean up eventually.
    static let runtimeDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let parent = caches ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return parent.appendingPathComponent("whisper-hotkey", isDirectory: true)
    }()

    /// The directory the checkout lives in, derived from the executable at
    /// `<checkout>/WhisperHotkey.app/Contents/MacOS/WhisperHotkey`.
    static let checkoutDir: URL = {
        var url = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        if url.pathComponents.count > 4 {
            url = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return url
    }()

    /// Settings file, first match wins:
    /// `$WHISPER_HOTKEY_CONFIG`, `~/.config/whisper-hotkey/config.json`,
    /// then `config.json` beside the checkout — the developer's path, which is
    /// also how this app worked before, so an existing file keeps working.
    static let configFile: URL = {
        let fm = FileManager.default
        if let raw = ProcessInfo.processInfo.environment["WHISPER_HOTKEY_CONFIG"], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let xdg = home.appendingPathComponent(".config/whisper-hotkey/config.json")
        if fm.fileExists(atPath: xdg.path) { return xdg }
        let sibling = checkoutDir.appendingPathComponent("config.json")
        if fm.fileExists(atPath: sibling.path) { return sibling }
        return xdg
    }()

    /// Where `writeDefaultIfMissing` puts a first-run config.
    static let writableConfigFile: URL = configFile
}
