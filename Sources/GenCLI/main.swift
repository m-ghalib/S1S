// TabType — MLX inference + suggestion-tuning harness.
// Runs the model over several realistic prompts and prints the RAW output vs the
// TRIMMED autocomplete suggestion, so we can tune length/relevance without the GUI.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#if canImport(FoundationModels)
import FoundationModels
#endif

var args = Array(CommandLine.arguments.dropFirst())

// --- Apple Intelligence (FoundationModels) validation path ---
// Usage: tabtype-gencli --ai "the prompt text"
if args.first == "--ai" {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        let prompt = args.dropFirst().first ?? "Dear team, I wanted to follow up on our meeting and"
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let instructions = """
            You complete partially-typed text. You ARE the author, continuing your OWN writing — \
            never reply to it, answer it, or address the reader. Produce only the next few words.
            Output the continuation only: no greeting, no sign-off, no quotes, no labels, no brackets.
            Continue from immediately after the existing text; do not repeat it. If it ends mid-word, finish it.
            Match the existing language, register, casing, and punctuation.

            Examples:
            Input: I just wanted to follow up on the
            Output:  proposal we discussed last week
            Input: The suggestions are not relevant.
            Output:  They don't match what I'm actually typing.
            """
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)
            let start = Date()
            let response = try await session.respond(to: prompt, options: options)
            let dt = Date().timeIntervalSince(start)
            print("AVAILABLE\nPROMPT: \(prompt)\nCOMPLETION: \(response.content)\n(\(String(format: "%.3f", dt))s)")
        case .unavailable(let reason):
            print("UNAVAILABLE: \(reason)")
        }
    } else {
        print("FoundationModels needs macOS 26+")
    }
    #else
    print("FoundationModels not importable in this SDK")
    #endif
    exit(0)
}

let defaultModel = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
var modelId = defaultModel
if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
    modelId = args[i + 1]
    args.removeSubrange(i ... (i + 1))
}

// Trim a raw continuation down to a short, Cotypist-like suggestion.
func trimSuggestion(_ raw: String, maxWords: Int = 7) -> String {
    // 1) One line only.
    var s = raw
    if let nl = s.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
        s = String(s[..<nl])
    }
    // 2) Cut at the first sentence terminator (keep the terminator).
    if let idx = s.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
        s = String(s[...idx])
    }
    // 3) Cap word count (counting whitespace-separated words), preserving a leading space.
    let leadingSpace = s.first == " " ? " " : ""
    let words = s.split(separator: " ", omittingEmptySubsequences: true)
    if words.count > maxWords {
        s = leadingSpace + words.prefix(maxWords).joined(separator: " ")
    }
    return s
}

FileHandle.standardError.write("Loading \(modelId) …\n".data(using: .utf8)!)
// A local directory (e.g. TabType's model store) loads without downloading.
var isDirectory: ObjCBool = false
let configuration = FileManager.default.fileExists(atPath: modelId, isDirectory: &isDirectory) && isDirectory.boolValue
    ? ModelConfiguration(directory: URL(fileURLWithPath: modelId))
    : ModelConfiguration(id: modelId)
let container = try await #huggingFaceLoadModelContainer(configuration: configuration) { p in
    FileHandle.standardError.write("\r\(Int(p.fractionCompleted * 100))%   ".data(using: .utf8)!)
}
FileHandle.standardError.write("\nready\n".data(using: .utf8)!)

let prompts = args.isEmpty ? [
    "Dear team, I wanted to follow up on our meeting and",
    "Hey, are you free to",
    "Thanks so much for your help with the",
    "I think the best approach here is to",
    "def fibonacci(n):",
    "The weather today is",
] : args

func complete(_ prompt: String, maxTok: Int) async throws -> (String, TimeInterval) {
    let start = Date()
    let out: String = try await container.perform { ctx in
        var params = GenerateParameters()
        params.maxTokens = maxTok
        params.temperature = Float(ProcessInfo.processInfo.environment["TEMP"] ?? "0.1") ?? 0.1
        params.repetitionPenalty = 1.15
        let ids = ctx.tokenizer.encode(text: prompt)
        let input = LMInput(tokens: MLXArray(ids.map { Int32($0) }))
        let stream = try MLXLMCommon.generate(input: input, parameters: params, context: ctx)
        var text = ""
        // Consume the ENTIRE stream — breaking early terminates MLX's GPU work
        // mid-flight and segfaults. maxTokens keeps this short.
        for await item in stream {
            if case .chunk(let s) = item { text += s }
        }
        return text
    }
    return (out, Date().timeIntervalSince(start))
}

// --- KV prefix-cache A/B validation (mirrors Predictor.PromptCache logic) ---
// Usage: tabtype-gencli --model <id> --kvtest
// Simulates consecutive keystrokes (growing prompt, shared system prefix) and checks
// that cached generation (a) matches uncached output exactly, (b) prefills far fewer
// tokens (reported as wall-clock).
if args.contains("--kvtest") {
    let system = """
    You are an inline autocomplete engine. You ARE the author of the text after "Input:". \
    Output only the next few words the author would type.
    """
    let steps = [
        "I just wanted to follow up on the propos",
        "I just wanted to follow up on the proposal we disc",
        "I just wanted to follow up on the proposal we discussed last week and see if",
    ]

    @Sendable func tokenize(_ ctx: ModelContext, _ user: String) throws -> [Int] {
        try ctx.tokenizer.applyChatTemplate(messages: [
            ["role": "system", "content": system],
            ["role": "user", "content": "Input: \(user)\nOutput:"],
        ])
    }

    @Sendable func run(_ ids: [Int], ctx: ModelContext, cache: [KVCache]?, feedFrom: Int) async throws -> String {
        var params = GenerateParameters()
        params.maxTokens = 16
        params.temperature = 0.0   // deterministic for exact comparison
        params.repetitionPenalty = 1.05
        let input = LMInput(tokens: MLXArray(ids[feedFrom...].map { Int32($0) }))
        let stream = try MLXLMCommon.generate(input: input, cache: cache, parameters: params, context: ctx)
        var text = ""
        // Never break early — abandoning the stream mid-flight segfaults MLX.
        for await item in stream {
            if case .chunk(let s) = item { text += s }
        }
        return text
    }

    let pass = try await container.perform { ctx -> Bool in
        var pass = true
        var cachedTokens: [Int] = []
        var kv: [KVCache] = ctx.model.newCache(parameters: nil)
        for (i, step) in steps.enumerated() {
            let ids = try tokenize(ctx, step)

            // Uncached reference.
            let t0 = Date()
            let ref = try await run(ids, ctx: ctx, cache: nil, feedFrom: 0)
            let tRef = Date().timeIntervalSince(t0)

            // Cached: trim divergent suffix, feed only new tokens.
            var common = 0
            let maxCommon = min(cachedTokens.count, ids.count - 1)
            while common < maxCommon, cachedTokens[common] == ids[common] { common += 1 }
            if common < cachedTokens.count {
                let need = cachedTokens.count - common
                if trimPromptCache(kv, numTokens: need) < need {
                    kv = ctx.model.newCache(parameters: nil); cachedTokens = []; common = 0
                } else { cachedTokens = Array(cachedTokens.prefix(common)) }
            }
            let t1 = Date()
            let out = try await run(ids, ctx: ctx, cache: kv, feedFrom: common)
            let tCached = Date().timeIntervalSince(t1)
            let extra = (kv.first?.offset ?? 0) - ids.count
            if extra > 0 { trimPromptCache(kv, numTokens: extra) }
            cachedTokens = ids

            let match = out == ref
            pass = pass && match
            print("step \(i): prompt=\(ids.count) tok, fed=\(ids.count - common) tok, " +
                  "uncached=\(String(format: "%.0f", tRef * 1000))ms, " +
                  "cached=\(String(format: "%.0f", tCached * 1000))ms, match=\(match)")
            if !match {
                print("  ref:    \(ref.replacingOccurrences(of: "\n", with: "⏎"))")
                print("  cached: \(out.replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
        return pass
    }
    print(pass ? "KVTEST PASS" : "KVTEST FAIL")
    exit(pass ? 0 : 1)
}

// --- GPU buffer-cache growth check ---
// Usage: [CACHE_LIMIT_MB=512] tabtype-gencli --model <id> --memtest [rounds]
// Prefills prompts of varying length (like context switches between apps) and
// prints MLX active/cache memory plus latency. Without CACHE_LIMIT_MB, MLX keeps
// its default cache limit (the memory limit), which is what TabType ran with
// before `Predictor.gpuCacheLimit`.
if let i = args.firstIndex(of: "--memtest") {
    let rounds = (i + 1 < args.count ? Int(args[i + 1]) : nil) ?? 40
    if let limitMB = ProcessInfo.processInfo.environment["CACHE_LIMIT_MB"].flatMap(Int.init) {
        Memory.cacheLimit = limitMB * 1024 * 1024
    }
    let mb = { (bytes: Int) in bytes / (1024 * 1024) }
    let filler = "The quarterly planning review covered hiring, budget, and launch dates for the new release. "
    var latencies: [Double] = []
    for r in 0 ..< rounds {
        // 100…1500 tokens, a different length every round.
        let prompt = String(repeating: filler, count: 6 + (r * 37) % 80) + "Next we should"
        let (_, dt) = try await complete(prompt, maxTok: 8)
        latencies.append(dt)
        print("round \(r): \(Int(dt * 1000))ms  active \(mb(Memory.activeMemory))MB  cache \(mb(Memory.cacheMemory))MB")
    }
    // Round 0 includes warm-up, so leave it out of the average.
    let avg = latencies.dropFirst().reduce(0, +) / Double(max(1, latencies.count - 1))
    print("cacheLimit \(mb(Memory.cacheLimit))MB  avg \(Int(avg * 1000))ms  final cache \(mb(Memory.cacheMemory))MB  peak \(mb(Memory.peakMemory))MB")
    exit(0)
}

// --- Instruct-model check through the chat template (mirrors Predictor) ---
// Usage: [SYSTEM_FILE=prompt.txt] tabtype-gencli --model <id> --chat [prompts…]
// Prints each suggestion with prefill and decode speed, and flags models that emit
// <think> reasoning instead of a continuation.
if let i = args.firstIndex(of: "--chat") {
    args.remove(at: i)
    let system = ProcessInfo.processInfo.environment["SYSTEM_FILE"]
        .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        ?? "You are an inline autocomplete engine. You ARE the author of the text after \"Input:\". Output only the next few words the author would type."
    let inputs = args.isEmpty ? Array(prompts.prefix(4)) : args
    for (n, text) in ([inputs[0]] + inputs).enumerated() {   // first run warms up
        let (output, info): (String, GenerateCompletionInfo?) = try await container.perform { ctx in
            let ids = try ctx.tokenizer.applyChatTemplate(messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": "Input: \(text)\nOutput:"],
            ], tools: nil, additionalContext: ["enable_thinking": false])
            var params = GenerateParameters()
            params.maxTokens = 16
            params.temperature = 0
            params.repetitionPenalty = 1.05
            let input = LMInput(tokens: MLXArray(ids.map { Int32($0) }))
            var out = ""
            var info: GenerateCompletionInfo?
            // Never break early — abandoning the stream mid-flight segfaults MLX.
            for await item in try MLXLMCommon.generate(input: input, parameters: params, context: ctx) {
                switch item {
                case .chunk(let s): out += s
                case .info(let i): info = i
                default: break
                }
            }
            return (out, info)
        }
        guard n > 0, let info else { continue }
        let flag = output.contains("<think>") || output.contains("Thinking Process") ? "  THINKING" : ""
        print("\(text) → \(output.replacingOccurrences(of: "\n", with: "⏎"))\(flag)")
        print(String(format: "  prefill %d tok @ %.0f tok/s, decode %d tok @ %.1f tok/s",
                     info.promptTokenCount, info.promptTokensPerSecond,
                     info.generationTokenCount, info.tokensPerSecond))
    }
    exit(0)
}

// Warm up.
_ = try await complete("Hello", maxTok: 4)

for p in prompts {
    let (raw, dt) = try await complete(p, maxTok: 16)
    print("\nPROMPT:     \(p)")
    print("RAW:        \(raw.replacingOccurrences(of: "\n", with: "⏎"))")
    print("SUGGESTION: \(trimSuggestion(raw))")
    print("(\(String(format: "%.3f", dt))s)")
}
