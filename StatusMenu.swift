import AppKit

/// Menu-bar presence: what the app is doing right now, a pause switch, a config
/// reload, and shortcuts to the two files worth reaching for. Without this,
/// operating the app means editing JSON in a terminal.
final class StatusMenu: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let stateItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private lazy var pauseItem = NSMenuItem(title: "Pause hotkey", action: #selector(togglePause), keyEquivalent: "")

    var onPauseToggled: ((Bool) -> Void)?
    var onReloadConfig: (() -> Void)?

    private let configURL: URL
    private let runtimeDir: URL
    private var paused = false

    init(configURL: URL, runtimeDir: URL) {
        self.configURL = configURL
        self.runtimeDir = runtimeDir
        super.init()

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "WhisperHotkey") {
                button.image = image
            } else {
                button.title = "🎙"
            }
        }

        stateItem.isEnabled = false
        pauseItem.target = self

        let menu = NSMenu()
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(item("Reload config", #selector(reloadConfig)))
        menu.addItem(item("Open settings", #selector(openConfig)))
        menu.addItem(item("Open log folder", #selector(openLogFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit WhisperHotkey", #selector(quit)))
        statusItem.menu = menu
    }

    func setState(_ text: String) {
        stateItem.title = paused ? "\(text) (paused)" : text
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseItem.title = paused ? "Resume hotkey" : "Pause hotkey"
        onPauseToggled?(paused)
    }

    @objc private func reloadConfig() { onReloadConfig?() }

    @objc private func openConfig() {
        if FileManager.default.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.open(configURL)
        } else {
            NSWorkspace.shared.open(configURL.deletingLastPathComponent())
        }
    }

    @objc private func openLogFolder() {
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(runtimeDir)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
