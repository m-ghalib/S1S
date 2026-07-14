import Foundation

enum EngineChoice: String, CaseIterable {
    case auto           // Apple Intelligence if available, else local
    case appleIntelligence
    case local
}

/// Selects the active `SuggestionEngine` from settings and hardware availability.
@MainActor
final class EngineRouter {
    private let settings: AppSettings
    private let mlx: MLXEngine
    private var foundation: SuggestionEngine?

    /// Fires with a suggestion that finished after its original caller already gave up
    /// (see `Predictor.onLateSuggestion`). Forwarded from whichever engine supports it.
    var onLateSuggestion: ((String, CompletionRequest) -> Void)? {
        didSet {
            mlx.onLateSuggestion = onLateSuggestion
            foundation?.onLateSuggestion = onLateSuggestion
        }
    }

    init(settings: AppSettings, provider: ModelProvider) {
        self.settings = settings
        self.mlx = MLXEngine(provider: provider)
        if #available(macOS 26.0, *) {
            self.foundation = FoundationModelEngine()
        }
    }

    /// The engine to use right now.
    var current: SuggestionEngine {
        switch settings.engineChoice {
        case .local:
            // Local is preferred, but hand off to Apple Intelligence if the local
            // model isn't ready yet (not downloaded) or has wedged (Predictor) rather
            // than silently producing nothing.
            if mlx.isReady { return mlx }
            if let f = foundation, f.isReady { return f }
            return mlx
        case .appleIntelligence, .auto:
            if let f = foundation, f.isReady { return f }
            return mlx
        }
    }

    /// Whether Apple Intelligence is usable on this machine.
    var appleIntelligenceAvailable: Bool { foundation?.isReady ?? false }

    func cancelInFlight() {
        foundation?.cancelInFlight()
        mlx.cancelInFlight()
    }
}
