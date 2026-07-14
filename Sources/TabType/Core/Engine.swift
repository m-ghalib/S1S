import AppKit
import ApplicationServices

/// Central orchestrator: wires keystrokes → context → prediction → ghost-text
/// overlay → Tab-to-accept. Runs entirely on the main actor (the event tap is
/// serviced on the main run loop).
@MainActor
final class Engine {
    private let settings: AppSettings
    private let provider: ModelProvider
    private let router: EngineRouter
    private let monitor = KeystrokeMonitor()
    private let overlay = SuggestionOverlay()
    private let inlineCommand: InlineCommandController
    private let accessory = AccessoryButton()

    /// Fallback context buffer, used when the Accessibility API can't provide the
    /// focused field's text. Rebuilt on focus change.
    private var buffer = ""
    private var currentSuggestion: String?
    private var debounceWork: DispatchWorkItem?
    private var lastFocusedPID: pid_t = 0
    private var lastPredictedPrompt: String = ""
    private(set) var pausedUntil: Date?
    private var scheduleToken = 0
    /// AX text length captured at keydown (before the app processes the key), so we
    /// can poll until the keystroke actually lands in the field ("host publish").
    private var hostBaselineLen: Int?

    private(set) var isRunning = false

    init(settings: AppSettings = .shared, provider: ModelProvider = .shared) {
        self.settings = settings
        self.provider = provider
        self.router = EngineRouter(settings: settings, provider: provider)
        self.inlineCommand = InlineCommandController(settings: settings)
    }

    /// Start monitoring. Returns false if the event tap couldn't be created
    /// (usually missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        wireCallbacks()
        guard monitor.start() else { return false }
        isRunning = true
        return true
    }

    /// Pause suggestions for `minutes`, or indefinitely if nil, until `resume()`.
    func pause(minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) } ?? .distantFuture
        clearSuggestion()
    }

    func resume() {
        pausedUntil = nil
    }

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return Date() < until
    }

    func stop() {
        monitor.stop()
        clearSuggestion()
        isRunning = false
    }

    // MARK: - Callback wiring

    private func wireCallbacks() {
        accessory.onClick = {
            NotificationCenter.default.post(name: .tabTypeOpenSettings, object: nil)
        }
        monitor.onEdit = { chars, isDeletion, _ in
            MainActor.assumeIsolated { self.handleEdit(chars: chars, isDeletion: isDeletion) }
        }
        monitor.handleControlKey = { keyCode, flags in
            MainActor.assumeIsolated { self.handleControlKey(keyCode: keyCode, flags: flags) }
        }
        router.onLateSuggestion = { [weak self] raw, req in
            self?.handleLateSuggestion(raw: raw, req: req)
        }
    }

    /// Map a keydown against configured shortcut bindings and navigation keys.
    private func handleControlKey(keyCode: Int64, flags: CGEventFlags) -> ControlDecision {
        // Global enable/disable toggle.
        if settings.toggleKey.matches(keyCode: keyCode, flags: flags) {
            settings.isEnabled.toggle()
            return .swallow
        }
        // Per-app override: some apps need Tab to keep its native meaning (e.g. IDEs).
        let tabDisabled = keyCode == 48
            && AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId()).disableTabKey

        // Accept whole suggestion.
        if settings.acceptAllKey.matches(keyCode: keyCode, flags: flags) {
            if tabDisabled { return .passthrough }
            return acceptCurrent(whole: true) ? .swallow : .passthrough
        }
        // Accept a word (or an inline command). Honors the "accept whole" preference.
        if settings.acceptWordKey.matches(keyCode: keyCode, flags: flags) {
            if tabDisabled { return .passthrough }
            return acceptCurrent(whole: settings.acceptWholeLine) ? .swallow : .passthrough
        }
        // Dismiss.
        if settings.dismissKey.matches(keyCode: keyCode, flags: flags) {
            if inlineCommand.isActive || currentSuggestion != nil {
                if inlineCommand.isActive { inlineCommand.cancel() }
                clearSuggestion()
                if settings.escapeBehavior == "pause" {
                    pausedUntil = Date().addingTimeInterval(5)   // brief pause after Esc
                }
                return .swallow
            }
            return .passthrough
        }
        // While an emoji picker is active, Up/Down cycle the highlighted candidate
        // instead of cancelling the session and moving the real caret.
        if inlineCommand.isActive, keyCode == 126 || keyCode == 125 {
            let delta = keyCode == 126 ? -1 : 1
            if inlineCommand.moveSelection(by: delta, caretRect: {
                AccessibilityBridge.focusedElement().flatMap { AccessibilityBridge.caretRect(of: $0) }
            }) {
                return .swallow
            }
        }
        // Navigation / editing keys that invalidate a shown suggestion but pass through.
        let navKeys: Set<Int64> = [36, 123, 124, 125, 126, 116, 121, 115, 119] // return, arrows, page/home/end
        if navKeys.contains(keyCode) {
            if inlineCommand.isActive { inlineCommand.cancel() }
            clearSuggestion()
            return .passthrough
        }
        return .notControl
    }

    // MARK: - Editing

    private func handleEdit(chars: String, isDeletion: Bool) {
        // Track focus changes to reset the fallback buffer and enable enhanced
        // accessibility for Electron/Chromium apps (Slack, VS Code, browsers…).
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if pid != lastFocusedPID {
            lastFocusedPID = pid
            buffer = ""
            if pid != 0 { AccessibilityBridge.enableEnhancedAccessibility(pid: pid) }
            updateAccessoryButton()

            // Kick off screen-memory capture right away on focus change rather than
            // waiting for the next runPrediction() cycle — otherwise the very first
            // suggestion in a freshly-focused window has no completed capture yet.
            let policy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
            if (settings.useScreenContext || policy.forceScreenContext) && policy.includesScreenContext {
                ScreenContextProvider.shared.refreshIfStale()
            }
        }

        // Maintain fallback buffer.
        if isDeletion {
            if !buffer.isEmpty { buffer.removeLast() }
        } else {
            buffer += chars
        }

        // Inline commands (:emoji / macro) take priority over LLM suggestions.
        let commandActive = inlineCommand.handleEdit(
            chars: chars, isDeletion: isDeletion,
            caretRect: {
                AccessibilityBridge.focusedElement().flatMap { AccessibilityBridge.caretRect(of: $0) }
            })
        if commandActive {
            router.cancelInFlight()
            overlay.hide()
            currentSuggestion = nil
            debounceWork?.cancel()
            return
        }

        // Any edit invalidates the shown suggestion.
        clearSuggestion()

        let bundleId = AccessibilityBridge.frontmostBundleId()
        let policy = AppPolicyStore.policy(forBundleId: bundleId)
        guard policy.isEnabled,
              settings.isEnabled(forBundleId: bundleId) else { return }

        // On a word boundary: replace an emoticon, else autocorrect the finished word.
        let autocorrectAllowed = policy.autocorrectOverride ?? settings.autocorrectEnabled
        if !isDeletion, let ch = chars.last, ch == " " || ch == "\n" {
            if !(settings.emoticonsEnabled && replaceEmoticon(boundary: ch)), autocorrectAllowed {
                maybeAutocorrect()
            }
        }

        guard router.current.isReady else { return }

        // Snapshot AX text length *now* — the tap fires before the app inserts the
        // key, so this is the pre-keystroke length. We poll until it changes.
        hostBaselineLen = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.stringValue(of: $0)?.count }

        schedulePrediction()
    }

    /// Wait for the keystroke to appear in the AX tree (host-publish), then predict.
    /// Polls on the main run loop without blocking; a token cancels stale schedules.
    ///
    /// In continuous mode (default), the "settle" wait is just long enough for the
    /// keystroke to land in the AX tree — a prediction is requested on essentially
    /// every keystroke, and `Predictor`'s coalescing (busy-gate + latest-request-wins)
    /// collapses a fast-typing burst down to one generation at a time, so suggestions
    /// keep pace with typing instead of only appearing once it pauses. In debounced
    /// mode (opt-out, or automatic on battery — see `batteryUseDebounce`), the full
    /// idle-wait behavior is preserved.
    private func schedulePrediction() {
        debounceWork?.cancel()
        scheduleToken += 1
        let token = scheduleToken
        let start = Date()

        func poll(_ delay: Double) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, token == self.scheduleToken else { return }
                let elapsed = Date().timeIntervalSince(start)
                if self.hostPublished() || elapsed > 0.4 {
                    self.runPrediction()
                } else {
                    poll(0.025)
                }
            }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        let useContinuous = settings.continuousGeneration
            && !(PowerMonitor.shared.isLowPower && settings.batteryUseDebounce)
        if useContinuous {
            poll(0.02)   // minimal settle — just a chance for host-publish, no idle-wait
        } else {
            // Initial settle = the configured debounce (+ battery back-off), then fast polls.
            let baseDebounce = settings.labsUltraFastDebounce ? 40 : settings.debounceMs
            let settle = baseDebounce + PowerMonitor.shared.extraDebounceMs
            poll(Double(settle) / 1000.0)
        }
    }

    /// If the token just before the boundary is a known emoticon (":-)"), replace it
    /// with the emoji. Returns true if a replacement was made.
    private func replaceEmoticon(boundary: Character) -> Bool {
        guard buffer.count >= 2 else { return false }
        let withoutBoundary = String(buffer.dropLast())
        guard let token = withoutBoundary.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
              let emoji = Emoticons.emoji(for: String(token)) else { return false }
        let deleteCount = token.count + 1   // token + boundary
        buffer = String(buffer.dropLast(deleteCount)) + emoji + String(boundary)
        DispatchQueue.main.async {
            TextInserter.backspace(count: deleteCount)
            TextInserter.insert(emoji + String(boundary), strategy: .keystroke)
        }
        return true
    }

    /// Correct the word just before the trailing boundary in the buffer, if SymSpell
    /// finds a confident fix. Applied asynchronously and only if the buffer tail is
    /// still intact (the user hasn't typed past it).
    private func maybeAutocorrect() {
        // buffer currently ends with the boundary char just typed.
        guard buffer.count >= 4 else { return }
        let withoutBoundary = String(buffer.dropLast())
        guard let word = withoutBoundary.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
              word.count >= 3, word.allSatisfy({ $0.isLetter }) else { return }
        let wordStr = String(word)
        let boundary = String(buffer.last!)
        let expectedSuffix = wordStr + boundary

        // Don't touch secure fields.
        if let f = AccessibilityBridge.focusedElement(), AccessibilityBridge.isSecureField(f) { return }

        SpellChecker.shared.correct(wordStr, language: settings.autocorrectLanguage) { [weak self] corrected in
            guard let self, let corrected else { return }
            guard self.buffer.hasSuffix(expectedSuffix) else { return }  // tail unchanged
            let deleteCount = expectedSuffix.count
            self.buffer = String(self.buffer.dropLast(deleteCount)) + corrected + boundary
            TextInserter.backspace(count: deleteCount)
            TextInserter.insert(corrected + boundary, strategy: .keystroke)
            Log.shared.debug("autocorrect: \(wordStr) -> \(corrected)")
        }
    }

    /// Reject/strip suggestions that just repeat what the user already typed. Returns
    /// the (possibly trimmed) suggestion, or nil if it's a pure echo.
    nonisolated static func stripEcho(_ suggestion: String, prefix: String) -> String? {
        let sug = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sug.isEmpty else { return nil }
        let tail = String(prefix.suffix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return suggestion }

        let sugLower = sug.lowercased()
        let tailLower = tail.lowercased()
        // Pure echo: the suggestion is (part of) the end of what was typed.
        if tailLower.hasSuffix(sugLower) || sugLower == tailLower { return nil }
        // Overlap: suggestion starts by repeating the tail's last words → strip it.
        if sugLower.hasPrefix(tailLower), sug.count > tail.count {
            let stripped = String(sug.dropFirst(tail.count))
            return stripped.isEmpty ? nil : stripped
        }
        return suggestion
    }

    /// Reply-opener phrases that signal the model answered instead of continuing the
    /// user's text (assistant-persona drift). Checked case-insensitively against the
    /// start of the (trimmed) suggestion.
    nonisolated private static let assistantSpeakPrefixes: [String] = [
        "i'm sorry", "i am sorry", "i apologize", "i understand", "i see that",
        "sure,", "sure!", "sure.", "of course,", "certainly,",
        "yes,", "yes.", "no,", "no.",
        "as an ai", "as a language model",
        "unfortunately", "thanks for", "thank you for",
        "great question", "that's a great",
    ]

    /// Reject suggestions that read like an assistant reply rather than a continuation
    /// of the user's own text. Returns the suggestion unchanged, or nil to reject.
    nonisolated static func stripAssistantSpeak(_ suggestion: String) -> String? {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in assistantSpeakPrefixes where lower.hasPrefix(prefix) {
            return nil
        }
        return suggestion
    }

    /// Reconcile a suggestion's leading boundary against the char before the caret so
    /// accepting never merges words (or doubles spaces). Only handles the unambiguous
    /// whitespace-boundary case; the letter/number-boundary case is ambiguous (same-word
    /// completion vs. new word) and is resolved by `reconcileMidWord` instead, which can
    /// actually distinguish the two via the plausibility dictionary.
    nonisolated static func reconcile(_ suggestion: String, prefix: String) -> String {
        var s = suggestion
        guard let prev = prefix.last, prev.isWhitespace else { return s }
        while let f = s.first, f == " " { s.removeFirst() }
        return s
    }

    /// Resolves a suggestion's leading boundary when the caret sits right after a
    /// letter/number — the case `reconcile` can't disambiguate on its own. Tries the
    /// same-word completion first (no space — e.g. "the" + "n" → "then", matching what
    /// the model is explicitly instructed to do when it ends mid-word); if that's
    /// implausible, reinterprets the fragment as a new word (space inserted) instead of
    /// just discarding it; only rejects if neither reading is plausible.
    private func reconcileMidWord(_ suggestion: String, prefix: String, elapsedMs: UInt64) async -> String? {
        let noLeadingSpace = suggestion.hasPrefix(" ") ? String(suggestion.dropFirst()) : suggestion
        guard !noLeadingSpace.isEmpty else { return nil }

        guard !settings.labsDisableMidWordGuard else {
            return suggestion.isEmpty ? nil : suggestion   // trust the model's own formatting
        }

        let partial = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        let fragment = String(noLeadingSpace.prefix { $0.isLetter || $0 == "'" })

        let sameWordPlausible = await SpellChecker.shared.isPlausibleContinuation(
            partial: partial, fragment: fragment, language: settings.autocorrectLanguage)
        if sameWordPlausible {
            return noLeadingSpace   // direct append — completes the current word
        }

        let newWordPlausible = await SpellChecker.shared.isPlausibleContinuation(
            partial: "", fragment: fragment, language: settings.autocorrectLanguage)
        guard newWordPlausible else {
            Log.shared.debug("predict -> (mid-word implausible: \(partial)+\(fragment)) (\(elapsedMs)ms)")
            return nil
        }
        return " " + noLeadingSpace
    }

    /// Gate junk predictions: need at least a couple of meaningful characters and a
    /// sensible boundary (don't fire mid-URL or right after a bare `/@`).
    nonisolated static func shouldPredict(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        if let last = input.last, "/@".contains(last) { return false }
        if let lastWord = input.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
           lastWord.contains("://") {
            return false
        }
        return true
    }

    /// True once the field's AX text reflects the latest keystroke (or AX text isn't
    /// available, in which case the keystroke buffer is the source of truth).
    private func hostPublished() -> Bool {
        guard let baseline = hostBaselineLen,
              let element = AccessibilityBridge.focusedElement(),
              let len = AccessibilityBridge.stringValue(of: element)?.count else {
            return true
        }
        return len != baseline
    }

    private func runPrediction() {
        let front = NSWorkspace.shared.frontmostApplication
        let frontApp = front?.localizedName
        let bundleId = front?.bundleIdentifier
        let policy = AppPolicyStore.policy(forBundleId: bundleId)
        guard policy.isEnabled else { return }

        // Paused after Escape, or conserving battery (on-demand only).
        if let until = pausedUntil, Date() < until { return }
        if PowerMonitor.shared.isLowPower && settings.batteryOnDemandOnly { return }

        // Per-domain disable (browsers).
        if !settings.disabledDomains.isEmpty, let host = AccessibilityBridge.frontmostURLHost(),
           settings.disabledDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            Log.shared.debug("predict skipped: disabled domain \(host)")
            return
        }

        // Screen memory (throttled, off the typing path), unless this app opts out or
        // we're conserving battery. Chat/messaging apps force this on regardless of
        // the global toggle — reading recent conversation is the whole point there.
        let screenContextEnabled = (settings.useScreenContext || policy.forceScreenContext)
            && policy.includesScreenContext
        if screenContextEnabled && !PowerMonitor.shared.shouldPauseCapture {
            ScreenContextProvider.shared.refreshIfStale()
        }
        _ = frontApp
        let screenContext = screenContextEnabled
            ? ScreenContextProvider.shared.contextText(cap: policy.screenContextCap ?? 600) : ""

        let ctx = ContextReader.gather(
            fallbackBuffer: buffer,
            screenContext: screenContext,
            inputChars: settings.contextChars)
        guard ctx.hasInput, Engine.shouldPredict(ctx.input) else { return }

        // Require an actual focused element — like Cotypist, never suggest when
        // nothing is focused/selected (even if the keystroke buffer has text, e.g.
        // from typing over a non-text control or between fields).
        guard ctx.focused != nil else {
            Log.shared.debug("predict skipped: no focused element")
            return
        }

        // Never autocomplete a password field.
        if policy.excludesSecureField, let f = ctx.focused, AccessibilityBridge.isSecureField(f) {
            Log.shared.debug("predict skipped: secure field in \(bundleId ?? "?")")
            return
        }

        // Per-app "mid-line completions" override.
        if !policy.allowsMidLine, let f = ctx.focused, AccessibilityBridge.hasTextAfterCaret(of: f) {
            Log.shared.debug("predict skipped: mid-line disabled for \(bundleId ?? "?")")
            return
        }

        if settings.collectTypingHistory && settings.storeInputsWithoutAcceptedCompletions {
            TypingHistoryStore.shared.record(String(ctx.input.suffix(120)))
        }

        // Skip redundant work if nothing changed since the last prediction.
        if ctx.prompt == lastPredictedPrompt { return }
        lastPredictedPrompt = ctx.prompt

        let engine = router.current
        let clipboard = settings.useClipboardContext
            ? String((NSPasteboard.general.string(forType: .string) ?? "").prefix(300)) : ""
        let persona = policy.customInstructions.isEmpty
            ? settings.personaPreface
            : settings.personaPreface + " " + policy.customInstructions
        let req = CompletionRequest(
            beforeCursor: ctx.input,
            afterCursor: ctx.afterCursor,
            screenContext: screenContext,
            clipboard: clipboard,
            persona: persona,
            screenContextBudget: policy.screenContextCap ?? 700,
            maxWords: (PowerMonitor.shared.isLowPower && settings.batteryShorterCompletions)
                ? min(settings.maxWords, 3) : settings.maxWords,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature)
        Log.shared.debug("predict app=\(bundleId ?? "?") engine=\(engine.displayName) focused=\(ctx.focused != nil) screenCtx=\(screenContext.count) inputTail=\"\(String(ctx.input.suffix(40)))\"")
        if settings.verboseLog {
            let fullPrompt = PromptBuilder.body(req, cap: 1500, screenContextBudget: req.screenContextBudget)
            Log.shared.debug("predict full prompt:\n---\n\(fullPrompt)\n---")
        }
        let startedAt = DispatchTime.now()

        Task { [weak self] in
            guard let self else { return }
            let raw = await engine.complete(req)
            await self.handlePredictionResult(
                raw: raw, req: req, ctxInput: ctx.input, policy: policy, startedAt: startedAt)
        }
    }

    /// Shared post-processing for a raw model output: echo/assistant-speak rejection,
    /// word-boundary reconciliation, the mid-word plausibility guard, and finally
    /// showing the suggestion. Used both for the direct `runPrediction()` path and for
    /// a coalesced request that completes later (`handleLateSuggestion`).
    private func handlePredictionResult(raw: String?, req: CompletionRequest, ctxInput: String,
                                        policy: AppPolicy, startedAt: DispatchTime) async {
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        if settings.verboseLog {
            Log.shared.debug("predict raw model output (pre-post-processing): \(raw.map { "\"\($0)\"" } ?? "nil")")
        }
        guard let raw, !raw.isEmpty else {
            Log.shared.debug("predict -> (no suggestion) (\(elapsedMs)ms)")
            return
        }
        // Drop echoes (the model repeating what was just typed), then reject
        // assistant-speak/reply-drift, then reconcile the word boundary so
        // accepting never merges into the prefix.
        guard let deEchoed = Engine.stripEcho(raw, prefix: ctxInput) else {
            Log.shared.debug("predict -> (echo rejected) (\(elapsedMs)ms)")
            return
        }
        guard let clean = Engine.stripAssistantSpeak(deEchoed) else {
            Log.shared.debug("predict -> (assistant-speak rejected) (\(elapsedMs)ms)")
            return
        }
        var suggestion = Engine.reconcile(clean, prefix: ctxInput)
        guard !suggestion.isEmpty else { return }

        // Letter/number boundary is ambiguous (same-word completion vs. new word) —
        // resolve it via the plausibility dictionary rather than always forcing a
        // space, which used to destroy correct mid-word completions like "the"+"n".
        if let lastWord = ctxInput.last, lastWord.isLetter || lastWord.isNumber {
            guard let resolved = await reconcileMidWord(suggestion, prefix: ctxInput, elapsedMs: elapsedMs) else {
                return
            }
            suggestion = resolved
        }

        // Resolve placement NOW (fresh), not before generation — otherwise the
        // caret rect is ~0.4s stale and the ghost lands on the wrong line.
        let element = AccessibilityBridge.focusedElement()
        let inlineCaret = element.flatMap { AccessibilityBridge.caretRect(of: $0) }
        let windowRect = element.flatMap { ContextReader.windowRect(of: $0) }
        let mode = inlineCaret != nil ? "inline" : "hud"
        Log.shared.debug("predict -> \"\(suggestion)\" [\(mode)] (\(elapsedMs)ms)")
        present(suggestion: suggestion, inlineCaret: inlineCaret, windowRect: windowRect, policy: policy)
    }

    /// A coalesced local-model request finished after its original `runPrediction()`
    /// caller already gave up (see `Predictor.onLateSuggestion`). Only shown if the
    /// caret prefix still matches what it was generated for — never shows a
    /// suggestion behind what's since been typed.
    private func handleLateSuggestion(raw: String, req: CompletionRequest) {
        if let until = pausedUntil, Date() < until { return }
        let ctx = ContextReader.gather(
            fallbackBuffer: buffer, screenContext: req.screenContext, inputChars: settings.contextChars)
        guard ctx.input == req.beforeCursor else {
            Log.shared.debug("predict -> (late suggestion stale, discarded)")
            return
        }
        let policy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
        guard policy.isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.handlePredictionResult(
                raw: raw, req: req, ctxInput: ctx.input, policy: policy, startedAt: DispatchTime.now())
        }
    }

    /// Display the suggestion: inline ghost text when we have precise caret bounds,
    /// otherwise a HUD pill anchored to the focused window (Electron/Catalyst apps).
    private func present(suggestion: String, inlineCaret: CGRect?, windowRect: CGRect?,
                         policy: AppPolicy = AppPolicy(), isNewSuggestion: Bool = true) {
        currentSuggestion = suggestion
        if isNewSuggestion { Statistics.shared.recordShown() }
        if let caretRect = inlineCaret {
            // Match the field's real font when available; fall back to a caret-height guess.
            let element = AccessibilityBridge.focusedElement()
            let caret = element.flatMap { AccessibilityBridge.caretOffset(of: $0) } ?? 0
            let axFont = element.flatMap { AccessibilityBridge.fontAtCaret(of: $0, caret: caret) }
            let base = axFont ?? NSFont.systemFont(ofSize: max(11, caretRect.height * policy.fontSizeRatio))
            let font = NSFont(descriptor: base.fontDescriptor,
                              size: base.pointSize * policy.fontFactor) ?? base
            let anchored = caretRect.offsetBy(dx: 0, dy: policy.verticalOffset)
            Log.shared.debug("placement app=\(AccessibilityBridge.frontmostBundleId() ?? "?") caretRect=\(caretRect) axFont=\(axFont != nil ? "yes(\(axFont!.pointSize)pt)" : "no, using \(base.pointSize)pt heuristic") fontFactor=\(policy.fontFactor) verticalOffset=\(policy.verticalOffset) anchored=\(anchored)")
            // Screenshot-assisted colour so ghost text blends with the field's text.
            var color: NSColor?
            if settings.useScreenshotAppearance {
                GhostAppearanceProbe.shared.refresh(caretRect: caretRect)
                color = GhostAppearanceProbe.shared.current?.ghostColor
            }
            overlay.showInline(text: suggestion, at: anchored, font: font,
                               opacity: settings.ghostOpacity, color: color)
        } else {
            overlay.showHUD(text: suggestion, windowRect: windowRect)
        }
    }

    // MARK: - Accept / dismiss

    /// Accept the current inline command or LLM suggestion. Returns true if something
    /// was accepted (so the key is swallowed). `whole` = accept the entire suggestion.
    private func acceptCurrent(whole: Bool) -> Bool {
        // Inline command (emoji/macro) takes priority over LLM suggestions.
        if inlineCommand.isActive {
            if let (deleteCount, insert) = inlineCommand.accept() {
                buffer = String(buffer.dropLast(deleteCount)) + insert
                DispatchQueue.main.async {
                    TextInserter.backspace(count: deleteCount)
                    TextInserter.insert(insert, strategy: .keystroke)
                }
                return true
            }
            inlineCommand.cancel()
            return false
        }

        guard let suggestion = currentSuggestion, !suggestion.isEmpty else { return false }

        let toInsert: String
        let remainder: String
        if whole {
            toInsert = suggestion
            remainder = ""
        } else {
            var split = TextInserter.firstWord(of: suggestion)
            var accepted = split.accepted
            var rest = split.remainder
            // Optionally hold back trailing punctuation (…"word?" → "word" + "?").
            if !settings.includeTrailingPunctuation {
                var trimmed = accepted
                while let last = trimmed.last, last.isPunctuation || last == "?" || last == "!" {
                    rest = String(last) + rest
                    trimmed.removeLast()
                }
                if !trimmed.isEmpty { accepted = trimmed }
            }
            // Optionally hold back the trailing space.
            if !settings.includeTrailingSpace, accepted.hasSuffix(" ") {
                accepted.removeLast()
                rest = " " + rest
            }
            toInsert = accepted
            remainder = rest
            _ = split
        }

        overlay.hide()
        currentSuggestion = remainder.isEmpty ? nil : remainder
        buffer += toInsert
        let strategy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
            .insertionStrategy
        let wordCount = toInsert.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        Statistics.shared.recordAccepted(wordCount: max(wordCount, toInsert.isEmpty ? 0 : 1))
        if settings.collectTypingHistory {
            TypingHistoryStore.shared.record(toInsert)
        }

        // Insert on the next tick so we return from the tap callback first.
        DispatchQueue.main.async {
            TextInserter.insert(toInsert, strategy: strategy)
            if remainder.isEmpty {
                // Suggestion exhausted — speculatively fetch the next continuation so it
                // appears sooner than waiting for the next keystroke's debounce.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    guard self.currentSuggestion == nil else { return }
                    self.runPrediction()
                }
                return
            }
            // The synthesized keystrokes are processed by the target app slightly
            // after we post them, so wait a beat before re-reading the caret — then
            // the remaining ghost text moves to the NEW caret position.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard self.currentSuggestion == remainder else { return }
                let element = AccessibilityBridge.focusedElement()
                let caretRect = element.flatMap { AccessibilityBridge.caretRect(of: $0) }
                let windowRect = element.flatMap { ContextReader.windowRect(of: $0) }
                self.present(suggestion: remainder, inlineCaret: caretRect, windowRect: windowRect,
                             isNewSuggestion: false)
            }
        }
        return true
    }

    private func updateAccessoryButton() {
        guard settings.showAccessoryButton,
              let element = AccessibilityBridge.focusedElement(),
              let windowRect = ContextReader.windowRect(of: element) else {
            accessory.hide(); return
        }
        accessory.show(near: windowRect)
    }

    private func clearSuggestion() {
        debounceWork?.cancel()
        scheduleToken += 1   // invalidate any in-flight host-publish poll
        router.cancelInFlight()
        currentSuggestion = nil
        overlay.hide()
    }
}
