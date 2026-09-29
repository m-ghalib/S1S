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
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// The recommended model id for this Mac: the most accurate of the three
    /// simple choices that fits in memory and suggests quickly on this chip.
    /// See `ModelAdvisor.recommended(chip:ramGB:)`.
    static var recommendedModelId: String {
        ModelAdvisor.recommended(chip: chip, ramGB: ramGB).modelId
    }

    /// Human-readable rationale for the recommendation.
    static var recommendationReason: String {
        "\(chip) · \(ramGB) GB memory"
    }
}
