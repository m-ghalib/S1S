import SwiftUI

/// What TabType is allowed to read for extra context, grouped the way Cotypist's own
/// Context pane is (Screenshot Settings / Clipboard Settings) rather than folded into
/// Personalization.
struct ContextPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Read on-screen context", isOn: $settings.useScreenContext)
            Text("Reads the conversation or document around your cursor — via the accessibility tree in chat apps, or an on-device screenshot elsewhere — so suggestions match what you're working on. Chat apps like Slack and Claude always use this.")
                .font(.caption).foregroundStyle(.secondary)
            Text("TabType picks a context recipe per app: the conversation in chat apps and chat websites (accessibility tree, no screenshots), your document in writing apps, and nearby on-screen text elsewhere. Open the Apps section to see exactly what applies to each app — and to change it.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Screenshot extraction mode", selection: $settings.screenCropMode) {
                ForEach(AppSettings.ScreenCropMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .disabled(!settings.useScreenContext)
            Text("Applies only when falling back to screenshot OCR. Caret-Aware focuses on the text around your cursor; Columnar helps with multi-column windows.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use screenshots to improve suggestion appearance", isOn: $settings.useScreenshotAppearance)
            Text("Samples the color around the caret so ghost text blends with the field's real text. May occasionally show a Screen Recording indicator in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            PaneHeader(anchor: .context, subtitle: "Screen Context")
        }
        Section("Clipboard Settings") {
            Toggle("Use clipboard for context", isOn: $settings.useClipboardContext)
            Text("Reads your clipboard to understand what you're working with. Processed locally; never stored or sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Toggles for the inline text tools (autocorrect + macros). Emoji has its own
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
            Text("When you finish a word, clear typos are corrected in place (e.g. \"teh\" → \"the\"). Never in password fields.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Don't suggest while a word is misspelled", isOn: $settings.skipOnTypo)
                .onChange(of: settings.skipOnTypo) { _, on in
                    if on { SpellChecker.shared.loadIfNeeded(language: settings.autocorrectLanguage) }
                }
            Text("Pauses completions when the word at the cursor looks like a typo, instead of suggesting its corrected form.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            PaneHeader(anchor: .textTools, subtitle: "Autocorrect")
        }
        Section("Macros") {
            Toggle("Inline macros", isOn: $settings.macrosEnabled)
            Text("Type `/` then a command and press Tab:")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                macroRow("/date, /time, /now", "current date / time")
                macroRow("/uuid, /dice, /coin", "random value")
                macroRow("/random 100", "random 0–100")
                macroRow("10km->mi", "unit conversion")
                macroRow("2+2*3", "arithmetic")
            }
            .font(.caption)
            .padding(.top, 2)
        }
    }

    private func macroRow(_ cmd: String, _ desc: String) -> some View {
        GridRow {
            Text(cmd).monospaced().foregroundStyle(.primary)
            Text(desc).foregroundStyle(.secondary)
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
            KeyRecorderRow(title: "Enable/disable TabType", binding: $settings.toggleKey, allowNone: true)
            Text("Hold ⌥ with the accept key to send the real key to the app (e.g. ⌥Tab moves between form fields while a suggestion is shown).")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            PaneHeader(anchor: .shortcuts)
        }
        Section("Accepting a word") {
            Toggle("Include trailing space", isOn: $settings.includeTrailingSpace)
            Toggle("Include trailing punctuation", isOn: $settings.includeTrailingPunctuation)
            Text("When off, punctuation attached to a word (like a period or ?) is left for a separate press.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Behavior") {
            Picker("When you press Escape", selection: $settings.escapeBehavior) {
                Text("Dismiss the suggestion").tag("dismiss")
                Text("Pause completions briefly").tag("pause")
            }
        }
        Section {
            Text("Click a shortcut, then press the key combination you want. Changes take effect immediately.")
                .font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        Section {
            Toggle("Collect inputs for personalization", isOn: $settings.collectTypingHistory)
            Text("TabType can record short snippets of text it monitors to improve completions. All collected data is encrypted and stored locally on your Mac — nothing is sent anywhere. Not recommended if you work with particularly sensitive information.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Store inputs without accepted completions", isOn: $settings.storeInputsWithoutAcceptedCompletions)
                .disabled(!settings.collectTypingHistory)
            Text("When on, TabType stores everything it monitors, even when you don't accept a suggestion. When off, only text where you accepted a completion is stored.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Personalize word choice")
                    Slider(value: $settings.personalizeWordChoice, in: 0...1, step: 0.05)
                    Text(settings.personalizeWordChoice == 0 ? "Off" : String(format: "%.0f%%", settings.personalizeWordChoice * 100))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                Text("Shows the model examples of your writing: your onboarding picks at first, then completions you accept. With typing history on, it also favors words you use often. Higher values use more examples; too high may occasionally suggest a less fitting word.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Kept in a subview so TypingHistoryStore.shared (which reads the
            // Keychain on first touch) is only instantiated when data can exist.
            if settings.collectTypingHistory || TypingHistoryStore.historyFileExists {
                HistoryDataRow(showingDeleteConfirm: $showingDeleteConfirm)
            }
        } header: {
            PaneHeader(anchor: .personalization, subtitle: "Typing History")
        }
        .confirmationDialog("Delete all collected typing history?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { TypingHistoryStore.shared.deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
        Section("Onboarding") {
            HStack {
                Text("Redo the writing-style picks from first-run setup.")
                Spacer()
                Button("Redo Onboarding…") {
                    NotificationCenter.default.post(name: .tabTypeRedoOnboarding, object: nil)
                }
            }
            Text("Replaces your earlier choices, the writing style below, and the onboarding examples. Completions you accepted are kept.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            HStack {
                Text("Custom AI Instructions").font(.headline)
                Spacer()
                Button("Reset to Default") {
                    settings.authorName = NSFullUserName()
                    settings.writingStyle = ""
                    settings.customInstructions = ""
                }
            }
            TextField("Your name (optional)", text: $settings.authorName)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading) {
                Text("Writing style").font(.caption).foregroundStyle(.secondary)
                TextField("Writing style", text: $settings.writingStyle,
                          prompt: Text("e.g. concise, friendly, British spelling"), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
            VStack(alignment: .leading) {
                Text("Custom instructions").font(.caption).foregroundStyle(.secondary)
                TextField("Custom instructions", text: $settings.customInstructions,
                          prompt: Text("e.g. Avoid exclamation marks. Prefer plain words."), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }
            Text("These shape suggestions to match your voice. Sent only to the on-device model.")
                .font(.caption).foregroundStyle(.secondary)
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
        LabeledContent("Existing data") {
            Button("Delete All…", role: .destructive) { showingDeleteConfirm = true }
                .disabled(history.entryCount == 0 && history.pairCount == 0)
        }
        Text(summary).font(.caption).foregroundStyle(.secondary)
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
            Text("Type `:name` and Tab to insert 🚀, or common emoticons like :-) ;-) <3 which convert automatically.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            PaneHeader(anchor: .emoji)
        }
        Section("Customization") {
            Picker("Preferred skin tone", selection: $settings.emojiSkinTone) {
                ForEach(SkinTone.allCases, id: \.rawValue) { tone in
                    Text(tone.label).tag(tone.rawValue)
                }
            }
            Text("Applied to emoji that support skin-tone modifiers.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Power-saving behavior in Low Power Mode.
struct BatteryPane: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Section {
            Label(PowerMonitor.shared.isLowPower
                  ? "Low Power Mode is on — these settings are active."
                  : "These settings take effect while macOS Low Power Mode is on.",
                  systemImage: "bolt")
                .font(.callout).foregroundStyle(.secondary)
        } header: {
            PaneHeader(anchor: .battery)
        }
        Section("In Low Power Mode") {
            Toggle("Only show completions on demand", isOn: $settings.batteryOnDemandOnly)
            Toggle("Generate slightly shorter completions", isOn: $settings.batteryShorterCompletions)
            Toggle("Fall back to debounced suggestions", isOn: $settings.batteryUseDebounce)
            Text("Reduces power draw. When Apple Intelligence is the engine, impact is minimal; this mainly helps the local model. \"Fall back to debounced suggestions\" automatically steps down from continuous generation (Suggestions ▸ General ▸ Timing) in Low Power Mode, without needing to turn it off manually.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Local usage counters: words completed and suggestion acceptance rate.
struct StatisticsPane: View {
    @ObservedObject var stats = Statistics.shared

    var body: some View {
        Section {
            Text("These numbers are stored only on your Mac and never leave it.")
                .font(.callout).foregroundStyle(.secondary)
        } header: {
            PaneHeader(anchor: .statistics)
        }
        Section("Usage") {
            LabeledContent("Words completed", value: "\(stats.wordsCompleted)")
            LabeledContent("Suggestions shown", value: "\(stats.suggestionsShown)")
            LabeledContent("Suggestions accepted", value: "\(stats.suggestionsAccepted)")
            LabeledContent("Acceptance rate", value: percent(stats.acceptanceRate))
        }
        Section("Suggestion Funnel") {
            LabeledContent("Show rate", value: percent(stats.showRate))
            ForEach(Statistics.FunnelEvent.allCases, id: \.rawValue) { event in
                LabeledContent(event.label, value: "\(stats.funnel[event] ?? 0)")
            }
            Text("Where suggestions die between a model request and the ghost text on screen. A low show rate with high rejection counts points at over-aggressive filtering; high \"input changed\" counts point at latency.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Button("Reset Statistics", role: .destructive) { stats.reset() }
        }
    }

    private func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
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
                        Text("TabType").font(.title2).bold()
                        Text("Free, open-source, on-device autocomplete for macOS.")
                            .font(.callout).foregroundStyle(.secondary)
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
            Text("MIT licensed. Inspired by Cotypist; built in the open, more permissive than AGPL alternatives.")
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
        ("Apple Foundation Models & Vision", "On-device AI completions and OCR — Apple Inc."),
        ("MLX Swift", "Local model inference on Apple silicon — Apple / ml-explore"),
        ("mlx-swift-lm", "LLM model implementations — ml-explore"),
        ("swift-transformers", "Hugging Face model download — Hugging Face"),
        ("Qwen2.5", "Local base models — Alibaba (Apache-2.0)"),
        ("gemoji", "Emoji shortcode dataset — GitHub (MIT)"),
        ("FrequencyWords", "Autocorrect frequency lists — Hermit Dave (MIT)"),
        ("SymSpell algorithm", "Symmetric-delete spelling correction — Wolf Garbe (MIT)"),
    ]
}
