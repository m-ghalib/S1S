import Foundation

/// Detects the Mac's hardware and recommends the best local model that fits
/// comfortably while keeping autocomplete latency low.
enum HardwareInfo {
    /// Physical RAM in gigabytes.
    static var ramGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// Chip brand string, e.g. "Apple M4 Pro".
    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// The recommended model id for this machine's RAM. Unified memory on Apple
    /// Silicon is shared with the GPU, so we leave generous headroom for the OS
    /// and other apps while still using a capable model.
    static var recommendedModelId: String {
        // Tiers balance quality against autocomplete latency. Qwen3-4B-Instruct-2507
        // is the default across capable Macs — a newer generation than Qwen2.5 with
        // markedly better short-form continuation, non-thinking (never emits
        // reasoning), ~2.3 GB, and fast enough for inline use. Smaller Macs fall
        // back to lighter instruct models. Instruct variants get a real chat-template
        // prompt (see Predictor.swift), matching Cotypist's approach.
        let ram = ramGB
        switch ram {
        // 24 GB+ gets the 8-bit quant of the same model: higher-precision weights
        // measurably reduce wrong-token completions, and on M-Pro-class chips the
        // 4B model decodes at near-parity between 4-bit and 8-bit.
        case 24...: return "mlx-community/Qwen3-4B-Instruct-2507-8bit"
        case 16...: return "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        case 8...:  return "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        default:    return "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        }
    }

    /// Human-readable rationale for the recommendation.
    static var recommendationReason: String {
        "\(chip) · \(ramGB) GB RAM"
    }
}
