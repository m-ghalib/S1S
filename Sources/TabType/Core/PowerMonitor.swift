import Foundation

/// Tracks Low Power Mode so the engine can back off on battery (longer debounce,
/// pause screen capture). The Apple Intelligence path is light, so this mainly
/// protects battery when the local MLX engine + OCR are active.
@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()

    private(set) var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    @objc private func powerStateChanged() {
        let now = ProcessInfo.processInfo.isLowPowerModeEnabled
        if now != isLowPower {
            isLowPower = now
            Log.shared.info("power: low-power mode \(now ? "ON" : "off")")
        }
    }

    /// Extra debounce (ms) to add when on Low Power Mode.
    var extraDebounceMs: Int { isLowPower ? 200 : 0 }
    /// Whether background screen capture should be paused.
    var shouldPauseCapture: Bool { isLowPower }
}
