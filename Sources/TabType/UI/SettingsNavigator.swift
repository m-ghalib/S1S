import Foundation

/// Lets the menu bar (or other UI outside the Settings window) jump straight to a
/// specific settings section when Settings opens.
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var pendingSection: SettingsView.Section?
    private init() {}
}
