import AppKit
import Carbon

/// The controller the Carbon handler reaches. An `EventHandlerUPP` is a C
/// function pointer and cannot capture, so it goes through a global.
private var activeController: WhisperController?

func fourCharCode(_ value: String) -> OSType {
    var result: OSType = 0
    for byte in value.utf8 {
        result = (result << 8) + OSType(byte)
    }
    return result
}

private let hotKeySignature = fourCharCode("WSPR")
private let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)

private let hotKeyHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr && hotKeyID.signature == hotKeySignature && hotKeyID.id == 1 else {
        return noErr
    }

    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
        activeController?.hotkeyPressed()
    case UInt32(kEventHotKeyReleased):
        activeController?.hotkeyReleased()
    default:
        break
    }

    return noErr
}

/// App wiring: settings, permissions, hotkey registration, status item, the
/// resident server, and shutdown on SIGTERM.
///
/// Kept out of the controller so that class stays about dictation.
final class AppBootstrap: NSObject, NSApplicationDelegate {
    private let controller = WhisperController()
    private var hotKeyRef: EventHotKeyRef?
    /// The binding we last tried to install, successful or not — so a failed
    /// registration does not retry, and nag, on every single key press.
    private var desiredHotKey: HotKey?
    private var eventHandlerInstalled = false
    /// The settings that need the resident server restarted when they change.
    private struct ServerKey: Equatable {
        let enabled: Bool
        let port: Int
        let root: String
        let model: String
    }
    private var serverKey: ServerKey?
    private var statusMenu: StatusMenu?
    private var sigtermSource: DispatchSourceSignal?

    /// Entry point for `main.swift`. Never returns.
    func run() {
        activeController = controller
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The LaunchAgent starts us with `open -g`, and a hidden app cannot order
        // its overlay panels in even when it was launched hidden (`-j`), so
        // undo the hide without activating: never steal focus, always composite.
        NSApp.unhideWithoutActivation()

        OverlayConfig.writeDefaultIfMissing()
        let config = OverlayConfig.load(log: Logger.shared.log)
        OverlayDebug.enabled = config.overlayDiagnostics
        Logger.shared.log("WhisperHotkey launched (hotkey \(config.hotKey().display), config \(OverlayConfig.path.path)).")

        Notifier.requestAuthorizationIfNeeded()
        requestAccessibilityIfNeeded()
        reportMissingWhisperParts(config)

        controller.configChanged = { [weak self] newConfig in self?.applyConfig(newConfig) }
        controller.stateChanged = { [weak self] state in self?.statusMenu?.setState(state) }

        applyConfig(config)
        installStatusMenu(config: config)
        installSignalHandlers()
    }

    /// Applies a freshly loaded config: restarts the server when its settings
    /// changed, and re-binds the hotkey when the binding changed.
    private func applyConfig(_ config: OverlayConfig) {
        let key = ServerKey(
            enabled: config.serverEnabled,
            port: config.serverPort,
            root: config.whisperRootPath,
            model: config.modelFileName
        )
        if serverKey != key {
            serverKey = key
            controller.restartServer(config: config)
        }
        let hotKey = config.hotKey()
        if hotKey != desiredHotKey {
            desiredHotKey = hotKey
            if let ref = hotKeyRef {
                UnregisterEventHotKey(ref)
                hotKeyRef = nil
            }
            registerHotKey(hotKey)
        }
    }

    private func registerHotKey(_ hotKey: HotKey) {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        if !eventHandlerInstalled {
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, eventTypes.count, &eventTypes, nil, nil)
            eventHandlerInstalled = true
        }

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Logger.shared.log("Could not register hotkey \(hotKey.display); OSStatus \(status).")
            Notifier.notify(title: "Whisper", body: "Could not register \(hotKey.display) — another app may already own it.")
            return
        }
        hotKeyRef = ref
        Logger.shared.log("Hotkey bound: \(hotKey.display).")
    }

    private func installStatusMenu(config: OverlayConfig) {
        let menu = StatusMenu(configURL: OverlayConfig.path, runtimeDir: RuntimePaths.runtimeDir)
        menu.setState("Ready")
        menu.onPauseToggled = { [weak self] paused in
            self?.controller.isPaused = paused
            Logger.shared.log(paused ? "Hotkey paused." : "Hotkey resumed.")
            self?.statusMenu?.setState(paused ? "Paused" : "Ready")
        }
        menu.onReloadConfig = { [weak self] in
            guard let self else { return }
            let fresh = OverlayConfig.load(log: Logger.shared.log)
            OverlayDebug.enabled = fresh.overlayDiagnostics
            // Reload means "try again", so forget what we last bound and let
            // applyConfig re-register even if the binding looks unchanged.
            self.desiredHotKey = nil
            self.applyConfig(fresh)
            Logger.shared.log("Config reloaded from \(OverlayConfig.path.path).")
            Notifier.notify(title: "Whisper", body: "Config reloaded.")
        }
        statusMenu = menu
    }

    private func requestAccessibilityIfNeeded() {
        if AXIsProcessTrusted() {
            Logger.shared.log("Accessibility permission granted.")
            return
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        Logger.shared.log("Accessibility permission missing: paste and auto-submit are disabled until it is granted.")
    }

    private func reportMissingWhisperParts(_ config: OverlayConfig) {
        let missing = config.whisperInstall.missingParts
        guard !missing.isEmpty else { return }
        for part in missing { Logger.shared.log("Missing: \(part).") }
        Notifier.notify(
            title: "Whisper",
            body: "Whisper is not where the config says it is (\(config.whisperInstall.root.path)). Transcription will fail until that is fixed."
        )
    }

    /// build.sh relaunches us with pkill (SIGTERM): take the child server down
    /// with us instead of leaving an orphan holding the model and the port.
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.controller.shutdown()
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }
}
