import AppKit

/// Display-only waveform overlay shown while recording (spec §2).
/// No keyboard or mouse interaction of any kind.
final class RecordingOverlay {
    private static let barCount = 24
    private static let barWidth: CGFloat = 6
    private static let barGap: CGFloat = 4
    private static let panelWidth: CGFloat = 300
    private static let panelHeight: CGFloat = 100
    private static let maxBarHeight: CGFloat = 44
    private static let minBarHeight: CGFloat = 3

    private var panel: NSPanel?
    private var barLayers: [CALayer] = []
    private var levels = [CGFloat](repeating: 0, count: RecordingOverlay.barCount)
    private var statusLabel: NSTextField?
    private var transcribing = false

    /// dBFS (−160…0) mapped to 0…1, floored at −55 dB so room tone and the
    /// meter's own noise floor leave the bars flat instead of jittering.
    static func level(fromDB db: Double) -> CGFloat {
        let floor = -55.0
        guard db > floor else { return 0 }
        return CGFloat(min(1.0, (db - floor) / (0.0 - floor)))
    }

    func show(config: OverlayConfig) {
        dismiss()
        transcribing = false
        levels = [CGFloat](repeating: 0, count: Self.barCount)

        let width = Self.panelWidth
        let height = Self.panelHeight
        let (panel, content) = makeGlassPanel(width: width, height: height, config: config)

        let totalBarsWidth = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barGap
        let barsX = (width - totalBarsWidth) / 2
        let barsMidY = height / 2 + 8
        let fillColor = config.fillColorHex.flatMap { NSColor(hex: $0) } ?? .controlAccentColor

        barLayers = []
        for i in 0..<Self.barCount {
            let layer = CALayer()
            layer.backgroundColor = fillColor.cgColor
            layer.cornerRadius = Self.barWidth / 2
            layer.frame = NSRect(
                x: barsX + CGFloat(i) * (Self.barWidth + Self.barGap),
                y: barsMidY - Self.minBarHeight / 2,
                width: Self.barWidth,
                height: Self.minBarHeight
            )
            content.layer?.addSublayer(layer)
            barLayers.append(layer)
        }

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = Self.statusText("Recording…")
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 12, width: width, height: 16)
        content.addSubview(label)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.minY + f.height * 0.15))
        }

        self.panel = panel
        self.statusLabel = label
        OverlayDebug.orderFront(panel, label: "recording")
    }

    private static func statusText(_ text: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 12)
        ])
        s.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12)
        ]))
        return s
    }

    /// level in 0...1; newest sample enters at the right, history scrolls left.
    func push(level: CGFloat) {
        guard panel != nil, !transcribing else { return }
        levels.removeFirst()
        levels.append(max(0, min(1, level)))

        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 30.0)
        for (i, layer) in barLayers.enumerated() {
            let h = Self.minBarHeight + (Self.maxBarHeight - Self.minBarHeight) * levels[i]
            var frame = layer.frame
            let midY = frame.midY
            frame.size.height = h
            frame.origin.y = midY - h / 2
            layer.frame = frame
        }
        CATransaction.commit()
    }

    func setTranscribing() {
        transcribing = true
        statusLabel?.attributedStringValue = Self.statusText("Transcribing…")
        for layer in barLayers { layer.opacity = 0.35 }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        barLayers = []
        statusLabel = nil
        transcribing = false
    }
}
