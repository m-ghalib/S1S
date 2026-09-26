import AppKit

extension Notification.Name {
    static let tabTypeOpenSettings = Notification.Name("tabTypeOpenSettings")
    static let tabTypeRedoOnboarding = Notification.Name("tabTypeRedoOnboarding")
}

/// A small floating button shown near the focused window that opens the TabType menu,
/// for quick access when the menu-bar icon is hidden (like Cotypist's accessory button).
@MainActor
final class AccessoryButton {
    var onClick: (() -> Void)?

    private var panel: NSPanel?
    private let button = NSButton()

    init() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 28, height: 28),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        button.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        button.bezelStyle = .circular
        button.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "TabType")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(clicked)
        panel.contentView = button
        self.panel = panel
    }

    @objc private func clicked() { onClick?() }

    /// Show anchored to the bottom-right of `windowRect` (Quartz top-left global coords).
    func show(near windowRect: CGRect) {
        guard let panel else { return }
        let size: CGFloat = 28, inset: CGFloat = 16
        let topLeftY = windowRect.maxY - size - inset
        let x = windowRect.maxX - size - inset
        let flippedY = NSScreen.primaryHeight - (topLeftY + size)
        panel.setFrame(CGRect(x: x, y: flippedY, width: size, height: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}
