import AppKit
import ScreenCaptureKit
import Vision

/// Builds a rolling memory of what TabType has "seen" on screen. It periodically
/// captures the **focused window**, OCRs it locally with Vision, and keeps a
/// deduplicated, time-bounded history. Predictions read this cached history so the
/// model can reference content from windows you looked at recently — e.g. a product
/// page in a browser you had open a moment ago — without ever leaving your Mac.
@MainActor
final class ScreenContextProvider: ObservableObject {
    static let shared = ScreenContextProvider()

    struct Entry {
        let time: Date
        let app: String
        let text: String
    }

    private(set) var history: [Entry] = []
    private var lastCaptureStarted = Date.distantPast
    private var capturing = false

    private let minInterval: TimeInterval = 1.5   // throttle captures
    private let maxEntries = 20
    private let maxAge: TimeInterval = 600         // forget after 10 min

    /// Logged once so a missing permission (which silently zeroes out screen context
    /// forever otherwise) is actually diagnosable instead of invisible.
    private var warnedNoPermission = false

    private init() {}

    // MARK: Permission

    func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: Capture (non-blocking)

    /// Trigger a capture of the largest **background content** windows (NOT the app
    /// you're typing in, and not system UI) if the throttle interval has elapsed.
    /// Runs off the main thread; never blocks typing/prediction. This reads what else
    /// is on screen — e.g. a product page in a browser behind your text field — while
    /// avoiding the noise of OCR'ing the current app's own chrome.
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
        let fieldText = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.stringValue(of: $0) } ?? ""

        Task.detached(priority: .utility) {
            let capture = await ScreenContextProvider.captureFocusedWindow(
                pid: frontPid, fieldText: fieldText)
            await MainActor.run {
                self.capturing = false
                if let (app, text) = capture, text.count >= 12 {
                    self.append(app: app, text: text)
                } else {
                    Log.shared.debug("screen memory: capture produced no usable text this round")
                }
            }
        }
    }

    private func append(app: String, text: String) {
        // Skip if unchanged from the last entry we stored for this app.
        if let last = history.last(where: { $0.app == app }), last.text == text { return }
        history.append(Entry(time: Date(), app: app, text: text))

        let cutoff = Date().addingTimeInterval(-maxAge)
        history.removeAll { $0.time < cutoff }
        if history.count > maxEntries {
            history.removeFirst(history.count - maxEntries)
        }
        Log.shared.debug("screen memory: +\(text.count) chars from \(app) (entries=\(history.count))")
    }

    /// The remembered context (focused-window OCR over time), most-recent last,
    /// capped to `cap` characters.
    func contextText(cap: Int) -> String {
        guard !history.isEmpty else { return "" }
        let parts = history.suffix(2).map { $0.text }
        var joined = parts.joined(separator: "\n")
        if joined.count > cap { joined = String(joined.suffix(cap)) }
        return joined
    }

    /// One-shot diagnostic: capture the frontmost window, OCR it, and log the result
    /// at info level so we can confirm the capture+OCR pipeline works on this machine.
    func selfTest() {
        guard hasPermission() else {
            Log.shared.info("screen self-test: no Screen Recording permission")
            return
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task.detached(priority: .utility) {
            if let (app, text) = await ScreenContextProvider.captureFocusedWindow(pid: pid, fieldText: "") {
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
        pid: pid_t?, fieldText: String
    ) async -> (String, String)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)

            let candidates = content.windows.filter { w in
                guard w.isOnScreen, w.frame.width > 120, w.frame.height > 80 else { return false }
                if let bid = w.owningApplication?.bundleIdentifier,
                   systemBundleIDs.contains(bid) { return false }
                return true
            }
            // The frontmost app's largest window; else the largest overall.
            let byArea: (SCWindow, SCWindow) -> Bool = {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }
            let window: SCWindow?
            if let pid, let w = candidates.filter({ $0.owningApplication?.processID == pid })
                .max(by: byArea) {
                window = w
            } else {
                window = candidates.max(by: byArea)
            }
            guard let window else { return nil }

            let config = SCStreamConfiguration()
            let scale = 2
            config.width = min(Int(window.frame.width) * scale, 3000)
            config.height = min(Int(window.frame.height) * scale, 3000)
            config.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config),
                  let text = ocr(image, excluding: fieldText) else { return nil }
            let app = window.owningApplication?.applicationName ?? "Window"
            return (app, text)
        } catch {
            Log.shared.info("screen capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func ocr(_ image: CGImage, excluding fieldText: String = "") -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return nil }
        // Vision's y origin is bottom-left; sort descending y for top→bottom reading.
        var raw = observations
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string }
        // Drop lines that are part of the text the user is currently typing.
        let field = fieldText.lowercased()
        if !field.isEmpty {
            raw = raw.filter { line in
                let t = line.trimmingCharacters(in: .whitespaces).lowercased()
                return t.count >= 4 && !field.contains(t)
            }
        }
        let text = cleanOCR(raw)
        return text.isEmpty ? nil : text
    }

    /// Reduce UI-chrome noise: drop very short fragments and lines with no letters
    /// (icons, standalone numbers, separators), and collapse duplicates.
    nonisolated private static func cleanOCR(_ lines: [String]) -> String {
        var kept: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 4 else { continue }
            let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letters >= 3 else { continue }           // must contain some words
            if kept.last == t { continue }
            kept.append(t)
        }
        return kept.joined(separator: "\n")
    }
}
