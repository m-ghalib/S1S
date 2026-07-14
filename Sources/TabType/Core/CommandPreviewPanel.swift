import AppKit

/// A small floating panel that previews inline-command results: emoji candidates
/// or a macro's evaluated value. Non-activating, click-through, like the suggestion
/// overlay.
@MainActor
final class CommandPreviewPanel {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()

    init() {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 1
        label.font = .systemFont(ofSize: 15)

        let container = NSView()
        container.addSubview(background)
        container.addSubview(label)
        panel.contentView = container
        self.panel = panel
    }

    /// Show `text` anchored near `caretRect` (Quartz top-left global coords) or, if
    /// nil, near the bottom-center of the main screen.
    func show(text: String, caretRect: CGRect?) {
        guard !text.isEmpty else { hide(); return }
        let attributed = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 15),
        ])
        render(attributed, caretRect: caretRect)
    }

    /// Show emoji candidates as distinct, selectable glyphs — `selectedIndex` is
    /// rendered with a highlighted background so the user can see which one Tab/Enter
    /// will actually insert while cycling with the arrow keys.
    func showEmojiCandidates(_ candidates: [Emoji], selectedIndex: Int, caretRect: CGRect?) {
        guard !candidates.isEmpty else { hide(); return }
        let result = NSMutableAttributedString()
        for (i, emoji) in candidates.enumerated() {
            let piece = NSMutableAttributedString(string: " \(emoji.char) ", attributes: [
                .font: NSFont.systemFont(ofSize: 20),
            ])
            if i == selectedIndex {
                piece.addAttribute(.backgroundColor, value: NSColor.selectedContentBackgroundColor,
                                   range: NSRange(location: 0, length: piece.length))
            }
            result.append(piece)
        }
        render(result, caretRect: caretRect)
    }

    private func render(_ attributed: NSAttributedString, caretRect: CGRect?) {
        guard let panel, attributed.length > 0 else { hide(); return }
        label.attributedStringValue = attributed
        label.sizeToFit()
        let textSize = label.intrinsicContentSize
        let hPad: CGFloat = 14, vPad: CGFloat = 8
        let w = textSize.width + hPad * 2, h = textSize.height + vPad * 2

        background.frame = CGRect(x: 0, y: 0, width: w, height: h)
        label.frame = CGRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height)

        let primaryH = NSScreen.primaryHeight
        let originX: CGFloat
        let topLeftY: CGFloat
        if let r = caretRect {
            originX = r.minX
            topLeftY = r.maxY + 6            // just below the caret line
        } else if let screen = NSScreen.main {
            originX = screen.frame.midX - w / 2
            topLeftY = primaryH - (screen.frame.origin.y + 140)
        } else {
            originX = 120; topLeftY = 120
        }
        let flippedY = primaryH - (topLeftY + h)
        panel.setFrame(CGRect(x: originX, y: flippedY, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        label.stringValue = ""
    }
}
