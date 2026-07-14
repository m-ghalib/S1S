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
        // Tiers balance quality against autocomplete latency (measured on M-series):
        // 3B ≈ 0.5s/suggestion, 7B ≈ 0.9s — instruct variants are the same parameter
        // counts as the base models these figures were measured on. Instruct models are
        // used by default so the local engine gets a real chat-template prompt (see
        // Predictor.swift), matching Cotypist's own approach rather than raw
        // base-model continuation.
        let ram = ramGB
        switch ram {
        case 32...: return "mlx-community/Qwen2.5-7B-Instruct-4bit"
        case 16...: return "mlx-community/Qwen2.5-3B-Instruct-4bit"
        case 8...:  return "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        default:    return "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        }
    }

    /// Human-readable rationale for the recommendation.
    static var recommendationReason: String {
        "\(chip) · \(ramGB) GB RAM"
    }
}
