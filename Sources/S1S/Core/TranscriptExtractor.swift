import AppKit
import ApplicationServices

/// Per-app context extraction via the ACCESSIBILITY TREE: chat apps expose their
/// conversation as ordered AXStaticText rows — clean, sender-labeled text with no
/// OCR noise and no Screen Recording permission. This is the "extraction path"
/// Cotypist uses for messaging apps (its compatibility docs + binary symbols);
/// pixel OCR remains the fallback for apps whose trees expose nothing.
/// AXUIElement is a thread-safe CFType but not marked Sendable — box it for
/// crossing into detached tasks.
struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement
}

enum TranscriptExtractor {

    /// Walk the window's AX tree and assemble the visible conversation text.
    /// Runs off the main thread (AX calls are thread-safe); bounded breadth-first
    /// so a pathological tree can't hang the extraction queue.
    /// `columnFrame` (the focused input field's frame, when known) anchors the
    /// conversation COLUMN: only static text that horizontally overlaps it is
    /// collected. Chat sidebars (session lists, contact lists) sit entirely to
    /// the side of the input field, and without this filter they dominate the
    /// "transcript" — the model then continues the author's text toward
    /// unrelated sidebar entries instead of the actual conversation.
    nonisolated static func extract(windowElement: AXUIElement,
                                    excludingSubtreeOf excluded: AXUIElement?,
                                    columnFrame: CGRect? = nil,
                                    budget: Int) -> String? {
        // Web DOMs (browser/Electron chats) are far deeper and wider than native
        // chat trees, so the bounds are generous; the char-based early exit below
        // keeps native apps as cheap as before, and the column pruning below
        // stops sidebars from burning the visit budget before the walk ever
        // reaches the (deep) message text.
        let maxVisits = 6000
        let maxDepth = 40
        var visits = 0
        var collectedChars = 0
        // Reverse depth-first walk: the LAST child is visited first, so text is
        // collected newest-first (reverse document order) and the char-based
        // early exit drops the oldest messages. A breadth-first walk stopped
        // partway through a long transcript and lost the latest reply.
        var stack: [(AXUIElement, Int)] = [(windowElement, 0)]
        var newestFirst: [(text: String, y: CGFloat, x: CGFloat)] = []

        while let (element, depth) = stack.popLast(), visits < maxVisits,
              collectedChars < budget * 3 {
            visits += 1
            if let excluded, CFEqual(element, excluded) { continue }   // never echo the input field

            if AccessibilityBridge.role(of: element) == kAXStaticTextRole as String {
                if let text = AccessibilityBridge.stringValue(of: element),
                   text.count >= 3,
                   !isUIAnnouncement(text),
                   let frame = AccessibilityBridge.elementFrame(of: element),
                   overlapsColumn(frame, columnFrame) {
                    newestFirst.append((text, frame.minY, frame.minX))
                    collectedChars += text.count
                }
                continue   // static text is a leaf for our purposes
            }
            guard depth < maxDepth else { continue }
            // Prune whole subtrees that sit outside the conversation column
            // (sidebars, tool panels) — their text would be filtered anyway, so
            // don't spend the visit budget walking them. Zero/unknown frames
            // descend: containers often report no geometry even when their
            // children do.
            if depth > 0, let frame = AccessibilityBridge.elementFrame(of: element),
               frame.width > 0, frame.height > 0,
               !overlapsColumn(frame, columnFrame) {
                continue
            }
            for child in AccessibilityBridge.children(of: element) {
                stack.append((child, depth + 1))
            }
        }
        let lines = Array(newestFirst.reversed())
        // Fewer than a few real lines is not a conversation — return nil so the
        // caller falls back to pixel OCR instead of feeding the model stray UI
        // strings as "the conversation".
        guard lines.count >= 3 else { return nil }
        return assemble(lines: lines, budget: budget)
    }

    /// True when `frame` horizontally overlaps the conversation column anchored
    /// by the input field (messages may be wider or indented — overlap, not
    /// containment). No column known → fail open. Zero-size frames (offscreen
    /// live-region announcements like drag-and-drop narration) never overlap.
    nonisolated static func overlapsColumn(_ frame: CGRect, _ column: CGRect?) -> Bool {
        guard let column, column.width >= 100 else { return true }
        guard frame.width > 0, frame.height > 0 else { return false }
        return frame.maxX > column.minX + 4 && frame.minX < column.maxX - 4
    }

    /// Screen-reader live-region announcements read as prose but are pure UI
    /// narration ("Draggable item custom-cg-<uuid> was dropped over droppable
    /// area …"). The reliable tell is a long machine identifier: a token
    /// containing a run of 6+ hex chars bounded by hyphens.
    nonisolated static func isUIAnnouncement(_ text: String) -> Bool {
        text.range(of: #"[0-9a-f]{6,}-[0-9a-f]{2,}"#, options: .regularExpression) != nil
    }

    /// Pure text assembly: reading order (y, then the document order `lines`
    /// arrive in), the shared OCR hygiene filters, then the most recent `budget`
    /// characters. Ties keep document order because web views (Claude Desktop)
    /// clamp scrolled-off rows to the scroll view's edge, so many rows share one
    /// y; sorting those by x scrambled the transcript.
    nonisolated static func assemble(lines: [(text: String, y: CGFloat, x: CGFloat)],
                                     budget: Int) -> String? {
        let ordered = lines.enumerated().sorted {
            $0.element.y != $1.element.y ? $0.element.y < $1.element.y : $0.offset < $1.offset
        }.map(\.element.text)
        let cleaned = OCRCleaner.clean(ordered)
        guard !cleaned.isEmpty else { return nil }
        let text = cleaned.count > budget ? String(cleaned.suffix(budget)) : cleaned
        return text
    }
}
