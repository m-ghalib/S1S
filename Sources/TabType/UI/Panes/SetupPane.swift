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

/// How a setup row reads: done, missing but required (needs attention), or
/// missing and optional.
enum SetupTone: Equatable {
    case ok, warning, neutral

    static func `for`(ok: Bool, required: Bool) -> SetupTone {
        if ok { return .ok }
        return required ? .warning : .neutral
    }

    var icon: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }
}

/// Top of Suggestions: every grant and the macOS conflict fix, each with its
/// action. Model download lives in Model & Power; this only links there.
/// Once setup is complete the rows fold behind a single summary row.
struct PermissionsSections: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var provider: ModelProvider
    private var signals = SetupSignals()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var complete: Bool {
        SettingsNavigator.isSetupComplete(axGranted: signals.trusted, modelReady: provider.isModelReady)
    }

    var body: some View {
        Section {
            if complete {
                SetupSummaryRow(complete: true)
                DisclosureGroup("Details") { rows }
            } else {
                rows
            }
        } header: {
            PaneHeader(anchor: .permissions)
        }
        .onReceive(poll) { _ in signals.refresh() }
    }

    @ViewBuilder private var rows: some View {
        SetupRow(ok: signals.trusted, required: true, title: "Accessibility permission",
                 detail: "Required. Lets TabType read the field you are typing in and insert completions.") {
            grantControl(signals.trusted) { _ = AccessibilityBridge.requestTrust() }
        }
        SetupRow(ok: signals.screenOK, required: false, title: "Screen Recording permission",
                 detail: "Optional. Improves context in non-chat apps. Screenshots stay on this Mac and are never stored.") {
            grantControl(signals.screenOK) { _ = ScreenContextProvider.shared.requestPermission() }
        }
        SetupRow(ok: settings.disableMacOSPredictiveText, required: false, title: "macOS text suggestions",
                 detail: settings.disableMacOSPredictiveText
                    ? "Off, so they cannot conflict with TabType. Log out and back in to fully apply."
                    : "Turn off the built-in inline suggestions to avoid conflicts with TabType.") {
            if settings.disableMacOSPredictiveText {
                HStack(spacing: 8) {
                    StatusPill(text: "Disabled", ok: true, required: false)
                    Button("Undo") { settings.disableMacOSPredictiveText = false }
                        .buttonStyle(.borderless).font(.caption)
                }
            } else {
                Button("Disable") { settings.disableMacOSPredictiveText = true }
            }
        }
        SetupRow(ok: provider.isModelReady, required: true, title: "AI model",
                 detail: "The local model that powers completions. Download and switch models in Model & Power.") {
            HStack(spacing: 8) {
                StatusPill(text: provider.setupStatusText, ok: provider.isModelReady, required: true)
                if !provider.isModelReady {
                    Button("Show") {
                        SettingsNavigator.shared.pending = SettingsDestination(item: .modelAndPower, anchor: .engine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func grantControl(_ granted: Bool, request: @escaping () -> Void) -> some View {
        if granted {
            StatusPill(text: "Granted", ok: true, required: false)
        } else {
            Button("Grant", action: request)
        }
    }
}

/// Bottom of About: the same signals as read-only rows, with no fix actions.
struct SetupStatusSections: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var provider: ModelProvider
    private var signals = SetupSignals()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            SetupSummaryRow(complete: SettingsNavigator.isSetupComplete(
                axGranted: signals.trusted, modelReady: provider.isModelReady))
            SetupRow(ok: signals.trusted, required: true, title: "Accessibility permission", detail: "Required.") {
                StatusPill(text: signals.trusted ? "Granted" : "Not granted", ok: signals.trusted, required: true)
            }
            SetupRow(ok: signals.screenOK, required: false, title: "Screen Recording permission", detail: "Optional.") {
                StatusPill(text: signals.screenOK ? "Granted" : "Not granted", ok: signals.screenOK, required: false)
            }
            SetupRow(ok: provider.isModelReady, required: true, title: "AI model", detail: settings.modelId) {
                StatusPill(text: provider.setupStatusText, ok: provider.isModelReady, required: true)
            }
            SetupRow(ok: settings.disableMacOSPredictiveText, required: false, title: "macOS text suggestions",
                     detail: "Can conflict with TabType when on.") {
                StatusPill(text: settings.disableMacOSPredictiveText ? "Disabled" : "On",
                           ok: settings.disableMacOSPredictiveText, required: false)
            }
        } header: {
            PaneHeader(anchor: .setupStatus)
        }
        .onReceive(poll) { _ in signals.refresh() }
    }
}

// MARK: - Rows

/// One-line verdict on setup, shared by Permissions and Setup Status.
private struct SetupSummaryRow: View {
    let complete: Bool

    var body: some View {
        let tone = SetupTone.for(ok: complete, required: true)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone.icon).foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(complete ? "Setup complete" : "Setup incomplete").fontWeight(.medium)
                Text(complete
                     ? "Start typing in any app and press Tab to accept a suggestion."
                     : "Fix permissions in Suggestions and the model in Model & Power.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SetupRow<Trailing: View>: View {
    let ok: Bool
    let required: Bool
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let tone = SetupTone.for(ok: ok, required: required)
        LabeledContent {
            trailing
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: tone.icon).foregroundStyle(tone.color)
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
    let required: Bool

    var body: some View {
        Text(text)
            .font(.caption).fontWeight(.medium)
            .foregroundStyle(SetupTone.for(ok: ok, required: required).color)
    }
}

extension ModelProvider {
    /// Setup-state view of the model: true only once `state` is `.ready`, so a
    /// download or load in progress counts as not ready.
    var isModelReady: Bool { if case .ready = state { return true } else { return false } }
}

private extension ModelProvider {
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
