import AppKit
import CoreGraphics

/// Transparent view that turns any click into a cancel (keyboard-independent
/// cancel path — spec §5 Q6).
private final class ClickCatcherView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The countdown panel that auto-submits the transcript, with Esc/click/typing
/// as escape hatches.
final class CountdownOverlay {
    private var panel: NSPanel?
    private var timer: Timer?
    private var monitor: Any?
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var startTime: Date?
    private var duration: TimeInterval = 0
    private var onComplete: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var titleLabel: NSTextField?
    private var track: NSView?
    private var fill: NSView?
    private var config = OverlayConfig()
    private var keyDisplay: (() -> String) = { "↩" }

    func show(duration: TimeInterval, config: OverlayConfig, keyDisplay: @escaping () -> String = { "↩" }, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        self.config = config
        self.duration = duration
        self.keyDisplay = keyDisplay
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.startTime = Date()

        // Clamp to minimums so a small config value can't collapse the overlay out of view.
        let width = max(config.width, 220)
        let height = max(config.height, 110)
        let (panel, content) = makeGlassPanel(width: width, height: height, config: config, ignoresMouseEvents: false)

        let title = NSTextField(labelWithString: config.title(seconds: Int(ceil(duration)), keyDisplay: keyDisplay()))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: height - 40, width: width, height: 24)
        content.addSubview(title)

        let barMargin: CGFloat = 30
        let barWidth = width - barMargin * 2
        let trackView = NSView(frame: NSRect(x: barMargin, y: (height - 14) / 2, width: barWidth, height: 14))
        trackView.wantsLayer = true
        trackView.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        trackView.layer?.cornerRadius = 7
        content.addSubview(trackView)

        let fillView = NSView(frame: NSRect(x: 0, y: 0, width: barWidth, height: 14))
        fillView.wantsLayer = true
        let fillColor = config.fillColorHex.flatMap { NSColor(hex: $0) } ?? .controlAccentColor
        fillView.layer?.backgroundColor = fillColor.cgColor
        fillView.layer?.cornerRadius = 7
        trackView.addSubview(fillView)

        let hint = NSTextField(labelWithString: config.cancelHint)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 18, width: width, height: 16)
        content.addSubview(hint)

        let clickCatcher = ClickCatcherView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        clickCatcher.onClick = { [weak self] in self?.cancel() }
        content.addSubview(clickCatcher)

        if let screen = NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
        }

        self.panel = panel
        self.titleLabel = title
        self.track = trackView
        self.fill = fillView
        OverlayDebug.orderFront(panel, label: "countdown")

        if OverlayDebug.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak panel] in
                guard let panel, !panel.isVisible else { return }
                OverlayDebug.log(OverlayDebug.probe("countdown 300ms later", panel))
            }
        }

        installKeyInterceptor()
        // Added in `.common` so the countdown keeps ticking while another app's
        // tracking runloop (a drag, an open menu) would otherwise pause it.
        let tick = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    /// Spec §5: Esc is swallowed and cancels; any other keydown cancels but
    /// passes through (user is editing — Q3). Tap re-enables itself if the OS
    /// disables it; if the tap can't be created at all, fall back to an
    /// observe-only monitor (Esc leaks but cancel still works — Q6).
    private func installKeyInterceptor() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let overlay = Unmanaged<CountdownOverlay>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = overlay.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 {  // Esc: cancel and swallow
                DispatchQueue.main.async { overlay.cancel() }
                return nil
            }
            // Any other key: user took over — cancel, let the key through.
            DispatchQueue.main.async { overlay.cancel() }
            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let eventTap {
            tapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            OverlayDebug.log("CGEventTap unavailable; falling back to global monitor (Esc will leak through).")
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
                self?.cancel()
            }
        }
    }

    private func tick() {
        guard let startTime, duration > 0 else { return }
        let remaining = max(0, duration - Date().timeIntervalSince(startTime))
        let fraction = CGFloat(max(0, min(1, remaining / duration)))
        if let track, let fill { fill.frame.size.width = track.bounds.width * fraction }
        titleLabel?.stringValue = config.title(seconds: Int(ceil(remaining)), keyDisplay: keyDisplay())
        if remaining <= 0 { complete() }
    }

    private func complete() { let cb = onComplete; teardown(); cb?() }
    private func cancel() { let cb = onCancel; teardown(); cb?() }
    func dismiss() { teardown() }

    private func teardown() {
        timer?.invalidate(); timer = nil
        if let tapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes) }
        tapRunLoopSource = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        eventTap = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil); panel = nil
        startTime = nil; onComplete = nil; onCancel = nil
        titleLabel = nil; track = nil; fill = nil
        keyDisplay = { "↩" }
    }
}
