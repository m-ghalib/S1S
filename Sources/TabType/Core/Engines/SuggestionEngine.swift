import Foundation

/// A request to complete text at the caret.
struct CompletionRequest {
    /// Text immediately before the caret (the thing to continue).
    var beforeCursor: String
    /// Text after the caret, sent as fill-in-the-middle context (see `PromptBuilder`).
    var afterCursor: String
    /// Remembered on-screen context (OCR of other windows), may be empty.
    var screenContext: String
    /// Clipboard text, if the user opted in (may be empty).
    var clipboard: String = ""
    /// Short persona preface from personalization settings (may be empty).
    var persona: String = ""
    /// Recent (prefix, accepted-completion) pairs from the user's own history,
    /// rendered as extra few-shot examples in the system prompt.
    var personalExamples: [TypingHistoryStore.AcceptPair] = []
    /// Samples of the author's recent writing (across apps) — voice + topics
    /// context, rendered as `<recently_written_by_author>` in the prompt.
    var previousWriting: [String] = []
    /// Speculative request: generated mid-burst and PARKED for instant serving on
    /// the next pause; its result is never presented directly.
    var speculative: Bool = false
    /// Character budget for screen-memory context in the prompt (chat/messaging apps
    /// get a larger one so more transcript survives — see `AppPolicy.screenContextCap`).
    var screenContextBudget: Int = 700
    /// Display cap on the suggestion.
    var maxWords: Int
    /// Generation cap.
    var maxTokens: Int
    var temperature: Double
}

/// A pluggable text-completion backend (Apple Intelligence, local MLX, …).
@MainActor
protocol SuggestionEngine: AnyObject {
    var displayName: String { get }
    /// Whether this engine can currently produce completions.
    var isReady: Bool { get }
    /// Produce a trimmed, ready-to-show suggestion, or nil.
    func complete(_ request: CompletionRequest) async -> String?
    /// Invalidate any in-flight result (cooperative; must not tear down GPU work).
    func cancelInFlight()
    /// Fires with a suggestion that finished after its original caller already gave up
    /// (e.g. a coalesced retry the local engine ran once it was free). `Engine` re-runs
    /// the normal post-processing/staleness checks before showing it. Engines without a
    /// coalescing mechanism (e.g. Apple Intelligence) simply never call this.
    var onLateSuggestion: ((String, CompletionRequest) -> Void)? { get set }
}
