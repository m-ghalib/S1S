import SwiftUI

/// A small shared visual layer for the Settings UI: a colored rounded-square icon
/// badge per sidebar item. Everything else in Settings intentionally stays on stock
/// `.formStyle(.grouped)`, which already reads as native.
enum SectionAccent {
    static func color(for item: SettingsItem) -> Color {
        switch item {
        case .suggestions: return .blue
        case .apps: return .teal
        case .modelAndPower: return .indigo
        case .about: return .gray
        }
    }
}

/// A colored rounded-square badge + SF Symbol, sized for a sidebar row.
struct SidebarIconBadge: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// A section footer: one or two short sentences about the controls above it.
/// Longer detail belongs in `.help()` on the control.
struct Footnote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        // Grouped Form footers are trailing-aligned on macOS and span the card's
        // outer edge; align with the row labels instead.
        Text(text).font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
