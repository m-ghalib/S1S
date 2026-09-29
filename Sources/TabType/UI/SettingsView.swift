import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var selection: SettingsItem? = .suggestions
    /// The section the visible page should scroll to; the page clears it.
    @State private var scrollTarget: SettingsAnchor?
    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsItem.allCases, selection: $selection) { item in
                HStack(spacing: 8) {
                    SidebarIconBadge(systemImage: item.icon, color: SectionAccent.color(for: item))
                    Text(item.rawValue)
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 230)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle((selection ?? .suggestions).rawValue)
        .frame(minWidth: 680, minHeight: 460)
        .onAppear {
            if let pending = navigator.pending { go(to: pending) }
            navigator.desiredContentWidth = SettingsNavigator.contentWidth(for: selection ?? .suggestions)
        }
        .onChange(of: navigator.pending) { _, pending in
            if let pending { go(to: pending) }
        }
        .onChange(of: selection) { _, newValue in
            navigator.desiredContentWidth = SettingsNavigator.contentWidth(for: newValue ?? .suggestions)
        }
    }

    /// No anchor means the top of the page, which is its first section.
    private func go(to destination: SettingsDestination) {
        selection = destination.item
        scrollTarget = destination.anchor ?? destination.item.anchors.first
        navigator.pending = nil
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .suggestions {
        case .suggestions:
            SettingsPage(item: .suggestions, target: $scrollTarget) {
                PermissionsSections()
                GeneralSettingsView()
                EmojiPane()
                TextToolsPane()
                PersonalizationPane()
                ShortcutsPane()
            }
        case .apps:
            // Fills the page directly: its list and detail each scroll on their own.
            AppsSettingsView(target: $scrollTarget)
        case .modelAndPower:
            SettingsPage(item: .modelAndPower, target: $scrollTarget) {
                ModelSettingsView()
                BatteryPane()
                AdvancedSettingsView()
            }
        case .about:
            SettingsPage(item: .about, target: $scrollTarget) {
                AboutPane()
                WhatsNewPane()
                StatisticsPane()
                SetupStatusSections()
            }
        }
    }
}

/// One item's page: a single grouped `Form` that scrolls to `target` when it
/// appears or when `target` changes, then clears it.
private struct SettingsPage<Content: View>: View {
    let item: SettingsItem
    @Binding var target: SettingsAnchor?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            Form { content }
                .formStyle(.grouped)
                .onAppear { scroll(proxy) }
                .onChange(of: target) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let anchor = target, anchor.item == item else { return }
        // Wait one runloop turn so a page that just appeared has laid out.
        DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
            // A newer destination may have arrived meanwhile; leave it alone.
            if target == anchor { target = nil }
        }
    }
}

/// The heading that opens each pane's block on a page, and the scroll target
/// for its anchor. `subtitle` keeps the pane's own first section title.
struct PaneHeader: View {
    let anchor: SettingsAnchor
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(anchor.title)
                .font(.title3).fontWeight(.semibold)
                .foregroundStyle(.primary)
                .padding(.top, 6)
            if let subtitle { Text(subtitle) }
        }
        .id(anchor)
    }
}

// MARK: - Live ghost-text preview

private struct GhostPreview: View {
    let opacity: Double
    var body: some View {
        HStack(spacing: 0) {
            Text("I'll send the report ")
            Text("by end of day.")
                .foregroundStyle(.secondary.opacity(opacity))
        }
        .font(.system(size: 15))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Section {
            Toggle("Enable suggestions", isOn: $settings.isEnabled)
            Toggle("Launch TabType at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
            Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
            Toggle("Show floating accessory button", isOn: $settings.showAccessoryButton)
        } header: {
            PaneHeader(anchor: .general)
        }

        Section("Accepting") {
            Picker("On Tab, insert", selection: $settings.acceptWholeLine) {
                Text("One word at a time").tag(false)
                Text("The whole suggestion").tag(true)
            }
            .pickerStyle(.radioGroup)
            Picker("Completion length", selection: $settings.completionLength) {
                Text("Short (~3 words)").tag("short")
                Text("Medium (~8 words)").tag("medium")
                Text("Long (~14 words)").tag("long")
            }
        }

        Section("Appearance") {
            GhostPreview(opacity: settings.ghostOpacity)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 4)
            LabeledContent("Ghost text opacity") {
                Slider(value: $settings.ghostOpacity, in: 0.2...1.0)
            }
        }

        Section {
            Toggle("Text mirroring in web apps", isOn: $settings.textMirroring)
        } footer: {
            Footnote("Redraws your last word with the suggestion on a matching backdrop so both align in apps like Slack. Turn off for plain ghost text.")
        }

        Section {
            Toggle("Suggest continuously while typing", isOn: $settings.continuousGeneration)
                .help("Requests a suggestion on nearly every keystroke so completions keep pace with fast typing. Web apps like Slack or Claude always wait for a brief pause.")
            if !settings.continuousGeneration {
                LabeledContent("Suggestion delay") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(settings.debounceMs) },
                            set: { settings.debounceMs = Int($0) }), in: 40...600, step: 20)
                        Text("\(settings.debounceMs) ms").monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Timing")
        } footer: {
            Footnote(settings.continuousGeneration
                     ? "Suggests on nearly every keystroke. Uses more CPU while you type."
                     : "Waits for a pause in typing before suggesting.")
        }
    }
}

// MARK: - Model manager

struct ModelSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var provider: ModelProvider
    @State private var customId = ""
    @State private var storageTick = 0   // bump to refresh installed sizes
    @State private var showAllModels = false

    var body: some View {
        Section {
            Picker("Suggestions from", selection: $settings.engineChoice) {
                Text("Local model (recommended)").tag(EngineChoice.local)
                Text("Apple Intelligence").tag(EngineChoice.appleIntelligence)
                Text("Automatic").tag(EngineChoice.auto)
            }
            .pickerStyle(.radioGroup)
        } header: {
            PaneHeader(anchor: .engine, subtitle: "Engine")
        } footer: {
            Footnote("The local model runs entirely on this Mac and needs no network. Apple Intelligence is an alternative.")
        }

        Section {
            statusRow
            ForEach(ModelAdvisor.Choice.allCases) { choice in choiceRow(choice) }
            if ModelAdvisor.Choice.matching(modelId: settings.modelId) == nil {
                Text(otherModelNote).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            Footnote("Estimates for this Mac (\(HardwareInfo.recommendationReason)). Speed also depends on what else is running.")
        }

        Section {
            DisclosureGroup("All models", isExpanded: $showAllModels) {
                ForEach(ModelCatalog.all) { model in modelRow(model) }
                HStack {
                    TextField("Hugging Face model ID", text: $customId, prompt: Text("mlx-community/…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Load") { select(customId) }
                        .disabled(customId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .help("Any MLX-format text model from Hugging Face.")
                LabeledContent("Model files") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [ModelStorage.revealDir(for: settings.modelId)])
                    }
                }
            }
        } footer: {
            Footnote("For experts. Instruct models continue text well but may occasionally reply instead. Models on disk: \(ModelStorage.formatted(ModelStorage.totalUsed())).")
                .id(storageTick)
        }
    }

    /// Download or load progress for the active model. Hidden once it is ready,
    /// because the selected choice row already says so.
    @ViewBuilder private var statusRow: some View {
        if case .ready = provider.state {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    statusIcon
                    Text(statusText).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if case .downloading(_, let p) = provider.state {
                        ProgressView(value: p).frame(width: 120)
                        Text("\(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    if case .finalizing = provider.state {
                        ProgressView().controlSize(.small)
                    }
                    if case .failed(let modelId, _) = provider.state {
                        Button("Retry") { provider.retry(modelId: modelId) }
                    }
                    if case .idle = provider.state {
                        Button("Download") { provider.load(modelId: settings.modelId) }
                    }
                }
                if case .failed(_, let message) = provider.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func choiceRow(_ choice: ModelAdvisor.Choice) -> some View {
        let selected = settings.modelId == choice.modelId
        let fit = ModelAdvisor.fit(choice, ramGB: HardwareInfo.ramGB)
        let latency = ModelAdvisor.estimatedLatencyMs(
            choice, bandwidthGBs: ModelAdvisor.memoryBandwidthGBs(chip: HardwareInfo.chip))
        Button { select(choice.modelId) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(choice.title).fontWeight(.medium)
                        if choice == recommendedChoice { badge("Recommended for this Mac") }
                        if installed(choice.modelId) {
                            Text("Downloaded").font(.caption2).foregroundStyle(.green)
                        } else {
                            Text(String(format: "%.1f GB download", choice.weightsGB))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(choice.summary).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        meter("Speed", score: ModelAdvisor.speedScore(ms: latency),
                              detail: ModelAdvisor.latencyText(ms: latency) + " per suggestion")
                        meter("Accuracy", score: choice.accuracy,
                              detail: ModelAdvisor.accuracyText(choice.accuracy))
                    }
                    .help("Rough estimates. Speed is calculated for this Mac's chip; accuracy compares these three choices with each other.")
                    switch fit {
                    case .comfortable: EmptyView()
                    case .tight:
                        Label("May slow other apps on this Mac.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    case .tooLarge:
                        Label("Needs more memory than this Mac has.", systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(fit == .tooLarge)
        .opacity(fit == .tooLarge ? 0.5 : 1)
    }

    /// Five dots filled up to `score`, then a plain-language value.
    private func meter(_ label: String, score: Int, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { i in
                    Circle()
                        .fill(i <= score ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
            Text(detail).font(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(detail)")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(Color.accentColor)
    }

    private var recommendedChoice: ModelAdvisor.Choice {
        ModelAdvisor.recommended(chip: HardwareInfo.chip, ramGB: HardwareInfo.ramGB)
    }

    private func displayName(_ id: String) -> String { ModelAdvisor.displayName(for: id) }

    /// Explains a selected model that is not one of the three simple choices.
    private var otherModelNote: String {
        let name = displayName(settings.modelId)
        if ModelCatalog.all.contains(where: { $0.id == settings.modelId }) {
            return "Using \(name), chosen under All models."
        }
        return "Using \(name), which is no longer listed. It keeps working until you pick another model."
    }

    @ViewBuilder private var statusIcon: some View {
        switch provider.state {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .finalizing: Image(systemName: "gearshape.2").foregroundStyle(.secondary)
        case .idle: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch provider.state {
        case .idle: return "Not downloaded yet"
        case .downloading(let modelId, _): return "Downloading \(displayName(modelId))…"
        case .finalizing(let modelId): return "Loading \(displayName(modelId))…"
        case .ready(let id): return "Ready: \(displayName(id))"
        case .failed(let modelId, _): return "Couldn't load \(displayName(modelId))"
        }
    }

    private func installed(_ id: String) -> Bool {
        _ = storageTick   // re-evaluate when storage changes
        return ModelStorage.isInstalled(id)
    }

    @ViewBuilder
    private func modelRow(_ model: CatalogModel) -> some View {
        Button { select(model.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: settings.modelId == model.id
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(settings.modelId == model.id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name).fontWeight(.medium)
                        if ModelCatalog.isRecommended(model.id) { badge("Recommended") }
                        if installed(model.id) {
                            Text("Installed · \(ModelStorage.formatted(ModelStorage.size(model.id)))")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(model.approxSize) · \(model.note)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if installed(model.id) {
                    Button {
                        ModelStorage.delete(model.id)
                        storageTick += 1
                    } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Delete downloaded files")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Don't persist settings.modelId yet — ModelProvider only reports it via
        // onReady once the download/load actually succeeds, so a failed switch never
        // leaves settings pointing at a model that isn't actually loaded.
        provider.load(modelId: trimmed)
    }
}

// MARK: - Apps

/// The Apps page: a searchable list of running apps plus Websites and Context
/// rows on the left, the selected row's form on the right.
struct AppsSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    /// The section navigation should show; applied as a list selection, then cleared.
    @Binding var target: SettingsAnchor?
    @State private var apps: [RunningApp] = []
    @State private var search = ""
    @State private var selected: String?

    struct RunningApp: Identifiable {
        let id: String       // bundle id
        let name: String
        let icon: NSImage?
    }

    private var filteredApps: [RunningApp] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                }
                .padding(8)
                Divider()
                List(selection: $selected) {
                    Section("Running apps") {
                        ForEach(filteredApps) { app in
                            HStack(spacing: 8) {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                }
                                Text(app.name)
                                Spacer()
                                if !(settings.appOverrides[app.id]?.isDefault ?? true) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.caption2).foregroundStyle(Color.accentColor)
                                }
                                ProfileBadge(profile: AppPolicyStore.policy(forBundleId: app.id).profile)
                            }
                            .tag(app.id)
                        }
                    }
                    Section {
                        Label("Websites", systemImage: "globe")
                            .tag(AppsListRow.websites)
                        Label("Context", systemImage: "text.viewfinder")
                            .tag(AppsListRow.context)
                    }
                }
                .listStyle(.sidebar)
            }
            // Narrow, capped list column so the detail pane always has room — the
            // whole Apps pane must fit at the base window width WITHOUT relying on
            // the window growing (sidebar ~200 + list ~220 + detail ≥300 ≤ 760).
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 280, maxHeight: .infinity)

            Group {
                if selected == AppsListRow.websites {
                    DomainsPane()
                } else if selected == AppsListRow.context {
                    Form { ContextPane() }.formStyle(.grouped)
                } else if let id = selected, let app = apps.first(where: { $0.id == id }) {
                    AppOverrideDetail(app: app, override: overrideBinding(for: id))
                } else {
                    ContentUnavailableView("Select an app",
                        systemImage: "app.badge",
                        description: Text("Choose an app to customize TabType for it."))
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            reload()
            applyTarget()
        }
        .onChange(of: target) { _, _ in applyTarget() }
    }

    private func applyTarget() {
        guard let anchor = target, anchor.item == .apps else { return }
        if let row = SettingsNavigator.appsListSelection(for: anchor) { selected = row }
        target = nil
    }

    private func overrideBinding(for id: String) -> Binding<AppOverride> {
        Binding(
            get: { settings.appOverrides[id] ?? AppOverride() },
            set: { newValue in
                if newValue.isDefault { settings.appOverrides.removeValue(forKey: id) }
                else { settings.appOverrides[id] = newValue }
            }
        )
    }

    private func reload() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { RunningApp(id: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!, icon: $0.icon) }
            .reduce(into: [RunningApp]()) { acc, app in
                if !acc.contains(where: { $0.id == app.id }) { acc.append(app) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Small colored tag showing the app's effective context profile — makes the
/// per-app behavior visible at a glance instead of buried in code.
private struct ProfileBadge: View {
    let profile: AppPolicy.Profile

    private var color: Color {
        switch profile {
        case .chat: return .blue
        case .document: return .purple
        case .codeEditor: return .orange
        case .disabled: return .gray
        case .standard: return .secondary.opacity(0.6)
        }
    }

    var body: some View {
        if profile != .standard {
            Text(profile.rawValue)
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
    }
}

/// Tri-state: nil = "Default", true = "On", false = "Off".
private struct TriStatePicker: View {
    let title: String
    @Binding var value: Bool?
    var onLabel = "On"
    var offLabel = "Off"

    var body: some View {
        Picker(title, selection: Binding(
            get: { value == nil ? "default" : (value! ? "on" : "off") },
            set: { s in value = s == "default" ? nil : (s == "on") }
        )) {
            Text("Default").tag("default")
            Text(onLabel).tag("on")
            Text(offLabel).tag("off")
        }
    }
}

/// Detail form for one app's override.
private struct AppOverrideDetail: View {
    let app: AppsSettingsView.RunningApp
    @Binding var override: AppOverride
    @State private var showingResetConfirm = false

    /// The RESOLVED policy (built-ins + this override) — the card below always
    /// tells the truth, including the effect of edits made right here.
    private var resolved: AppPolicy { AppPolicyStore.policy(forBundleId: app.id) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading) {
                        Text(app.name).font(.title3).bold()
                        Text(app.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProfileBadge(profile: resolved.profile)
                }
            }
            Section("How TabType works here") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(resolved.summaryLines, id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(line).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Section {
                TriStatePicker(title: "Read conversation (accessibility)",
                               value: $override.readConversation)
                    .help("Reads the visible conversation through the accessibility tree and keeps context always on, as chat apps do.")
            } header: {
                Text("Context")
            } footer: {
                Footnote("Turn on for messaging apps that TabType does not recognize.")
            }
            Section {
                Picker("Context size", selection: Binding(
                    get: { override.contextSize ?? "default" },
                    set: { override.contextSize = $0 == "default" ? nil : $0 }
                )) {
                    Text("Default (\(AppPolicyStore.builtinContextCap(forBundleId: app.id).formatted()) characters)")
                        .tag("default")
                    Text("Small (\(300.formatted()) characters)").tag("small")
                    Text("Large (\(AppPolicyStore.chatContextCap.formatted()) characters)").tag("large")
                }
            } footer: {
                Footnote("How much surrounding text the model gets in this app.")
            }
            Section {
                TriStatePicker(title: "Enable completions", value: $override.enabled)
                TriStatePicker(title: "Mid-line completions", value: $override.midLineEnabled)
                TriStatePicker(title: "Autocorrect", value: $override.autocorrectEnabled)
            } header: {
                Text("Completions")
            } footer: {
                Footnote("Mid-line completions appear even when text follows the cursor on the same line.")
            }
            Section {
                TriStatePicker(title: "Disable Tab key", value: $override.disableTabKey,
                              onLabel: "Disabled", offLabel: "Enabled")
            } footer: {
                Footnote("Disable Tab in apps that need it, for example to indent or switch fields.")
            }
            Section {
                Toggle("Improve compatibility with this app", isOn: $override.improveCompatibility)
            } header: {
                Text("Troubleshooting")
            } footer: {
                Footnote("Try this if completions do not appear reliably. It inserts text by pasting from the clipboard.")
            }
            Section {
                TextField("Custom instructions", text: $override.customInstructions,
                          prompt: Text("e.g. Use technical, concise language."), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...5)
            } header: {
                Text("Custom instructions")
            } footer: {
                Footnote("Extra instructions for the model in this app.")
            }
            if !override.isDefault {
                Section {
                    Button("Reset to Defaults", role: .destructive) { showingResetConfirm = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset \(app.name) to defaults?", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { override = AppOverride() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All custom settings and instructions for this app are deleted.")
        }
        .id(app.id)
    }
}

/// Per-domain (browser website) disable list.
private struct DomainsPane: View {
    @EnvironmentObject var settings: AppSettings
    @State private var newDomain = ""

    var body: some View {
        Form {
            Section {
                ForEach(Array(AppPolicyStore.chatDomains).sorted(), id: \.self) { domain in
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(.blue)
                        Text(domain)
                        Spacer()
                        ProfileBadge(profile: .chat)
                    }
                }
            } header: {
                Text("Built-in chat websites")
            } footer: {
                Footnote("On these sites, TabType reads the visible conversation, as in chat apps. Add a site below to disable it instead.")
            }
            Section {
                HStack {
                    TextField("Domain", text: $newDomain, prompt: Text("e.g. mail.google.com"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(Array(settings.disabledDomains).sorted(), id: \.self) { domain in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(domain)
                        Spacer()
                        Button {
                            settings.disabledDomains.remove(domain)
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Disabled websites")
            } footer: {
                Footnote("Suggestions are off on these domains and their subdomains in browsers.")
            }
            Section {
                HStack {
                    TextField("Domain", text: $newInstructionDomain, prompt: Text("e.g. linkedin.com"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    TextField("Instructions", text: $newInstructionText, prompt: Text("e.g. Formal tone, no emoji"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Add", action: addDomainInstructions)
                        .disabled(newInstructionDomain.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newInstructionText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(domainInstructionKeys, id: \.self) { key in
                    let host = String(key.dropFirst("domain:".count))
                    HStack(alignment: .top) {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(host).fontWeight(.medium)
                            Text(settings.appOverrides[key]?.customInstructions ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            settings.appOverrides.removeValue(forKey: key)
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Website instructions")
            } footer: {
                Footnote("Tune suggestions per website, for example language or tone. Applied on top of app settings.")
            }
        }
        .formStyle(.grouped)
    }

    @State private var newInstructionDomain = ""
    @State private var newInstructionText = ""

    private var domainInstructionKeys: [String] {
        settings.appOverrides.keys.filter { $0.hasPrefix("domain:") }.sorted()
    }

    private func addDomainInstructions() {
        var d = newInstructionDomain.trimmingCharacters(in: .whitespaces).lowercased()
        d = d.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        let text = newInstructionText.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, !text.isEmpty else { return }
        var override = settings.appOverrides[AppPolicyStore.domainKey(d)] ?? AppOverride()
        override.customInstructions = text
        settings.appOverrides[AppPolicyStore.domainKey(d)] = override
        newInstructionDomain = ""
        newInstructionText = ""
    }

    private func addDomain() {
        var d = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        d = d.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        guard !d.isEmpty else { return }
        settings.disabledDomains.insert(d)
        newDomain = ""
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showingResetConfirm = false

    var body: some View {
        Section {
            LabeledContent("Creativity (temperature)") {
                HStack {
                    Slider(value: $settings.temperature, in: 0.0...1.0, step: 0.05)
                    Text(String(format: "%.2f", settings.temperature)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
            }
            LabeledContent("Max tokens generated") {
                HStack {
                    Text("\(settings.maxTokens)").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("Max tokens generated", value: $settings.maxTokens, in: 6...48, step: 2)
                        .labelsHidden()
                }
            }
            .help("A hard ceiling on generation length. Completion length in General already sets the typical length, so you rarely need to change this.")
            LabeledContent("Context window") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(settings.contextChars) },
                        set: { settings.contextChars = Int($0) }), in: 100...2400, step: 50)
                    Text("\(settings.contextChars)").monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
        } header: {
            PaneHeader(anchor: .advanced, subtitle: "Generation")
        } footer: {
            Footnote("Max tokens is a hard ceiling. Completion length in General sets the usual length.")
        }
        Section {
            Toggle("Verbose logging", isOn: $settings.verboseLog)
            Button("Open Log in Console") {
                NSWorkspace.shared.open(Log.fileURL)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Footnote("Verbose logging writes your typed text and model output to the log file in plain text.")
        }
        FunnelSection()
        Section {
            Button("Reset to Defaults", role: .destructive) { showingResetConfirm = true }
        }
        .confirmationDialog("Reset Advanced settings to defaults?", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                settings.temperature = 0.1
                settings.maxTokens = 28
                settings.contextChars = 1200
                settings.verboseLog = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your temperature, max tokens, context window, and verbose logging choices are replaced.")
        }
    }
}
