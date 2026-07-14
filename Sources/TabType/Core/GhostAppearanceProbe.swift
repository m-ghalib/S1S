import AppKit
import ScreenCaptureKit

/// Samples the pixels around the caret to match ghost text to the field's real
/// appearance (like Cotypist's "use screenshots to improve suggestion appearance").
/// Determines the text (foreground) colour and background, and derives a dimmed
/// ghost colour that blends. Throttled + cached so it never blocks typing.
@MainActor
final class GhostAppearanceProbe: ObservableObject {
    static let shared = GhostAppearanceProbe()

    struct Appearance {
        var ghostColor: NSColor
        var textColor: NSColor
        var isDark: Bool
    }

    private var cached: Appearance?
    private var lastProbe = Date.distantPast
    private var probing = false
    private let minInterval: TimeInterval = 1.0

    private init() {}

    /// The most recent probed appearance (may be nil until the first probe lands).
    var current: Appearance? { cached }

    /// Kick a probe of the caret line if stale. Non-blocking; updates `cached`.
    func refresh(caretRect: CGRect) {
        guard CGPreflightScreenCaptureAccess(), !probing,
              Date().timeIntervalSince(lastProbe) > minInterval,
              caretRect.width.isFinite, caretRect.height > 1 else { return }
        probing = true
        lastProbe = Date()

        // Sample a strip to the LEFT of the caret (where existing text sits).
        let h = min(max(caretRect.height, 10), 60)
        let sample = CGRect(x: max(0, caretRect.minX - 220), y: caretRect.minY,
                            width: 220, height: h)

        Task.detached(priority: .utility) {
            let appearance = await GhostAppearanceProbe.sample(rect: sample)
            await MainActor.run {
                self.probing = false
                if let appearance { self.cached = appearance }
            }
        }
    }

    // MARK: - Sampling

    nonisolated private static func sample(rect: CGRect) async -> Appearance? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            // Find the display containing the caret (rect is top-left global coords).
            guard let display = content.displays.first(where: {
                displayRectTopLeft($0).intersects(rect)
            }) ?? content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // Capture just the sample strip (sourceRect is in points, top-left origin
            // relative to the display).
            let local = CGRect(x: rect.minX - display.frame.minX,
                               y: rect.minY - displayRectTopLeft(display).minY,
                               width: rect.width, height: rect.height)
            config.sourceRect = local
            config.width = Int(rect.width * 2)
            config.height = Int(rect.height * 2)
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            return analyze(image)
        } catch {
            return nil
        }
    }

    /// Convert an SCDisplay frame to Quartz top-left global coords.
    nonisolated private static func displayRectTopLeft(_ d: SCDisplay) -> CGRect {
        // SCDisplay.frame is already in the top-left global space used by AX rects.
        d.frame
    }

    /// Estimate background (modal colour) and foreground (most-contrasting) from the
    /// image, then blend a dimmed ghost colour.
    nonisolated private static func analyze(_ image: CGImage) -> Appearance? {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        // Histogram of coarse-quantised colours to find the background (most common).
        var counts: [UInt32: Int] = [:]
        func rgba(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let o = y * bpr + x * bpp
            return (Double(ptr[o]) / 255, Double(ptr[o + 1]) / 255, Double(ptr[o + 2]) / 255)
        }
        let stepX = max(1, w / 60), stepY = max(1, h / 20)
        var samples: [(Double, Double, Double)] = []
        for y in stride(from: 0, to: h, by: stepY) {
            for x in stride(from: 0, to: w, by: stepX) {
                let (r, g, b) = rgba(x, y)
                samples.append((r, g, b))
                let key = (UInt32(r * 7) << 6) | (UInt32(g * 7) << 3) | UInt32(b * 7)
                counts[key, default: 0] += 1
            }
        }
        guard let bgKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = (Double((bgKey >> 6) & 7) / 7, Double((bgKey >> 3) & 7) / 7, Double(bgKey & 7) / 7)

        // Foreground = the sampled pixel with the greatest luminance distance from bg.
        func lum(_ c: (Double, Double, Double)) -> Double { 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2 }
        let bgLum = lum(bg)
        var fg = bg
        var maxDist = 0.0
        for s in samples {
            let d = abs(lum(s) - bgLum)
            if d > maxDist { maxDist = d; fg = s }
        }
        // If there's basically no text in the strip, bail (keep previous/ default).
        guard maxDist > 0.12 else { return nil }

        let isDark = bgLum < 0.5
        // Ghost = the real foreground color at reduced alpha (applied by the caller
        // via `settings.ghostOpacity`), NOT blended toward the background in RGB
        // space — that crushes saturation/chroma and reads as flat gray instead of a
        // dimmed version of the actual ink color.
        return Appearance(
            ghostColor: NSColor(srgbRed: fg.0, green: fg.1, blue: fg.2, alpha: 1),
            textColor: NSColor(srgbRed: fg.0, green: fg.1, blue: fg.2, alpha: 1),
            isDark: isDark)
    }
}
