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
/// Reusable KV prefix cache. Consecutive keystrokes share almost their entire
/// prompt (chat template header + system prompt + context + all-but-the-last-few
/// typed characters), so instead of re-prefilling hundreds of static tokens per
/// call, keep the KV state and prefill only the divergent suffix.
///
/// Not thread-safe by itself: safety comes from `ModelContainer` serializing
/// `perform` calls and from `Predictor.isGenerating` allowing one generation at a
/// time. Mutated only inside `container.perform`.
final class PromptCache: @unchecked Sendable {
    var cache: [KVCache] = []
    var tokens: [Int] = []      // prompt tokens currently materialized in `cache`
    var modelId: String = ""    // invalidate when the loaded model changes

    func reset() {
        cache = []
        tokens = []
    }
}

@MainActor
final class Predictor {
    private let provider: ModelProvider
    private var generation = 0
    private let promptCache = PromptCache()

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

    /// Whether the currently loaded model is a legacy base model (raw token
    /// continuation, no chat template, no system prompt). Determines both the
    /// prompt body format and the tokenization path in `generate`.
    private var isBaseModel: Bool {
        ModelCatalog.all.first(where: { $0.id == provider.readyModelId })?.isBase ?? true
    }

    /// Invalidate any in-flight prediction's result (does not tear down GPU work).
    func cancel() { generation += 1 }

    /// Predict a short continuation for `request`. Returns nil if the model isn't
    /// ready or nothing useful was produced by the time this call itself is waiting
    /// on. A request that arrives while busy is coalesced (see `onLateSuggestion`)
    /// rather than dropped.
    func predict(request: CompletionRequest) async -> String? {
        guard provider.container != nil else { return nil }
        let context = PromptBuilder.body(request, cap: PromptBuilder.defaultCap, chatFormat: !isBaseModel)
        guard !context.isEmpty else { return nil }

        guard !isGenerating else {
            pendingRequest = request
            pendingGeneration = generation
            Log.shared.debug("predict: local model busy, coalescing latest request")
            Statistics.shared.record(.coalescedBusy)
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
            Statistics.shared.record(.watchdogTimeout)
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
        if superseded {
            Statistics.shared.record(.superseded)
        } else if result == nil || result?.isEmpty == true {
            Statistics.shared.record(.generatedEmpty)
        }

        // Tail-call: run the newest coalesced request now that we're free, unless it
        // was itself superseded before it ever got a turn.
        if let pending = pendingRequest, pendingGeneration >= myGen {
            pendingRequest = nil
            Task { [weak self] in
                guard let self else { return }
                let pendingContext = PromptBuilder.body(pending, cap: PromptBuilder.defaultCap,
                                                        chatFormat: !self.isBaseModel)
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

    /// Mild penalty only: autocomplete SHOULD reuse names/terms already present in
    /// the user's text, and higher values (the old 1.15) suppress exactly those.
    nonisolated private static let repetitionPenalty: Float = 1.05


    /// The actual MLX generation call — instruct models get a real system/user chat
    /// template; legacy base models keep raw token continuation. Prefill cost is
    /// amortized via `PromptCache`: only the tokens that differ from the previous
    /// call's prompt are fed through the model.
    private func generate(context: String, request: CompletionRequest,
                          container: ModelContainer) async -> String? {
        let isBase = isBaseModel
        let maxTokens = request.maxTokens
        let maxWords = request.maxWords
        let temperature = Float(request.temperature)
        let systemPrompt = CompletionInstructions.system(personalExamples: request.personalExamples)
        let modelId = provider.readyModelId ?? ""
        // A timed-out generation may still be running and mutating the shared cache
        // (MLX streams can't be cancelled mid-flight) — never share KV state with it.
        let hasZombie = consecutiveTimeouts > 0
        let pc = promptCache
        let verbose = AppSettings.shared.verboseLog

        return try? await container.perform { ctx -> String? in
            var params = GenerateParameters()
            params.maxTokens = maxTokens
            params.temperature = temperature
            params.repetitionPenalty = Self.repetitionPenalty

            let ids: [Int]
            if isBase {
                ids = ctx.tokenizer.encode(text: context)
            } else {
                do {
                    let messages: [Tokenizers.Message] = [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user", "content": context],
                    ]
                    ids = try ctx.tokenizer.applyChatTemplate(messages: messages)
                } catch {
                    Log.shared.debug("applyChatTemplate failed (\(error)), falling back to raw continuation")
                    ids = ctx.tokenizer.encode(text: context)
                }
            }
            guard !ids.isEmpty else { return nil }

            // --- KV prefix cache: reuse the longest common token prefix. ---
            if hasZombie || pc.modelId != modelId || pc.cache.isEmpty {
                pc.reset()
                pc.cache = ctx.model.newCache(parameters: params)
                pc.modelId = modelId
                Task { @MainActor in Statistics.shared.record(.cacheReset) }
            }
            var common = 0
            let maxCommon = min(pc.tokens.count, ids.count - 1)   // must feed ≥1 token
            while common < maxCommon, pc.tokens[common] == ids[common] { common += 1 }
            if common < pc.tokens.count {
                // Discard the divergent cached suffix; rebuild from scratch if the
                // cache can't trim that much.
                let need = pc.tokens.count - common
                if trimPromptCache(pc.cache, numTokens: need) < need {
                    pc.reset()
                    pc.cache = ctx.model.newCache(parameters: params)
                    common = 0
                    Task { @MainActor in Statistics.shared.record(.cacheReset) }
                } else {
                    pc.tokens = Array(pc.tokens.prefix(common))
                }
            }

            let suffix = Array(ids[common...])
            if verbose {
                Log.shared.debug("cache: reused \(common)/\(ids.count) tokens, prefilling \(suffix.count)")
            }
            let genStart = Date()
            let input = LMInput(tokens: MLXArray(suffix.map { Int32($0) }))

            // Custom TokenIterator so the StartGuard logit processor can veto bad
            // FIRST tokens (immediate EOS → empty suggestion; "Sorry" reply-drift)
            // at the sampler, instead of only filtering afterwards. Chains the
            // parameter-derived processor (repetition penalty) inside.
            var guardIds: [Int] = []
            if let eos = ctx.tokenizer.eosTokenId { guardIds.append(eos) }
            // Unambiguous reply-openers only — "Yes"/"No"/"I" are legitimate
            // continuations and must never be banned at the sampler. Each opener is
            // encoded in its bare, space- and newline-prefixed variants because BPE
            // assigns them different ids; only single-token bans are meaningful (a
            // multi-token word's first piece is a shared subword — banning it would
            // veto unrelated legitimate continuations).
            for opener in ["Sorry", " Sorry", "\nSorry", "Sure", " Sure", "\nSure",
                           "Certainly", " Certainly", "\nCertainly",
                           "Hello", " Hello", "\nHello", "Hi", " Hi", "\nHi"] {
                let toks = ctx.tokenizer.encode(text: opener, addSpecialTokens: false)
                guard toks.count == 1, let only = toks.first, !guardIds.contains(only) else {
                    if verbose, toks.count > 1 {
                        Log.shared.debug("startguard: \"\(opener)\" is \(toks.count) tokens — not banned (its first piece is a shared subword)")
                    }
                    continue
                }
                guardIds.append(only)
                if verbose { Log.shared.debug("startguard: banning token \(only) = \"\(opener)\"") }
            }
            let iterator = try TokenIterator(
                input: input, model: ctx.model, cache: pc.cache,
                processor: StartGuardProcessor(bannedFirst: guardIds, wrapped: params.processor()),
                sampler: params.sampler(),
                prefillStepSize: params.prefillStepSize,
                maxTokens: params.maxTokens)
            let result = MLXLMCommon.generate(input: input, context: ctx, iterator: iterator) { (tokens: [Int]) in
                // Early stop instead of always burning the full token budget:
                // SuggestionTrimmer keeps only the first line and at most `maxWords`
                // words, so anything past a newline, scaffold leakage ("Input:"),
                // or the word cap is pure wasted decode time. The suggestion is
                // ≤ maxTokens tokens, so re-decoding each step is trivial.
                let text = ctx.tokenizer.decode(tokenIds: tokens)
                if text.contains("\n") || text.contains("Input:") { return .stop }
                if text.split(separator: " ", omittingEmptySubsequences: true).count > maxWords + 2 {
                    return .stop
                }
                return .more
            }
            let text = result.output
            if verbose {
                let genMs = Int(Date().timeIntervalSince(genStart) * 1000)
                let outTokens = (pc.cache.first?.offset ?? 0) - ids.count
                Log.shared.debug("gen: \(genMs)ms total (prefill \(suffix.count) + decode \(max(0, outTokens)) tokens)")
            }

            // Trim the generated tokens back off so the cache holds exactly this
            // prompt — the next call's common prefix is then the whole shared prompt.
            let extra = (pc.cache.first?.offset ?? 0) - ids.count
            if extra >= 0, extra == 0 || trimPromptCache(pc.cache, numTokens: extra) >= extra {
                pc.tokens = ids
            } else {
                pc.reset()
            }
            return SuggestionTrimmer.trim(text, maxWords: maxWords)
        }
    }
}

/// Vetoes bad FIRST tokens at the sampler: an immediate EOS (empty suggestion) or
/// a "Sorry"-style reply opener never gets sampled at all. Subsequent tokens pass
/// through untouched; the wrapped processor (repetition penalty) always runs.
final class StartGuardProcessor: LogitProcessor {
    private let bannedFirst: [Int32]
    private var wrapped: LogitProcessor?
    private var step = 0

    init(bannedFirst: [Int], wrapped: LogitProcessor?) {
        self.bannedFirst = bannedFirst.map(Int32.init)
        self.wrapped = wrapped
    }

    func prompt(_ prompt: MLXArray) {
        step = 0
        wrapped?.prompt(prompt)
    }

    func process(logits: MLXArray) -> MLXArray {
        var logits = wrapped?.process(logits: logits) ?? logits
        if step == 0, !bannedFirst.isEmpty {
            logits[.ellipsis, MLXArray(bannedFirst)] = MLXArray(-Float.infinity)
        }
        return logits
    }

    func didSample(token: MLXArray) {
        step += 1
        wrapped?.didSample(token: token)
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
        // 2) Cut at the first sentence terminator (keep it) — but only when it
        //    actually ends a sentence: end of text, or a space followed by a new
        //    capitalized sentence. Abbreviations ("e.g. the plan") and decimals
        //    ("2.5") survive; the word cap below still bounds the length.
        var searchFrom = s.startIndex
        while let idx = s[searchFrom...].firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            let next = s.index(after: idx)
            let rest = s[next...].drop(while: { $0 == " " })
            if next == s.endIndex || rest.isEmpty || (s[next] == " " && rest.first!.isUppercase) {
                s = String(s[...idx])
                break
            }
            searchFrom = next
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
