import Foundation

/// Completion engine backed by a local MLX model (instruct models via chat template,
/// legacy base models via raw continuation — see `Predictor`). Wraps `Predictor` +
/// `ModelProvider`.
@MainActor
final class MLXEngine: SuggestionEngine {
    let displayName = "Local model"

    private let provider: ModelProvider
    private let predictor: Predictor

    var onLateSuggestion: ((String, CompletionRequest) -> Void)?

    init(provider: ModelProvider) {
        self.provider = provider
        self.predictor = Predictor(provider: provider)
        predictor.onLateSuggestion = { [weak self] text, request in
            self?.onLateSuggestion?(text, request)
        }
    }

    /// False if no model is loaded, or the local engine has wedged after repeated
    /// watchdog timeouts (see `Predictor`) — lets `EngineRouter` hand off to another
    /// engine instead of silently producing nothing until relaunch.
    var isReady: Bool { provider.isReady && !predictor.isWedged }

    func cancelInFlight() { predictor.cancel() }

    func complete(_ request: CompletionRequest) async -> String? {
        await predictor.predict(request: request)
    }
}
