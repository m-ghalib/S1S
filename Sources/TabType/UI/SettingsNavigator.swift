import CoreGraphics
import Foundation

/// Lets the menu bar (or other UI outside the Settings window) jump straight to a
/// specific settings section when Settings opens, and lets the SwiftUI settings
/// content ask the hosting NSWindow to resize per section (SwiftUI can't drive an
/// AppKit-hosted window's size on its own).
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var pendingSection: SettingsView.Section?
    /// The content width the current section wants — AppDelegate animates the
    /// hosting window to this when it changes.
    @Published var desiredContentWidth: CGFloat = 720
    private init() {}
}
