import AppKit
import ScreenCaptureKit
import Vision

/// Builds a short-lived memory of what's around the text being typed. It captures the
/// **focused window** (matched to the AX focused-window frame), OCRs it locally with
/// Vision, aggressively strips UI chrome and any text that duplicates the focused
/// field's own contents, and keeps a small, tightly time-bounded history per app.
/// Predictions read only the freshest snapshot for the current app — stale or
/// unrelated screen text is worse than none for a small on-device model.
@MainActor
final class ScreenContextProvider: ObservableObject {
    static let shared = ScreenContextProvider()

    struct Entry {
        let time: Date
        let app: String
        let bundleId: String
        let text: String
    }

    private(set) var history: [Entry] = []
    private var lastCaptureStarted = Date.distantPast
    private var capturing = false

    private let minInterval: TimeInterval = 1.5   // throttle captures
    private let maxEntries = 20
    private let maxAge: TimeInterval = 150         // stale screen text is noise, but
                                                   // conversations stay relevant a while
                                                   // and captures don't land every minute

    /// Logged once so a missing permission (which silently zeroes out screen context
    /// forever otherwise) is actually diagnosable instead of invisible.
    private var warnedNoPermission = false

    private init() {}

    // MARK: Permission

    func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: Capture (non-blocking)

    /// Trigger a capture of the focused window (if the throttle interval has elapsed).
    /// Runs off the main thread; never blocks typing/prediction. The focused field's
    /// own text is passed along so the OCR can strip it — the prompt already carries
    /// that text verbatim via accessibility, so re-OCR'ing it only adds noise.
    func refreshIfStale() {
        guard hasPermission() else {
            if !warnedNoPermission {
                warnedNoPermission = true
                Log.shared.info("screen memory: no Screen Recording permission — context will stay empty until granted (Settings ▸ Personalization, or System Settings ▸ Privacy & Security ▸ Screen Recording)")
            }
            return
        }
        guard !capturing, Date().timeIntervalSince(lastCaptureStarted) > minInterval else { return }
        capturing = true
        lastCaptureStarted = Date()

        // Capture the window the user is typing in (like cotabby/KeyType), and pass
        // the focused field's own text so we can strip it from the OCR (we don't want
        // to echo what's already being typed).
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = AccessibilityBridge.focusedElement()
        let fieldText = focused.flatMap { AccessibilityBridge.stringValue(of: $0) } ?? ""
        let caretRect = focused.flatMap { AccessibilityBridge.caretRect(of: $0) }
        let windowFrame = AccessibilityBridge.focusedWindowFrame()
        let cropMode = AppSettings.shared.screenCropMode

        Task.detached(priority: .utility) {
            let capture = await ScreenContextProvider.captureFocusedWindow(
                pid: frontPid, fieldText: fieldText, cropMode: cropMode, caretRect: caretRect, windowFrame: windowFrame)
            await MainActor.run {
                self.capturing = false
                if let (app, bid, text) = capture, text.count >= 12 {
                    self.append(app: app, bundleId: bid, text: text)
                } else {
                    Log.shared.debug("screen memory: capture produced no usable text this round")
                }
            }
        }
    }

    private func append(app: String, bundleId: String, text: String) {
        // Skip if unchanged from the last entry we stored for this app.
        if let last = history.last(where: { $0.app == app }), last.text == text { return }
        history.append(Entry(time: Date(), app: app, bundleId: bundleId, text: text))

        let cutoff = Date().addingTimeInterval(-maxAge)
        history.removeAll { $0.time < cutoff }
        if history.count > maxEntries {
            history.removeFirst(history.count - maxEntries)
        }
        Log.shared.debug("screen memory: +\(text.count) chars from \(app) (bid=\(bundleId)) (entries=\(history.count))")
    }

    /// The freshest OCR snapshot for a specific bundle ID, capped to `cap` characters.
    /// Only the single most recent entry is used — consecutive snapshots of the same
    /// window are near-duplicates that would eat the whole budget — and staleness is
    /// enforced here too (append-time pruning alone lets an old entry linger while
    /// capture is paused).
    func contextText(for bundleId: String?, cap: Int) -> String {
        guard !history.isEmpty, let bundleId else { return "" }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let matching = history.filter { $0.bundleId == bundleId && $0.time >= cutoff }
        Log.shared.debug("screen context requested for bid=\(bundleId), found \(matching.count) fresh entries out of \(history.count) total")
        guard var text = matching.last?.text else { return "" }
        if text.count > cap { text = String(text.suffix(cap)) }
        return text
    }

    /// One-shot diagnostic: capture the frontmost window, OCR it, and log the result
    /// at info level so we can confirm the capture+OCR pipeline works on this machine.
    func selfTest() {
        guard hasPermission() else {
            Log.shared.info("screen self-test: no Screen Recording permission")
            return
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windowFrame = AccessibilityBridge.focusedWindowFrame()
        Task.detached(priority: .utility) {
            if let (app, _, text) = await ScreenContextProvider.captureFocusedWindow(pid: pid, fieldText: "", cropMode: AppSettings.shared.screenCropMode, caretRect: nil, windowFrame: windowFrame) {
                Log.shared.info("screen self-test: OCR \(text.count) chars from \(app) — \"\(text.prefix(60))\"")
            } else {
                Log.shared.info("screen self-test: no content window captured")
            }
        }
    }

    // MARK: Capture + OCR implementation

    /// Apps whose windows are UI chrome, not content — never OCR these.
    nonisolated private static let systemBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.WindowManager", "com.apple.systemuiserver", "com.apple.spotlight",
        "com.apple.wallpaper", "app.tabtype.TabType",
    ]

    /// Capture and OCR the **focused** window (the frontmost app's largest window) —
    /// the context around where the user is typing, like cotabby/KeyType. Strips the
    /// focused field's own text (`fieldText`) so we don't echo what's being typed.
    nonisolated private static func captureFocusedWindow(
        pid: pid_t?, fieldText: String, cropMode: AppSettings.ScreenCropMode, caretRect: CGRect?, windowFrame: CGRect?
    ) async -> (String, String, String)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)

            let candidates = content.windows.filter { w in
                guard w.isOnScreen, w.frame.width > 120, w.frame.height > 80 else { return false }
                if let bid = w.owningApplication?.bundleIdentifier,
                   systemBundleIDs.contains(bid) { return false }
                return true
            }
            
            // First, try to exactly match the window frame provided by the Accessibility API
            var window: SCWindow?
            if let pid = pid, let frame = windowFrame {
                // SCWindow frames and AXWindow frames might have slight differences depending on borders/shadows.
                // We check that the centers are within 100 points, which is robust against shadow insets.
                window = candidates.first { w in
                    w.owningApplication?.processID == pid &&
                    abs(w.frame.midX - frame.midX) < 100 &&
                    abs(w.frame.midY - frame.midY) < 100
                }
            }
            
            // Fallback: The frontmost app's largest window; else the largest overall.
            if window == nil {
                let byArea: (SCWindow, SCWindow) -> Bool = {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                }
                if let pid, let w = candidates.filter({ $0.owningApplication?.processID == pid }).max(by: byArea) {
                    window = w
                } else {
                    window = candidates.max(by: byArea)
                }
            }
            guard let window else { return nil }

            let config = SCStreamConfiguration()
            let scale = 2
            config.width = min(Int(window.frame.width) * scale, 3000)
            config.height = min(Int(window.frame.height) * scale, 3000)
            config.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard var image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) else { return nil }
            
            // Caret cropping: keep only the vertical band around the caret's line.
            // Crop the height ONLY — text flows horizontally, so a horizontal pixel
            // crop slices through glyphs and OCRs mid-word fragments ("goDB Atlas
            // archive cost optimiza"). Column selection happens post-OCR instead,
            // via each observation's bounding box vs the caret X (see ocr()).
            // AX caret rects, SCWindow frames, and CGImage crop rects all use a
            // top-left origin, so no flip.
            var caretNormX: CGFloat?
            if cropMode == .caretCropped, let caret = caretRect {
                let scaleY = CGFloat(image.height) / window.frame.height
                // caret position relative to the window's top-left corner
                let localY = caret.midY - window.frame.minY
                let cropHeightPts: CGFloat = 500   // ±250 around the caret line
                // Inset the boundaries slightly so half-height glyph rows at the
                // crop edges don't OCR into garbage lines.
                let edgeInset: CGFloat = 8 * scaleY
                let cropMinY = max(0, (localY - cropHeightPts / 2) * scaleY + edgeInset)
                let cropMaxY = min(CGFloat(image.height), (localY + cropHeightPts / 2) * scaleY - edgeInset)
                let rect = CGRect(x: 0, y: cropMinY,
                                  width: CGFloat(image.width), height: cropMaxY - cropMinY)
                if rect.height > 40, let cropped = image.cropping(to: rect) {
                    image = cropped
                }
                caretNormX = min(max((caret.midX - window.frame.minX) / window.frame.width, 0), 1)
            }

            guard let text = ocr(image, excluding: fieldText, cropMode: cropMode, caretNormX: caretNormX) else { return nil }
            let app = window.owningApplication?.applicationName ?? "Window"
            let bid = window.owningApplication?.bundleIdentifier ?? ""
            return (app, bid, text)
        } catch {
            Log.shared.info("screen capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func ocr(_ image: CGImage, excluding fieldText: String = "",
                                        cropMode: AppSettings.ScreenCropMode,
                                        caretNormX: CGFloat? = nil) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard var observations = request.results else { return nil }

        // Caret-column filter: keep only observations whose horizontal span contains
        // the caret X (with slack). The content column the user is typing under
        // spans the caret; sidebars and side panels sit entirely to one side of it
        // and drop out — without any pixel cropping that would slice words.
        if cropMode == .caretCropped, let cx = caretNormX {
            // Generous slack: Electron caret X is imprecise and conversation columns
            // are wide — a tight band discards the whole capture.
            observations = observations.filter {
                $0.boundingBox.minX - 0.15 <= cx && cx <= $0.boundingBox.maxX + 0.15
            }
        }

        var raw: [String] = []
        if cropMode == .columnar {
            // Sort primarily by X (to group columns) and secondarily by Y (top to bottom within column)
            // Vision's bounding box is normalized 0.0-1.0
            raw = observations.sorted { a, b in
                let dx = abs(a.boundingBox.midX - b.boundingBox.midX)
                // If they are separated horizontally by > 15% of the window, they are in different columns
                if dx > 0.15 {
                    return a.boundingBox.midX < b.boundingBox.midX
                }
                return a.boundingBox.origin.y > b.boundingBox.origin.y
            }.compactMap { $0.topCandidates(1).first?.string }
        } else {
            // Vision's y origin is bottom-left; sort descending y for top→bottom reading.
            raw = observations
                .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
                .compactMap { $0.topCandidates(1).first?.string }
        }
        // Drop lines that duplicate the text the user is typing. OCR mangles
        // characters, so compare on a normalized form (lowercased, letters/digits
        // only) and in both directions: the field containing the line, or the line
        // containing a long run of the field.
        let field = OCRCleaner.normalized(fieldText)
        if !field.isEmpty {
            raw = raw.filter { line in
                let t = OCRCleaner.normalized(line)
                guard t.count >= 4 else { return false }
                if field.contains(t) { return false }
                if t.count >= 20 && t.contains(String(field.suffix(20))) { return false }
                return true
            }
        }
        let text = OCRCleaner.clean(raw)
        return text.isEmpty ? nil : text
    }
}
