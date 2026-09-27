import CoreGraphics
import Foundation

/// One of the four Settings sidebar items. Each renders as a single scrolling
/// page; new settings are added as a section of an existing item.
enum SettingsItem: String, CaseIterable, Identifiable {
    case suggestions = "Suggestions"
    case apps = "Apps"
    case modelAndPower = "Model & Power"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .suggestions: return "character.cursor.ibeam"
        case .apps: return "app.badge"
        case .modelAndPower: return "cpu"
        case .about: return "info.circle"
        }
    }

    /// The page's sections, top to bottom.
    var anchors: [SettingsAnchor] {
        switch self {
        case .suggestions: return [.permissions, .general, .emoji, .textTools, .personalization, .shortcuts]
        case .apps: return [.apps, .context]
        case .modelAndPower: return [.engine, .battery, .advanced]
        case .about: return [.about, .statistics, .setupStatus]
        }
    }
}

/// A section inside an item's page that navigation can scroll to.
enum SettingsAnchor: String, CaseIterable, Hashable {
    case permissions = "Permissions"
    case general = "General"
    case emoji = "Emoji"
    case textTools = "Text Tools"
    case personalization = "Personalization"
    case shortcuts = "Shortcuts"
    case apps = "Apps"
    case context = "Context"
    case engine = "Engine & Model"
    case battery = "Battery"
    case advanced = "Advanced"
    case about = "About"
    case statistics = "Statistics"
    case setupStatus = "Setup Status"

    var title: String { rawValue }

    var item: SettingsItem {
        SettingsItem.allCases.first { $0.anchors.contains(self) }!
    }
}

/// Where Settings should open: an item, scrolled to a section (nil = the top).
struct SettingsDestination: Equatable {
    var item: SettingsItem
    var anchor: SettingsAnchor?
}

/// The ways UI outside the Settings window opens it.
enum SettingsEntry {
    case settings, statistics, about
}

/// Lets the menu bar (or other UI outside the Settings window) jump straight to a
/// specific settings section when Settings opens, and lets the SwiftUI settings
/// content ask the hosting NSWindow to resize per item (SwiftUI can't drive an
/// AppKit-hosted window's size on its own).
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var pending: SettingsDestination?
    /// The content width the current item wants — AppDelegate animates the
    /// hosting window to this when it changes.
    @Published var desiredContentWidth: CGFloat = 760
    private init() {}

    /// The plain Settings action lands on Permissions until setup is done:
    /// Accessibility is the only required grant, and a model that is still
    /// downloading or loading counts as missing.
    nonisolated static func defaultDestination(axGranted: Bool, modelReady: Bool) -> SettingsDestination {
        SettingsDestination(item: .suggestions, anchor: axGranted && modelReady ? nil : .permissions)
    }

    /// Setup is complete exactly when the plain Settings action no longer needs
    /// to land on Permissions.
    nonisolated static func isSetupComplete(axGranted: Bool, modelReady: Bool) -> Bool {
        defaultDestination(axGranted: axGranted, modelReady: modelReady).anchor == nil
    }

    /// The Apps page list row that shows an anchor, or nil to leave the
    /// selection alone (`.apps` is the page itself).
    nonisolated static func appsListSelection(for anchor: SettingsAnchor) -> String? {
        anchor == .context ? "__context__" : nil
    }

    nonisolated static func destination(for entry: SettingsEntry, axGranted: Bool, modelReady: Bool) -> SettingsDestination {
        switch entry {
        case .settings: return defaultDestination(axGranted: axGranted, modelReady: modelReady)
        case .statistics: return SettingsDestination(item: .about, anchor: .statistics)
        case .about: return SettingsDestination(item: .about, anchor: nil)
        }
    }

    /// The Apps page hosts a nested split view (app list + detail) that needs
    /// more room; every other page is a single column and reads better narrower.
    nonisolated static func contentWidth(for item: SettingsItem) -> CGFloat {
        item == .apps ? 980 : 760
    }
}
