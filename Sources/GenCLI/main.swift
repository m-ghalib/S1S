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
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
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
let container = try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(id: modelId)) { p in
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

// Warm up.
_ = try await complete("Hello", maxTok: 4)

for p in prompts {
    let (raw, dt) = try await complete(p, maxTok: 16)
    print("\nPROMPT:     \(p)")
    print("RAW:        \(raw.replacingOccurrences(of: "\n", with: "⏎"))")
    print("SUGGESTION: \(trimSuggestion(raw))")
    print("(\(String(format: "%.3f", dt))s)")
}
