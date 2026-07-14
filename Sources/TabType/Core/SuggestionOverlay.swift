import AppKit

/// A borderless, non-activating overlay window that shows the suggestion either as
/// dimmed inline "ghost text" at the caret (when precise caret bounds are known) or
/// as a floating pill anchored to the focused window (HUD fallback for Electron /
/// Catalyst apps that don't expose caret bounds). It never takes focus or intercepts
/// mouse events.
@MainActor
final class SuggestionOverlay {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()

    init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(background)
        container.addSubview(label)
        panel.contentView = container
        self.panel = panel
    }

    // MARK: Inline ghost text (native apps with caret bounds)

    /// Show `text` as dimmed ghost text just right of the caret. `caretRect` is in
    /// Quartz/AX global coordinates (top-left origin). `color`, when provided (from the
    /// screenshot appearance probe), makes the ghost blend with the field's real text.
    ///
    /// Vertically aligns the label's baseline to the caret rect's baseline (using the
    /// font's ascender) instead of stretching the label to the caret height and letting
    /// AppKit center it — that mismatch is what made the ghost float at the wrong
    /// height relative to the real text.
    func showInline(text: String, at caretRect: CGRect, font: NSFont, opacity: Double,
                    color: NSColor? = nil) {
        guard let panel, !text.isEmpty else { hide(); return }
        background.isHidden = true

        label.stringValue = text
        label.font = font
        // Apply the user's ghost-opacity setting uniformly — whether the color came
        // from the screenshot probe or the neutral-gray fallback — so the Settings
        // slider always has a consistent, visible effect.
        label.textColor = (color ?? NSColor.secondaryLabelColor).withAlphaComponent(opacity)
        label.sizeToFit()
        let size = label.intrinsicContentSize
        let padding: CGFloat = 2

        // The panel is sized exactly to the label; no extra vertical stretch.
        let panelHeight = size.height
        label.frame = CGRect(x: 0, y: 0, width: size.width, height: panelHeight)

        // Baseline of the caret rect ≈ caretRect.maxY - font.descender-ish gap. Align
        // the label's own baseline (ascender from its top) to that same point.
        let caretBaselineFromTop = caretRect.height > 0
            ? caretRect.height - abs(font.descender) - 1
            : font.ascender
        let labelBaselineFromTop = size.height - abs(font.descender) - 1
        let verticalNudge = caretBaselineFromTop - labelBaselineFromTop

        let flippedY = NSScreen.primaryHeight - (caretRect.minY + verticalNudge + panelHeight)
        let origin = CGPoint(x: caretRect.maxX + padding, y: flippedY)
        panel.setFrame(CGRect(origin: origin,
                              size: CGSize(width: size.width + padding, height: panelHeight)),
                       display: true)
        panel.orderFrontRegardless()
    }

    // MARK: HUD pill (Electron / Catalyst fallback)

    /// Show `text` as a floating pill with a Tab hint, anchored near the bottom of
    /// `windowRect` (Quartz/AX top-left global coords) or the main screen.
    func showHUD(text: String, windowRect: CGRect?) {
        guard let panel, !text.isEmpty else { hide(); return }
        background.isHidden = false

        label.stringValue = "\(text)   ⇥ Tab"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let textSize = label.intrinsicContentSize
        let hPad: CGFloat = 14, vPad: CGFloat = 8
        let w = textSize.width + hPad * 2
        let h = textSize.height + vPad * 2

        background.frame = CGRect(x: 0, y: 0, width: w, height: h)
        label.frame = CGRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height)

        // Anchor bottom-center of the window (or main screen), converted to AppKit.
        let primaryH = NSScreen.primaryHeight
        let anchorX: CGFloat
        let anchorTopLeftY: CGFloat
        if let r = windowRect, r.width > 0 {
            anchorX = r.midX - w / 2
            anchorTopLeftY = r.maxY - h - 12   // just inside the window bottom
        } else if let screen = NSScreen.main {
            anchorX = screen.frame.midX - w / 2
            anchorTopLeftY = primaryH - (screen.frame.origin.y + 120)
        } else {
            anchorX = 100; anchorTopLeftY = 100
        }
        let flippedY = primaryH - (anchorTopLeftY + h)
        panel.setFrame(CGRect(x: anchorX, y: flippedY, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        label.stringValue = ""
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}
