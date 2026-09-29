import Foundation

/// Picks a local model for people who don't know model names. Offers three plain
/// choices (Fastest, Balanced, Most accurate), estimates how long each takes to
/// suggest on this Mac, checks whether each fits in memory, and recommends one.
///
/// Pure logic keyed on the chip brand string and RAM, so it is unit-tested with
/// fixed hardware (see `ModelAdvisorTests`). Assumes Apple Silicon MacBooks.
enum ModelAdvisor {

    enum Choice: String, CaseIterable, Identifiable {
        case fastest, balanced, accurate
        var id: String { rawValue }

        var title: String {
            switch self {
            case .fastest: return "Fastest"
            case .balanced: return "Balanced"
            case .accurate: return "Most accurate"
            }
        }

        var summary: String {
            switch self {
            case .fastest: return "Good suggestions for everyday email, chat, and notes."
            case .balanced: return "Better at longer, more specific sentences. Slower."
            case .accurate: return "Fewest wrong words. Slowest, and uses the most memory and battery."
            }
        }

        var modelId: String {
            switch self {
            case .fastest: return "mlx-community/Qwen3.5-2B-4bit"
            case .balanced: return "mlx-community/Qwen3.5-4B-4bit"
            case .accurate: return "mlx-community/Qwen3.5-9B-4bit"
            }
        }

        /// Size of the weights on disk and in memory, in GB.
        var weightsGB: Double {
            switch self {
            case .fastest: return 1.75
            case .balanced: return 3.06
            case .accurate: return 5.98
            }
        }

        /// Relative suggestion accuracy, 1–5. A ranking by model size within one
        /// family, not a measured rate: all three gave sensible suggestions in the
        /// harness, and larger Qwen3.5 models make fewer wrong-word picks.
        var accuracy: Int {
            switch self {
            case .fastest: return 3
            case .balanced: return 4
            case .accurate: return 5
            }
        }

        static func matching(modelId: String) -> Choice? {
            allCases.first { $0.modelId == modelId }
        }
    }

    enum Fit: Equatable {
        case comfortable   // leaves plenty of memory for other apps
        case tight         // runs, but other apps may slow down
        case tooLarge      // not offered
    }

    // MARK: Hardware

    /// Approximate memory bandwidth for a chip brand string such as "Apple M4 Pro".
    /// Token generation is bandwidth-bound, so this drives the speed estimate.
    /// Binned Max chips use the lower figure. Unknown future chips use the newest
    /// known generation of the same tier.
    static func memoryBandwidthGBs(chip: String) -> Double {
        let name = chip.replacingOccurrences(of: "Apple ", with: "")
        // A-series MacBooks (for example MacBook Neo, A18 Pro).
        if name.hasPrefix("A") { return 60 }
        guard name.hasPrefix("M"),
              let generation = Int(name.dropFirst().prefix { $0.isNumber }) else { return 100 }
        let tier: Int
        if name.contains("Max") {
            tier = 2
        } else if name.contains("Pro") {
            tier = 1
        } else {
            tier = 0
        }
        //                     base  Pro  Max
        let table: [Int: [Double]] = [
            1: [68, 200, 400],
            2: [100, 200, 400],
            3: [100, 150, 300],
            4: [120, 273, 410],
            5: [153, 307, 460],
        ]
        let newest = table.keys.max()!
        return table[min(generation, newest)]![tier]
    }

    // MARK: Estimates

    /// Typical time from pause to visible suggestion, in milliseconds.
    ///
    /// Qwen3.5 can't reuse the prompt cache (see `ModelCatalog.all`), so every
    /// suggestion prefills the whole ~860-token prompt and then decodes ~8 tokens.
    /// Measured with `s1s-gencli --chat` on an M1 Max (400 GB/s): prefill
    /// 940 / 395 / 205 tok/s and decode 38 / 29 / 30 tok/s for 2B / 4B / 9B.
    /// Other chips scale by memory bandwidth, which tracks GPU size across the
    /// base, Pro, and Max tiers.
    static func estimatedLatencyMs(_ choice: Choice, bandwidthGBs: Double) -> Int {
        let referenceMs: Double
        switch choice {
        case .fastest: referenceMs = 1130
        case .balanced: referenceMs = 2450
        case .accurate: referenceMs = 4460
        }
        return Int((referenceMs * 400 / bandwidthGBs).rounded())
    }

    /// Weights plus KV cache and GPU buffers must stay a small share of unified memory,
    /// which the OS and every other app also use.
    static func fit(_ choice: Choice, ramGB: Int) -> Fit {
        let need = choice.weightsGB * 1.3
        let ram = Double(ramGB)
        if need <= ram * 0.30 { return .comfortable }
        if need <= ram * 0.45 { return .tight }
        return .tooLarge
    }

    /// Suggestions slower than this feel laggy while typing. No Qwen3.5 choice meets
    /// it on current MacBooks, so today this always recommends Fastest; the rule
    /// picks a larger model once prompt caching makes one fast enough.
    static let latencyBudgetMs = 750

    /// The most accurate choice that fits comfortably and stays within the latency
    /// budget; Fastest when nothing else qualifies.
    static func recommended(chip: String, ramGB: Int) -> Choice {
        let bandwidth = memoryBandwidthGBs(chip: chip)
        return Choice.allCases.reversed().first {
            fit($0, ramGB: ramGB) == .comfortable
                && estimatedLatencyMs($0, bandwidthGBs: bandwidth) <= latencyBudgetMs
        } ?? .fastest
    }

    // MARK: Labels

    /// "Balanced model" for the simple choices, else the catalog name, else the repo name.
    static func displayName(for modelId: String) -> String {
        if let choice = Choice.matching(modelId: modelId) { return "\(choice.title) model" }
        if let model = ModelCatalog.known(modelId) { return model.name }
        return modelId.split(separator: "/").last.map(String.init) ?? modelId
    }

    /// "about 0.3 seconds", rounded to a tenth.
    static func latencyText(ms: Int) -> String {
        let seconds = max(0.1, (Double(ms) / 100).rounded() / 10)
        return String(format: "about %.1f seconds", seconds)
    }

    /// Speed on the same 1–5 scale as accuracy, for a side-by-side meter. The
    /// seconds label beside it gives the absolute figure.
    static func speedScore(ms: Int) -> Int {
        switch ms {
        case ..<700: return 5
        case ..<1200: return 4
        case ..<2000: return 3
        case ..<3500: return 2
        default: return 1
        }
    }

    static func accuracyText(_ score: Int) -> String {
        switch score {
        case ...1: return "Basic"
        case 2: return "Fair"
        case 3: return "Good"
        case 4: return "Very good"
        default: return "Best"
        }
    }
}
