import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Completion engine backed by Apple Intelligence's on-device model
/// (FoundationModels, macOS 26+). Highest quality, no download, fully private.
@available(macOS 26.0, *)
@MainActor
final class FoundationModelEngine: SuggestionEngine {
    let displayName = "Apple Intelligence"

    private var generation = 0
    private var loggedInstructions = false
    var onLateSuggestion: ((String, CompletionRequest) -> Void)?

    var isReady: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    func cancelInFlight() { generation += 1 }

    func complete(_ request: CompletionRequest) async -> String? {
        #if canImport(FoundationModels)
        guard isReady else { return nil }
        generation += 1
        let myGen = generation

        if !loggedInstructions {
            loggedInstructions = true
            Log.shared.info("model instructions (Apple Intelligence system message):\n---\n\(CompletionInstructions.system)\n---")
        }

        let body = PromptBuilder.body(request, cap: PromptBuilder.defaultCap, chatFormat: true)
        guard !body.isEmpty else { return nil }

        // Fresh session per call: no transcript carry-over between independent
        // completions.
        let session = LanguageModelSession(
            instructions: CompletionInstructions.system(personalExamples: request.personalExamples))
        // Greedy decoding for low temperature gives the most predictable completion.
        let options: GenerationOptions = request.temperature <= 0.15
            ? GenerationOptions(sampling: .greedy, maximumResponseTokens: request.maxTokens)
            : GenerationOptions(temperature: request.temperature,
                                maximumResponseTokens: request.maxTokens)

        do {
            let response = try await session.respond(to: body, options: options)
            if myGen != generation { return nil }   // superseded
            return SuggestionTrimmer.trim(response.content, maxWords: request.maxWords)
        } catch {
            Log.shared.debug("FoundationModels error: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }
}
