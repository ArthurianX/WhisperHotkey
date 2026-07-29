import AppKit

/// Builds the floating Liquid Glass panel both overlays share.
/// Returns the panel and the content view to add subviews to.
func makeGlassPanel(width: CGFloat, height: CGFloat, config: OverlayConfig,
                    ignoresMouseEvents: Bool = true) -> (panel: NSPanel, content: NSView) {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.ignoresMouseEvents = ignoresMouseEvents
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    content.wantsLayer = true

    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        glass.style = config.glassStyle.lowercased() == "clear" ? .clear : .regular
        glass.cornerRadius = config.cornerRadius
        if let hex = config.tintColorHex, let tint = NSColor(hex: hex) { glass.tintColor = tint }
        glass.contentView = content
        panel.contentView = glass
    } else {
        content.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.82).cgColor
        content.layer?.cornerRadius = config.cornerRadius
        panel.contentView = content
    }
    return (panel, content)
}
