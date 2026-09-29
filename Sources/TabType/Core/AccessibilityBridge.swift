import AppKit
import ApplicationServices

/// Notification-based focus tracking: fires the handler (on the main run loop)
/// whenever the focused UI element changes within one app — the instant
/// alternative to noticing a focus change only on the next keystroke.
final class AXFocusObserver {
    private final class Box {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    private let box: Box
    private var observer: AXObserver?

    init?(pid: pid_t, handler: @escaping () -> Void) {
        box = Box(handler)
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue().handler()
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let result = AXObserverAddNotification(
            obs, app, kAXFocusedUIElementChangedNotification as CFString,
            Unmanaged.passUnretained(box).toOpaque())
        guard result == .success else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}

/// Thin wrappers over the macOS Accessibility (AX) API for reading the focused
/// text element, the text preceding the caret, and the caret's screen rectangle.
enum AccessibilityBridge {

    /// AX may announce focus again while editing the same field.
    static func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return CFEqual(lhs, rhs)
        default: return false
        }
    }

    /// Whether TabType has been granted Accessibility permission.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission (opens the system dialog
    /// / directs them to System Settings).
    @discardableResult
    static func requestTrust() -> Bool {
        // Key value is "AXTrustedCheckOptionPrompt"; use the literal to avoid a
        // reference to the non-Sendable global CFString constant under Swift 6.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// The system-wide focused UI element, if any.
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        // Bound AX round-trips so a stalled app can't beach-ball us.
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }

    /// Whether the element is a secure (password) text field — never autocomplete these.
    static func isSecureField(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXSecureTextField" { return true }
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        return (subroleRef as? String) == "AXSecureTextField"
    }

    /// The full string value of a text element.
    static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    /// The raw caret position in the host's AX range coordinates (UTF-16). Uses the selected text range's
    /// location (caret == zero-length selection).
    static func caretOffset(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Whether there's text after the caret (rough proxy for "mid-line": the caret
    /// isn't at the very end of the field's content).
    static func hasTextAfterCaret(of element: AXUIElement) -> Bool {
        guard caretOffset(of: element) != nil, let text = textAroundCaret(of: element) else { return false }
        return !text.after.isEmpty
    }

    /// Children of an element (kAXChildren), or [] when unavailable.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    /// The element's AX role, or nil.
    static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Whether the element is an EDITABLE text input. Selected-text-range alone is
    /// not enough — read-only static text and web areas expose it too (anything
    /// selectable does). Editability = a text-input role, or a settable value.
    static func isTextInput(_ element: AXUIElement) -> Bool {
        let role = role(of: element)
        if let role, textInputRoles.contains(role) { return true }
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return isTextInput(role: role, valueSettable: err == .success && settable.boolValue)
    }

    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String,
        kAXComboBoxRole as String, "AXSearchField",
    ]

    /// Controls whose value is settable but is not text: typing over them
    /// (keyboard shortcuts, game keys) must never count as writing.
    private static let nonTextControlRoles: Set<String> = [
        "AXSlider", "AXCheckBox", "AXRadioButton", "AXIncrementor",
        "AXPopUpButton", "AXMenuButton", "AXScrollBar", "AXDisclosureTriangle",
        "AXColorWell", "AXLevelIndicator", "AXValueIndicator", "AXSplitter",
        "AXStepper", "AXSwitch", "AXToggle",
    ]

    /// Pure decision behind `isTextInput`: a text-input role, or a settable
    /// value on something that is not a non-text control.
    static func isTextInput(role: String?, valueSettable: Bool) -> Bool {
        if let role, textInputRoles.contains(role) { return true }
        if let role, nonTextControlRoles.contains(role) { return false }
        return valueSettable
    }

    /// True only with POSITIVE evidence that the caret sits at the very end of the
    /// field's text. Unreadable AX (common in Electron) returns false — callers use
    /// this to gate rendering that would overlap any text after the caret.
    static func caretConfirmedAtEnd(of element: AXUIElement) -> Bool {
        guard caretOffset(of: element) != nil, let text = textAroundCaret(of: element) else { return false }
        return text.after.isEmpty
    }

    struct CaretText: Equatable {
        var before: String
        var after: String
    }

    /// Native AX ranges use UTF-16, not Swift Character counts.
    static func splitText(_ full: String, caret: Int?) -> CaretText {
        let value = full as NSString
        let offset = min(max(caret ?? value.length, 0), value.length)
        return CaretText(before: value.substring(to: offset), after: value.substring(from: offset))
    }

    struct ValueCaret: Equatable {
        var run: Int
        var localOffset: Int
        var valueOffset: Int
    }

    /// Align the host's text runs with AXValue. Only paragraph separators may
    /// occur between runs; a stale or mismatched tree must not shift the cursor.
    static func valueCarets(full: String, caret: Int, runs: [String]) -> [ValueCaret] {
        let value = Array(full.utf16)
        var starts: [Int] = []
        var offset = 0
        for run in runs {
            let units = Array(run.utf16)
            guard !units.isEmpty else { return [] }
            while !value.dropFirst(offset).starts(with: units),
                  offset < value.count, value[offset] == 10 {
                offset += 1
            }
            guard value.dropFirst(offset).starts(with: units) else { return [] }
            starts.append(offset)
            offset += units.count
        }
        guard value.dropFirst(offset).allSatisfy({ $0 == 10 }) else { return [] }
        return runLocations(caret: caret, runLengths: runs.map { $0.utf16.count }).map {
            ValueCaret(run: $0.run, localOffset: $0.offset, valueOffset: starts[$0.run] + $0.offset)
        }
    }

    /// Read one snapshot so before/after context shares the same caret and value.
    static func textAroundCaret(of element: AXUIElement) -> CaretText? {
        guard let full = stringValue(of: element) else { return nil }
        let rawCaret = caretOffset(of: element)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.anthropic.claudefordesktop",
           full.contains("\n"), let rawCaret {
            var runs: [(element: AXUIElement, length: Int)] = []
            collectStaticText(in: element, into: &runs, depth: 0)
            let candidates = valueCarets(full: full, caret: rawCaret,
                                        runs: runs.map { stringValue(of: $0.element) ?? "" })
            let line = textMarkerCaretRect(element)
            let positioned = candidates.compactMap { candidate -> (ValueCaret, CGRect)? in
                guard let rect = caretRect(inRun: runs[candidate.run].element, offset: candidate.localOffset)
                else { return nil }
                return (candidate, rect)
            }
            // At a paragraph boundary, both the previous paragraph's end and the
            // next paragraph's start share a raw offset. The marker's line chooses.
            if Set(candidates.map(\.valueOffset)).count == 1, let candidate = candidates.first {
                if full.utf16.count > candidate.valueOffset,
                   full.dropFirst(splitText(full, caret: candidate.valueOffset).before.count)
                    .allSatisfy({ $0 == "\n" }),
                   let line, let rect = positioned.first?.1,
                   rect.midY < line.minY || rect.midY > line.maxY {
                    return nil // caret is on a trailing empty paragraph
                }
                return splitText(full, caret: candidate.valueOffset)
            }
            if let line {
                let onLine = positioned.filter { $0.1.midY >= line.minY && $0.1.midY <= line.maxY }
                if onLine.count == 1 {
                    return splitText(full, caret: onLine[0].0.valueOffset)
                }
            }
            // Empty composers have a synthetic newline but no text runs.
            if rawCaret == 0, full.trimmingCharacters(in: .newlines).isEmpty {
                return CaretText(before: "", after: full)
            }
            return nil
        }
        return splitText(full, caret: rawCaret)
    }

    /// Text immediately preceding the caret, capped in Swift characters.
    static func textBeforeCaret(of element: AXUIElement, maxChars: Int) -> String? {
        textAroundCaret(of: element).map { String($0.before.suffix(max(0, maxChars))) }
    }

    /// Text immediately following the caret, capped in Swift characters.
    static func textAfterCaret(of element: AXUIElement, maxChars: Int) -> String? {
        textAroundCaret(of: element).map { String($0.after.prefix(max(0, maxChars))) }
    }

    /// Screen rectangle (Quartz/top-left origin) of the caret, for overlay placement.
    /// Tries a ladder of strategies (mirrors cotabby/KeyType) and returns the first
    /// valid rect, else nil.
    ///
    /// Some apps (TextEdit included) can return a "zero-length bounds" rect that is
    /// implausibly far from the actual cursor — a known AX quirk. We compute the
    /// preceding-character rect as an anchor whenever possible and only trust the
    /// zero-length rect if it's close to that anchor's trailing edge; otherwise we
    /// prefer the anchor itself. This is what fixed the "wide gap" ghost-text bug.
    static func caretRect(of element: AXUIElement) -> CGRect? {
        guard let caret = caretOffset(of: element) else {
            if let r = textMarkerCaretRect(element), isValidCaretRect(r), isCaretWidth(r) { return r }
            return nil
        }

        let anchor: CGRect? = caret > 0
            ? boundsForRange(element, location: caret - 1, length: 1).map {
                CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height)
              }
            : nil

        // Web content (Electron/WebKit/Chromium) exposes AXTextMarker attributes even
        // when it also answers NSRange-based bounds queries — but its NSRange "bounds"
        // frequently reflect an inflated CSS line-box rather than the true glyph line,
        // which is exactly the zero-length-rect failure mode this function otherwise
        // guards against. For such content, prefer the anchor (a real character's
        // rendered position) outright rather than trusting agreement with it.
        let isWebContent = hasTextMarkerSupport(element)

        if let zero = boundsForRange(element, location: caret, length: 0),
           isValidCaretRect(zero) {
            if let anchor {
                if isWebContent {
                    return anchor
                }
                // Trust the zero-length rect only if it's near the anchor (same line,
                // close horizontally); otherwise the anchor is more reliable.
                let dx = abs(zero.minX - anchor.maxX)
                let dy = abs(zero.minY - anchor.minY)
                if dx <= 24, dy <= 6 { return zero }
            } else {
                return zero
            }
        }

        // Prefer the anchor (bounds of the preceding character) when the zero-length
        // rect was missing or implausible.
        if let anchor, isValidCaretRect(anchor) { return anchor }

        // AXTextMarker path — WebKit/Chromium (Safari, Chrome, Electron) expose
        // caret geometry via text markers rather than NSRange.
        let marker = textMarkerCaretRect(element).flatMap { isValidCaretRect($0) ? $0 : nil }
        if let marker, isCaretWidth(marker) { return marker }

        // Chromium content editables (Claude Desktop's composer) can answer both
        // queries with garbage: NSRange bounds off-screen, and the marker bounds
        // as the whole LINE box. Anchoring to that box put the ghost at the line
        // start, over the typed text. The per-paragraph AXStaticText runs still
        // report exact character bounds, so resolve the caret there.
        if let r = staticTextCaretRect(element, caret: caret, line: marker) { return r }
        // Nothing typed on the caret's line: the line box's left edge IS the caret.
        if let marker, lineIsEmptyBeforeCaret(element, caret: caret) {
            return CGRect(x: marker.minX, y: marker.minY, width: 0, height: marker.height)
        }
        return nil
    }

    /// A real caret is a hairline; anything wider is a line or field box.
    static func isCaretWidth(_ rect: CGRect) -> Bool { rect.width <= 4 }

    /// Which static-text run holds `caret`, and the offset inside it. Runs are
    /// consecutive with no separator between them: Chromium's selection offsets
    /// skip the "\n" its AXValue puts between paragraphs (observed in Claude
    /// Desktop: caret at the end of "abc\nde" reports offset 5, not 6).
    /// Because separators are skipped, a caret on a run boundary is ambiguous: the
    /// end of one paragraph and the start of the next share an offset. Both
    /// readings are returned (earlier run first) for the caller to settle.
    static func runLocations(caret: Int, runLengths: [Int]) -> [(run: Int, offset: Int)] {
        guard caret >= 0 else { return [] }
        var start = 0
        for (i, length) in runLengths.enumerated() {
            if caret < start + length { return [(i, caret - start)] }
            if caret == start + length {
                return i + 1 < runLengths.count ? [(i, length), (i + 1, 0)] : [(i, length)]
            }
            start += length
        }
        return []
    }

    /// Settles a boundary caret with the caret's line box (`line`, the degenerate
    /// marker rect): keep the candidate on that line. Without a line, an
    /// ambiguous caret gets no rect rather than a guess.
    static func pickCaret(_ candidates: [CGRect], line: CGRect?) -> CGRect? {
        guard candidates.count > 1 else { return candidates.first }
        guard let line else { return nil }
        let onLine = candidates.filter { $0.midY >= line.minY && $0.midY <= line.maxY }
        return onLine.count == 1 ? onLine[0] : nil
    }

    private static func staticTextCaretRect(_ element: AXUIElement, caret: Int, line: CGRect?) -> CGRect? {
        var runs: [(element: AXUIElement, length: Int)] = []
        collectStaticText(in: element, into: &runs, depth: 0)
        let candidates = runLocations(caret: caret, runLengths: runs.map(\.length)).compactMap {
            caretRect(inRun: runs[$0.run].element, offset: $0.offset)
        }
        return pickCaret(candidates, line: line)
    }

    /// A hairline at the trailing edge of the character before `offset`, or at
    /// the leading edge of the first character when `offset` is 0.
    private static func caretRect(inRun leaf: AXUIElement, offset: Int) -> CGRect? {
        guard offset >= 0 else { return nil }
        let atStart = offset == 0
        guard let char = boundsForRange(leaf, location: atStart ? 0 : offset - 1, length: 1),
              isValidCaretRect(char) else { return nil }
        return CGRect(x: atStart ? char.minX : char.maxX, y: char.minY, width: 1, height: char.height)
    }

    /// Depth-first AXStaticText leaves (UTF-16 lengths, the unit AX offsets use).
    private static func collectStaticText(in element: AXUIElement,
                                          into runs: inout [(element: AXUIElement, length: Int)],
                                          depth: Int) {
        guard depth < 8, runs.count < 200 else { return }
        for child in children(of: element) {
            if role(of: child) == (kAXStaticTextRole as String) {
                if let text = stringValue(of: child), !text.isEmpty {
                    runs.append((child, text.utf16.count))
                }
            } else {
                collectStaticText(in: child, into: &runs, depth: depth + 1)
            }
        }
    }

    private static func lineIsEmptyBeforeCaret(_ element: AXUIElement, caret: Int) -> Bool {
        guard let full = stringValue(of: element) as NSString? else { return false }
        let caret = min(max(caret, 0), full.length)
        let before = full.substring(to: caret)
        return before.isEmpty || before.hasSuffix("\n")
    }

    /// The x where the caret's paragraph starts (Quartz global): the left edge of
    /// the text column, which can sit well inside the element's frame (Notes pads
    /// its text ~17pt). Nil on an empty paragraph or when AX has no bounds.
    static func paragraphStartX(of element: AXUIElement) -> CGFloat? {
        guard let full = stringValue(of: element) as NSString?,
              let caret = caretOffset(of: element), caret > 0, caret <= full.length else { return nil }
        let newline = full.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let start = newline.location == NSNotFound ? 0 : newline.location + 1
        guard start < caret,
              let r = boundsForRange(element, location: start, length: 1), isValidCaretRect(r) else { return nil }
        return r.minX
    }

    private static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        guard location >= 0 else { return nil }
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef)
        guard err == .success, let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The field's actual font at the caret, read from the AX attributed string.
    /// Lets the ghost text match the field's font family and size exactly. Tries the
    /// preceding character first, then the character at/after the caret (helps an
    /// empty field or a caret at position 0, and gives web content a second chance —
    /// some WebKit/Chromium implementations only answer for certain ranges).
    static func fontAtCaret(of element: AXUIElement, caret: Int) -> NSFont? {
        if let font = font(of: element, at: max(0, caret - 1)) { return font }
        return font(of: element, at: caret)
    }

    private static func font(of element: AXUIElement, at location: Int) -> NSFont? {
        var cfRange = CFRange(location: location, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var attrRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue, &attrRef) == .success, let attrRef else { return nil }
        let attributed = attrRef as! NSAttributedString
        guard attributed.length > 0 else { return nil }
        return attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    /// Whether this element exposes AXTextMarker attributes at all — a signal that
    /// it's WebKit/Chromium web content rather than a native AppKit text field, since
    /// only web content typically implements this API alongside NSRange-based bounds.
    private static func hasTextMarkerSupport(_ element: AXUIElement) -> Bool {
        var markerRange: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success
            && markerRange != nil
    }

    /// Caret rect via AXTextMarker attributes (WebKit/Chromium content editables).
    private static func textMarkerCaretRect(_ element: AXUIElement) -> CGRect? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
            let markerRange else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsRef) == .success,
            let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Reject bogus caret rectangles (zero-size, off-screen, or absurd) that some
    /// apps — notably Electron/web views like Slack — return. Better to show nothing
    /// than to draw ghost text in the wrong place.
    static func isValidCaretRect(_ rect: CGRect) -> Bool {
        guard rect.width >= 0, rect.height > 1, rect.height < 200 else { return false }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
        // Must intersect some screen (AX uses a top-left global origin; compare in
        // that space by flipping each screen's frame).
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let primaryHeight = NSScreen.primaryHeight
        for screen in NSScreen.screens {
            let f = screen.frame
            let topLeftFrame = CGRect(
                x: f.origin.x,
                y: primaryHeight - f.origin.y - f.height,
                width: f.width, height: f.height)
            if topLeftFrame.insetBy(dx: -20, dy: -20).contains(point) { return true }
        }
        return false
    }

    /// Bundle identifier of the frontmost application.
    static func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// The kAXTitleAttribute of a window element, or nil.
    static func windowTitle(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Best-effort host of the URL for the focused browser tab (via `kAXURLAttribute`
    /// on the focused element or its window). Returns nil for non-browser contexts.
    static func frontmostURLHost() -> String? {
        guard let element = focusedElement() else { return nil }
        if let h = urlHost(of: element) { return h }
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
           let winRef {
            return urlHost(of: winRef as! AXUIElement)
        }
        return nil
    }

    private static func urlHost(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return url.host }
        if let s = value as? String, let url = URL(string: s) { return url.host }
        return nil
    }

    /// Chromium/Electron apps (Slack, VS Code, Discord, Chrome, Arc…) do not expose
    /// their web accessibility tree — including text values and caret bounds — until
    /// a client asks for it by setting `AXManualAccessibility` (and the older
    /// `AXEnhancedUserInterface`) on the application element. Call this once per app
    /// so `stringValue`/`caretRect` start returning real data there.
    static func enableEnhancedAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Frame (top-left global origin) of an element, from AXPosition + AXSize.
    /// Used as a rough overlay anchor when precise caret bounds aren't available.
    static func elementFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: origin, size: size)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// Gets the frame of the window containing the currently focused element.
    static func focusedWindowFrame() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
              let windowRef = winRef else { return nil }
        let windowElement = windowRef as! AXUIElement
        return elementFrame(of: windowElement)
    }
}
