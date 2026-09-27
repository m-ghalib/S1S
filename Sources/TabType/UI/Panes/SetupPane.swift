import Combine
import SwiftUI

/// Live setup signals shared by Permissions (Suggestions) and Setup Status
/// (About). Polls the grants once a second so a permission granted in System
/// Settings shows up without reopening the window.
@MainActor
private struct SetupSignals: DynamicProperty {
    @State var trusted = AccessibilityBridge.isTrusted()
    @State var screenOK = ScreenContextProvider.shared.hasPermission()

    func refresh() {
        trusted = AccessibilityBridge.isTrusted()
        screenOK = ScreenContextProvider.shared.hasPermission()
    }
}

/// Top of Suggestions: every grant and the macOS conflict fix, each with its
/// action. Model download lives in Model & Power; this only links there.
struct PermissionsSections: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var provider: ModelProvider
    private var signals = SetupSignals()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            SetupRow(ok: signals.trusted, title: "Accessibility permission",
                     detail: "Required — lets TabType read the field you're typing in and insert completions.") {
                if signals.trusted { StatusPill(text: "Granted", ok: true) }
                else { Button("Grant") { _ = AccessibilityBridge.requestTrust() } }
            }
            SetupRow(ok: signals.screenOK, title: "Screen Recording permission",
                     detail: "Optional — better context in non-chat apps. Screenshots are processed locally and never stored or sent anywhere.") {
                if signals.screenOK { StatusPill(text: "Granted", ok: true) }
                else { Button("Grant") { _ = ScreenContextProvider.shared.requestPermission() } }
            }
            SetupRow(ok: settings.disableMacOSPredictiveText, title: "macOS text suggestions",
                     detail: settings.disableMacOSPredictiveText
                        ? "Built-in inline suggestions are off, so they can't conflict with TabType. Log out and back in to fully apply."
                        : "Disable the built-in inline suggestions to avoid conflicts with TabType.") {
                if settings.disableMacOSPredictiveText {
                    HStack(spacing: 8) {
                        StatusPill(text: "Disabled", ok: true)
                        Button("Undo") { settings.disableMacOSPredictiveText = false }
                            .buttonStyle(.borderless).font(.caption)
                    }
                } else {
                    Button("Disable") { settings.disableMacOSPredictiveText = true }
                }
            }
            SetupRow(ok: provider.isModelReady, title: "AI model",
                     detail: "The local model that powers completions. Download and switch models in Model & Power.") {
                HStack(spacing: 8) {
                    StatusPill(text: provider.setupStatusText, ok: provider.isModelReady)
                    if !provider.isModelReady {
                        Button("Show") {
                            SettingsNavigator.shared.pending = SettingsDestination(item: .modelAndPower, anchor: .engine)
                        }
                    }
                }
            }
        } header: {
            PaneHeader(anchor: .permissions)
        }
        .onReceive(poll) { _ in signals.refresh() }
    }
}

/// Bottom of About: the same signals as read-only rows, with no fix actions.
struct SetupStatusSections: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var provider: ModelProvider
    private var signals = SetupSignals()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var allSet: Bool { signals.trusted && provider.isModelReady }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: allSet ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title2)
                    .foregroundStyle(allSet ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(allSet ? "All set!" : "Setup incomplete").font(.headline)
                    Text(allSet
                         ? "TabType is ready to use. Start typing in any app and press Tab to accept a suggestion."
                         : "Fix permissions in Suggestions and the model in Model & Power.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            SetupRow(ok: signals.trusted, title: "Accessibility permission", detail: "Required.") {
                StatusPill(text: signals.trusted ? "Granted" : "Not granted", ok: signals.trusted)
            }
            SetupRow(ok: signals.screenOK, title: "Screen Recording permission", detail: "Optional.") {
                StatusPill(text: signals.screenOK ? "Granted" : "Not granted", ok: signals.screenOK)
            }
            SetupRow(ok: provider.isModelReady, title: "AI model", detail: settings.modelId) {
                StatusPill(text: provider.setupStatusText, ok: provider.isModelReady)
            }
            SetupRow(ok: settings.disableMacOSPredictiveText, title: "macOS text suggestions", detail: "Can conflict with TabType when on.") {
                StatusPill(text: settings.disableMacOSPredictiveText ? "Disabled" : "On", ok: settings.disableMacOSPredictiveText)
            }
        } header: {
            PaneHeader(anchor: .setupStatus)
        }
        .onReceive(poll) { _ in signals.refresh() }
    }
}

// MARK: - Rows

private struct SetupRow<Trailing: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ok ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    let ok: Bool

    var body: some View {
        Text(text)
            .font(.caption).fontWeight(.medium)
            .foregroundStyle(ok ? .green : .secondary)
    }
}

private extension ModelProvider {
    var isModelReady: Bool { if case .ready = state { return true } else { return false } }

    var setupStatusText: String {
        switch state {
        case .ready: return "Ready"
        case .downloading(_, let p): return "Downloading \(Int(p * 100))%"
        case .finalizing: return "Loading…"
        case .failed: return "Failed"
        case .idle: return "Not downloaded"
        }
    }
}
