import Foundation
import MLX
import MLXLMCommon
import Tokenizers

/// Produces a short text continuation for the given context using the loaded MLX model.
///
/// Design notes learned the hard way:
///  - Instruct-tuned models (the default catalog tier, see `ModelCatalog.isBase`) are
///    prompted with a real system + user chat template via `Tokenizer.applyChatTemplate`
///    — matching how Cotypist itself actually completes text (reverse-engineered from
///    its installed binary: it runs instruct models through a real chat-template
///    prompt, not raw base-model continuation). Legacy base models already downloaded
///    before this switch keep using raw token continuation (no chat template) so
///    nothing already installed breaks.
///  - NEVER breaks out of the generation stream early: MLX keeps computing on the GPU
///    after the consumer stops, and abandoning it mid-flight segfaults. `maxTokens`
///    keeps each generation short, and a wall-clock watchdog (below) only stops
///    *waiting* for a stuck generation — it never cancels the underlying stream.
///  - Cancellation is cooperative via a generation token, not by tearing down the
///    stream — a superseded prediction still finishes (quickly) but its result is
///    discarded.
///  - A generation dropped for being "busy" is never lost: at most one newest request
///    is coalesced and automatically retried the moment the in-flight one finishes. If
///    that happens after the original caller already gave up, the result is delivered
///    via `onLateSuggestion` instead of a direct return.
@MainActor
final class Predictor {
    private let provider: ModelProvider
    private var generation = 0

    /// True while a generation is actually running on the model container. MLX's
    /// `ModelContainer` serializes `perform` calls, so if we let every keystroke queue
    /// up a new one, generations pile up faster than they can finish. Instead of
    /// dropping new requests outright, the *newest* one is coalesced (below) and
    /// retried automatically once this flips back to false.
    private var isGenerating = false

    /// The newest request received while a generation was already in flight. Only
    /// ever holds one — overwritten, never queued in depth — and drained exactly once
    /// when the current generation completes.
    private var pendingRequest: CompletionRequest?
    private var pendingGeneration = 0

    /// Fires with a suggestion that finished after its original `predict()` caller
    /// already returned (a coalesced retry, or a generation that outlived a watchdog
    /// timeout). The caller re-validates staleness against the current caret position
    /// before showing it.
    var onLateSuggestion: ((String, CompletionRequest) -> Void)?

    /// Generations that hit the watchdog timeout with no successful completion in
    /// between. After a few in a row, the engine is considered wedged.
    private var consecutiveTimeouts = 0
    private(set) var isWedged = false
    private let watchdogTimeoutNanos: UInt64 = 10_000_000_000   // 10s — well above the
    // ~0.5–0.9s typical latency noted in HardwareInfo; a real hang, not just a slow one.
    private let maxConsecutiveTimeouts = 3

    init(provider: ModelProvider) {
        self.provider = provider
    }

    /// Invalidate any in-flight prediction's result (does not tear down GPU work).
    func cancel() { generation += 1 }

    /// Predict a short continuation for `request`. Returns nil if the model isn't
    /// ready or nothing useful was produced by the time this call itself is waiting
    /// on. A request that arrives while busy is coalesced (see `onLateSuggestion`)
    /// rather than dropped.
    func predict(request: CompletionRequest) async -> String? {
        guard provider.container != nil else { return nil }
        let context = PromptBuilder.body(request, cap: 1500, screenContextBudget: request.screenContextBudget)
        guard !context.isEmpty else { return nil }

        guard !isGenerating else {
            pendingRequest = request
            pendingGeneration = generation
            Log.shared.debug("predict: local model busy, coalescing latest request")
            return nil
        }
        return await runGeneration(context: context, request: request, isDirectCall: true)
    }

    /// Runs one generation, racing it against a watchdog timeout, then hands off to
    /// `finishGeneration` once it actually completes (immediately, or later if it
    /// outlived the timeout).
    private func runGeneration(context: String, request: CompletionRequest,
                                isDirectCall: Bool) async -> String? {
        guard let container = provider.container else { return nil }
        generation += 1
        let myGen = generation
        isGenerating = true

        let genTask = Task<String?, Never> { [weak self] in
            await self?.generate(context: context, request: request, container: container)
        }

        let (result, timedOut) = await race(genTask, timeoutNanos: watchdogTimeoutNanos)

        if timedOut {
            consecutiveTimeouts += 1
            Log.shared.debug("predict: generation exceeded \(watchdogTimeoutNanos / 1_000_000_000)s (consecutive: \(consecutiveTimeouts))")
            if consecutiveTimeouts >= maxConsecutiveTimeouts {
                isWedged = true
                Log.shared.info("local engine appears wedged after \(consecutiveTimeouts) consecutive timeouts — disabling until relaunch")
            }
            // The abandoned genTask is left running (breaking it off mid-flight
            // segfaults MLX); fold its eventual result in via the normal completion
            // path once it actually finishes, whenever that is.
            Task { [weak self] in
                guard let self else { return }
                let late = await genTask.value
                await self.finishGeneration(result: late, myGen: myGen, request: request, isDirectCall: false)
            }
            return nil
        }

        return await finishGeneration(result: result, myGen: myGen, request: request, isDirectCall: isDirectCall)
    }

    /// Called exactly once per generation, only once it has actually completed
    /// (whether within the watchdog window or later). Clears the busy gate, discards
    /// superseded results, drains any coalesced pending request, and — for a call that
    /// isn't the direct return path anymore — delivers the result via
    /// `onLateSuggestion`.
    @discardableResult
    private func finishGeneration(result: String?, myGen: Int, request: CompletionRequest,
                                   isDirectCall: Bool) async -> String? {
        // A generation that actually finishes (fast or late) proves the pipe isn't
        // dead, regardless of which branch got us here.
        consecutiveTimeouts = 0
        isWedged = false
        isGenerating = false

        let superseded = myGen != generation
        let trimmed = superseded ? nil : result

        // Tail-call: run the newest coalesced request now that we're free, unless it
        // was itself superseded before it ever got a turn.
        if let pending = pendingRequest, pendingGeneration >= myGen {
            pendingRequest = nil
            Task { [weak self] in
                guard let self else { return }
                let pendingContext = PromptBuilder.body(pending, cap: 1500, screenContextBudget: pending.screenContextBudget)
                guard !pendingContext.isEmpty else { return }
                _ = await self.runGeneration(context: pendingContext, request: pending, isDirectCall: false)
            }
        }

        if isDirectCall {
            return trimmed
        }
        if let trimmed { onLateSuggestion?(trimmed, request) }
        return nil
    }

    /// Awaits `task`, or gives up waiting after `timeoutNanos` — without ever
    /// cancelling `task` itself, since MLX segfaults if its stream is abandoned
    /// mid-flight. The task keeps running independently and can still be awaited
    /// again later by the caller.
    private func race(_ task: Task<String?, Never>,
                       timeoutNanos: UInt64) async -> (result: String?, timedOut: Bool) {
        await withTaskGroup(of: (String?, Bool).self) { group in
            group.addTask {
                (await task.value, false)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return (nil, true)
            }
            let first = await group.next() ?? (nil, true)
            group.cancelAll()   // only cancels these wrapper tasks, never `task` itself
            return first
        }
    }

    /// The actual MLX generation call — instruct models get a real system/user chat
    /// template; legacy base models keep raw token continuation.
    private func generate(context: String, request: CompletionRequest,
                          container: ModelContainer) async -> String? {
        let isBase = ModelCatalog.all.first(where: { $0.id == provider.readyModelId })?.isBase ?? true
        let maxTokens = request.maxTokens
        let maxWords = request.maxWords
        let temperature = Float(request.temperature)

        return try? await container.perform { ctx -> String? in
            var params = GenerateParameters()
            params.maxTokens = maxTokens
            params.temperature = temperature
            params.repetitionPenalty = 1.15

            let ids: [Int]
            if isBase {
                ids = ctx.tokenizer.encode(text: context)
            } else {
                do {
                    let messages: [Tokenizers.Message] = [
                        ["role": "system", "content": CompletionInstructions.system],
                        ["role": "user", "content": context],
                    ]
                    ids = try ctx.tokenizer.applyChatTemplate(messages: messages)
                } catch {
                    Log.shared.debug("applyChatTemplate failed (\(error)), falling back to raw continuation")
                    ids = ctx.tokenizer.encode(text: context)
                }
            }
            guard !ids.isEmpty else { return nil }
            let input = LMInput(tokens: MLXArray(ids.map { Int32($0) }))
            let stream = try MLXLMCommon.generate(
                input: input, parameters: params, context: ctx)

            var text = ""
            for await item in stream {
                if case .chunk(let s) = item { text += s }
            }
            return SuggestionTrimmer.trim(text, maxWords: maxWords)
        }
    }
}

/// Trims a raw continuation into a short, Cotypist-like suggestion.
enum SuggestionTrimmer {
    static func trim(_ raw: String, maxWords: Int) -> String? {
        // 1) One line only.
        var s = raw
        if let nl = s.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            s = String(s[..<nl])
        }
        // 2) Cut at the first sentence terminator (keep it).
        if let idx = s.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            s = String(s[...idx])
        }
        // 3) Cap word count, preserving a leading space if present.
        let leadingSpace = s.first == " " ? " " : ""
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        if words.count > maxWords {
            s = leadingSpace + words.prefix(maxWords).joined(separator: " ")
        }
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
        // Reject degenerate suggestions (blanks, pure punctuation/underscores).
        let meaningful = trimmed.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return meaningful.isEmpty ? nil : trimmed
    }
}
