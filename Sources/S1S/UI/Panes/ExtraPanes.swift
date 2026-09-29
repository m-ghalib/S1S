import SwiftUI

/// What S1S is allowed to read for extra context. Shown as the Context row
/// of the Apps list.
struct ContextPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Read on-screen context", isOn: $settings.useScreenContext)
                .help("S1S picks a context recipe per app: the conversation in chat apps and chat websites (accessibility tree, no screenshots), your document in writing apps, and nearby on-screen text elsewhere. Select an app in the list to see and change what applies to it.")
            Picker("Screenshot extraction mode", selection: $settings.screenCropMode) {
                ForEach(AppSettings.ScreenCropMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .disabled(!settings.useScreenContext)
            .help("Applies only when falling back to screenshot OCR. Caret-Aware focuses on the text around your cursor; Columnar helps with multi-column windows.")
        } header: {
            PaneHeader(anchor: .context, subtitle: "Screen Context")
        } footer: {
            Footnote("Reads the text around your cursor so suggestions match your work. Chat apps like Slack and Claude always use this.")
        }
        Section {
            Toggle("Use screenshots to improve suggestion appearance", isOn: $settings.useScreenshotAppearance)
        } footer: {
            Footnote("Samples the color around the caret so ghost text matches the field. May show the Screen Recording indicator.")
        }
        Section {
            Toggle("Use clipboard for context", isOn: $settings.useClipboardContext)
        } header: {
            Text("Clipboard Settings")
        } footer: {
            Footnote("Reads your clipboard to understand your work. Processed locally, never stored or sent.")
        }
    }
}

/// Toggles for the inline text tools (autocorrect). Emoji has its own
/// dedicated sidebar section (`EmojiPane`).
struct TextToolsPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Fix typos automatically", isOn: $settings.autocorrectEnabled)
                .onChange(of: settings.autocorrectEnabled) { _, on in
                    if on { SpellChecker.shared.loadIfNeeded(language: settings.autocorrectLanguage) }
                }
            Picker("Language", selection: $settings.autocorrectLanguage) {
                Section("Western") {
                    ForEach(["en", "es", "fr", "de", "it", "pt"], id: \.self) {
                        Text(SpellChecker.displayName($0)).tag($0)
                    }
                }
                Section("Indian") {
                    ForEach(["hi", "bn", "ta", "te", "ml", "ur"], id: \.self) {
                        Text(SpellChecker.displayName($0)).tag($0)
                    }
                }
            }
            .disabled(!settings.autocorrectEnabled)
            .onChange(of: settings.autocorrectLanguage) { _, lang in
                SpellChecker.shared.loadIfNeeded(language: lang)
            }
        } header: {
            PaneHeader(anchor: .textTools, subtitle: "Autocorrect")
        } footer: {
            Footnote("Corrects clear typos in place when you finish a word, for example \"teh\" → \"the\". Never in password fields.")
        }
        Section {
            Toggle("Don't suggest while a word is misspelled", isOn: $settings.skipOnTypo)
                .onChange(of: settings.skipOnTypo) { _, on in
                    if on { SpellChecker.shared.loadIfNeeded(language: settings.autocorrectLanguage) }
                }
        } footer: {
            Footnote("Pauses completions while the word at the cursor looks like a typo.")
        }
    }
}

struct ShortcutsPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            KeyRecorderRow(title: "Accept word", binding: $settings.acceptWordKey)
            KeyRecorderRow(title: "Accept whole suggestion", binding: $settings.acceptAllKey)
            KeyRecorderRow(title: "Dismiss", binding: $settings.dismissKey)
            KeyRecorderRow(title: "Word alternatives", binding: $settings.wordAlternativesKey)
            KeyRecorderRow(title: "Force a suggestion", binding: $settings.forceActivateKey)
            KeyRecorderRow(title: "Pause in current app (5 min)", binding: $settings.appPauseKey)
            KeyRecorderRow(title: "Enable/disable S1S", binding: $settings.toggleKey, allowNone: true)
        } header: {
            PaneHeader(anchor: .shortcuts)
        } footer: {
            Footnote("Click a shortcut, then press the new keys. Hold ⌥ while accepting to send the real key, for example ⌥Tab to move between fields.")
        }
        Section {
            Toggle("Include trailing space", isOn: $settings.includeTrailingSpace)
            Toggle("Include trailing punctuation", isOn: $settings.includeTrailingPunctuation)
        } header: {
            Text("Accepting a word")
        } footer: {
            Footnote("When off, punctuation after a word, like a period or ?, waits for a separate press.")
        }
        Section("Behavior") {
            Picker("When you press Escape", selection: $settings.escapeBehavior) {
                Text("Dismiss the suggestion").tag("dismiss")
                Text("Pause completions briefly").tag("pause")
            }
        }
    }
}

/// A row that records a key combination when focused.
private struct KeyRecorderRow: View {
    let title: String
    @Binding var binding: KeyBinding
    var allowNone: Bool = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                KeyRecorder(binding: $binding)
                if allowNone && binding.isSet {
                    Button("Clear") { binding = .unset }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }
}

/// An NSView-backed recorder that captures the next key + modifiers.
private struct KeyRecorder: NSViewRepresentable {
    @Binding var binding: KeyBinding

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onCapture = { self.binding = $0 }
        b.binding = binding
        return b
    }
    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.binding = binding
        nsView.refreshTitle()
    }

    final class RecorderButton: NSButton {
        var binding: KeyBinding = .unset
        var onCapture: ((KeyBinding) -> Void)?
        private var recording = false

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(startRecording)
            refreshTitle()
        }
        required init?(coder: NSCoder) { fatalError() }

        func refreshTitle() {
            title = recording ? "Press keys…" : binding.displayString
        }

        @objc private func startRecording() {
            recording = true
            refreshTitle()
            window?.makeFirstResponder(self)
        }

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            let b = KeyBinding(keyCode: Int(event.keyCode),
                               flags: cgFlags(from: event.modifierFlags))
            recording = false
            binding = b
            onCapture?(b)
            refreshTitle()
        }

        private func cgFlags(from m: NSEvent.ModifierFlags) -> CGEventFlags {
            var f: CGEventFlags = []
            if m.contains(.command) { f.insert(.maskCommand) }
            if m.contains(.shift) { f.insert(.maskShift) }
            if m.contains(.option) { f.insert(.maskAlternate) }
            if m.contains(.control) { f.insert(.maskControl) }
            return f
        }
    }
}

/// Author name / voice / custom instructions that shape suggestions to sound like you.
struct PersonalizationPane: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showingDeleteConfirm = false
    @State private var showingResetConfirm = false

    var body: some View {
        Section {
            Toggle("Collect inputs for personalization", isOn: $settings.collectTypingHistory)
                .help("S1S records short snippets of text it monitors to improve completions.")
            Toggle("Store inputs without accepted completions", isOn: $settings.storeInputsWithoutAcceptedCompletions)
                .disabled(!settings.collectTypingHistory)
                .help("When on, S1S stores everything it monitors, even when you don't accept a suggestion. When off, only text where you accepted a completion is stored.")
            // Kept in a subview so TypingHistoryStore.shared (which reads the
            // Keychain on first touch) is only instantiated when data can exist.
            if settings.collectTypingHistory || TypingHistoryStore.historyFileExists {
                HistoryDataRow(showingDeleteConfirm: $showingDeleteConfirm)
            }
        } header: {
            PaneHeader(anchor: .personalization, subtitle: "Typing History")
        } footer: {
            Footnote("Collected text is encrypted and stays on this Mac. Not recommended if you work with sensitive information.")
        }
        .confirmationDialog("Delete all collected typing history?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { TypingHistoryStore.shared.deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
        Section {
            LabeledContent("Personalize word choice") {
                HStack {
                    Slider(value: $settings.personalizeWordChoice, in: 0...1, step: 0.05)
                    Text(settings.personalizeWordChoice == 0 ? "Off" : String(format: "%.0f%%", settings.personalizeWordChoice * 100))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            .help("Uses your onboarding picks at first, then completions you accept. With typing history on, it also favors words you use often.")
        } footer: {
            Footnote("Shows the model examples of your writing. Higher values use more examples but may pick a less fitting word.")
        }
        Section {
            LabeledContent("Writing-style picks") {
                Button("Redo Onboarding…") {
                    NotificationCenter.default.post(name: .s1sRedoOnboarding, object: nil)
                }
            }
        } header: {
            Text("Onboarding")
        } footer: {
            Footnote("Replaces your earlier picks, the writing style below, and the onboarding examples. Accepted completions are kept.")
        }
        Section {
            TextField("Your name", text: $settings.authorName, prompt: Text("Optional"))
            TextField("Writing style", text: $settings.writingStyle,
                      prompt: Text("e.g. concise, friendly, British spelling"), axis: .vertical)
                .lineLimit(2...4)
            TextField("Custom instructions", text: $settings.customInstructions,
                      prompt: Text("e.g. Avoid exclamation marks. Prefer plain words."), axis: .vertical)
                .lineLimit(2...5)
        } header: {
            HStack {
                Text("Custom AI Instructions")
                Spacer()
                Button("Reset to Defaults", role: .destructive) { showingResetConfirm = true }
                    .buttonStyle(.borderless).font(.caption)
            }
        } footer: {
            Footnote("These shape suggestions to match your voice. Used only by the on-device model.")
        }
        .confirmationDialog("Reset custom AI instructions?", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                settings.authorName = NSFullUserName()
                settings.writingStyle = ""
                settings.customInstructions = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your name returns to your account name. Your writing style and custom instructions are deleted.")
        }
    }
}

/// Data row for the Personalization pane; owns the `@ObservedObject` so the
/// store singleton (whose first touch reads the Keychain) is only created when
/// this row is actually shown.
private struct HistoryDataRow: View {
    @ObservedObject var history = TypingHistoryStore.shared
    @Binding var showingDeleteConfirm: Bool

    var body: some View {
        LabeledContent {
            Button("Delete All…", role: .destructive) { showingDeleteConfirm = true }
                .disabled(history.entryCount == 0 && history.pairCount == 0)
        } label: {
            Text("Existing data")
            Text(summary)
        }
    }

    private var summary: String {
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        switch (history.entryCount, history.pairCount) {
        case (0, 0): return "No inputs have been collected yet."
        case (let e, 0): return "\(plural(e, "snippet")) stored locally."
        case (0, let p): return "\(plural(p, "example")) stored locally."
        case (let e, let p): return "\(plural(e, "snippet")) and \(plural(p, "example")) stored locally."
        }
    }
}

/// Emoji suggestions + customization.
struct EmojiPane: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Section {
            Toggle("Enable emoji suggestions", isOn: $settings.emojiEnabled)
            Toggle("Suggest emoji from emoticons", isOn: $settings.emoticonsEnabled)
        } header: {
            PaneHeader(anchor: .emoji)
        } footer: {
            Footnote("Type `:name` and press Tab to insert 🚀. Emoticons like :-) ;-) <3 convert automatically.")
        }
        Section {
            Picker("Preferred skin tone", selection: $settings.emojiSkinTone) {
                ForEach(SkinTone.allCases, id: \.rawValue) { tone in
                    Text(tone.label).tag(tone.rawValue)
                }
            }
        } header: {
            Text("Customization")
        } footer: {
            Footnote("Applies to emoji that support skin-tone modifiers.")
        }
    }
}

/// Power-saving behavior in Low Power Mode.
struct BatteryPane: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Section {
            Toggle("Only show completions on demand", isOn: $settings.batteryOnDemandOnly)
            Toggle("Generate slightly shorter completions", isOn: $settings.batteryShorterCompletions)
            Toggle("Fall back to debounced suggestions", isOn: $settings.batteryUseDebounce)
                .help("Steps down from continuous generation (Suggestions ▸ General ▸ Timing) while Low Power Mode is on, without turning it off.")
        } header: {
            PaneHeader(anchor: .battery, subtitle: "In Low Power Mode")
        } footer: {
            Footnote(PowerMonitor.shared.isLowPower
                     ? "Low Power Mode is on, so these settings are active. They mainly help the local model."
                     : "These settings apply while macOS Low Power Mode is on. They mainly help the local model.")
        }
    }
}

/// Local usage counters: words completed and suggestion acceptance rate.
struct StatisticsPane: View {
    @ObservedObject var stats = Statistics.shared
    @State private var showingResetConfirm = false

    var body: some View {
        Section {
            LabeledContent("Words completed", value: "\(stats.wordsCompleted)")
            LabeledContent("Suggestions shown", value: "\(stats.suggestionsShown)")
            LabeledContent("Suggestions accepted", value: "\(stats.suggestionsAccepted)")
            LabeledContent("Acceptance rate", value: percent(stats.acceptanceRate))
        } header: {
            PaneHeader(anchor: .statistics)
        } footer: {
            Footnote("These numbers are stored only on your Mac and never leave it.")
        }
        Section {
            Button("Reset Statistics…", role: .destructive) { showingResetConfirm = true }
        }
        .confirmationDialog("Reset statistics?", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { stats.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All usage and funnel counts are permanently deleted.")
        }
    }
}

/// Where suggestions drop out between a model request and the screen. A
/// diagnostic, so it lives under Advanced rather than Statistics.
struct FunnelSection: View {
    @ObservedObject var stats = Statistics.shared

    var body: some View {
        Section {
            LabeledContent("Show rate", value: percent(stats.showRate))
            ForEach(Statistics.FunnelEvent.allCases, id: \.rawValue) { event in
                LabeledContent(event.label, value: "\(stats.funnel[event] ?? 0)")
            }
        } header: {
            Text("Suggestion Funnel")
        } footer: {
            Footnote("Where suggestions drop out before reaching the screen. Many rejections point at over-filtering; many \"input changed\" counts point at latency.")
        }
    }
}

private func percent(_ v: Double) -> String {
    String(format: "%.0f%%", v * 100)
}

/// The bundled release notes: this version's first, earlier ones collapsed.
struct WhatsNewPane: View {
    private let entries = ReleaseNotes.entries(upTo: ReleaseNotes.currentVersion, in: ReleaseNotes.bundled)

    var body: some View {
        Section {
            if let latest = entries.first {
                notes(latest)
            } else {
                Text("No release notes for this version.").foregroundStyle(.secondary)
            }
        } header: {
            PaneHeader(anchor: .whatsNew, subtitle: entries.first.map { "Version \($0.version)" })
        }
        if entries.count > 1 {
            Section {
                DisclosureGroup("Earlier versions") {
                    ForEach(entries.dropFirst(), id: \.version) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Version \(entry.version)").fontWeight(.medium)
                            notes(entry)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func notes(_ entry: ReleaseNotes.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(Self.markdown(item))
                }
            }
        }
    }

    /// Inline Markdown (bold, code, links); plain text if it does not parse.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

struct AboutPane: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 28)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("S1S").font(.title2).bold()
                        Text("Free, open-source, on-device autocomplete for macOS.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Version \(ReleaseNotes.currentVersion) (\(ReleaseNotes.currentBuild))")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            PaneHeader(anchor: .about)
        }
        Section("Privacy") {
            Label("Runs 100% on your Mac. No cloud, no account, no telemetry.",
                  systemImage: "lock.shield")
            Label("Your text and screen content never leave the device.",
                  systemImage: "hand.raised")
            Label("Password fields are never autocompleted.",
                  systemImage: "key.slash")
        }
        Section("Open source") {
            Text("MIT licensed. Built in the open.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section("Third-party acknowledgments") {
            ForEach(Self.acknowledgments, id: \.name) { ack in
                VStack(alignment: .leading, spacing: 1) {
                    Text(ack.name).fontWeight(.medium)
                    Text(ack.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let acknowledgments: [(name: String, detail: String)] = [
        ("Apple Foundation Models & Vision", "On-device AI completions and OCR (Apple Inc.)"),
        ("MLX Swift", "Local model inference on Apple silicon (Apple, ml-explore)"),
        ("mlx-swift-lm", "LLM model implementations (ml-explore)"),
        ("swift-transformers", "Hugging Face model download (Hugging Face)"),
        ("Qwen2.5", "Local base models (Alibaba, Apache-2.0)"),
        ("gemoji", "Emoji shortcode dataset (GitHub, MIT)"),
        ("FrequencyWords", "Autocorrect frequency lists (Hermit Dave, MIT)"),
        ("SymSpell algorithm", "Symmetric-delete spelling correction (Wolf Garbe, MIT)"),
    ]
}
