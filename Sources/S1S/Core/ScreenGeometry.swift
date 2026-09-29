import AppKit

extension NSScreen {
    /// Height of the primary screen (the one whose frame origin is (0,0)). Used to
    /// convert between Quartz/AX global coordinates (top-left origin) and AppKit
    /// global coordinates (bottom-left origin).
    static var primaryHeight: CGFloat {
        (screens.first { $0.frame.origin == .zero } ?? screens.first ?? main)?.frame.height ?? 0
    }
}
