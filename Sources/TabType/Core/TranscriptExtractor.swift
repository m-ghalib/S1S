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
        var queue: [(AXUIElement, Int)] = [(windowElement, 0)]
        var lines: [(text: String, y: CGFloat, x: CGFloat)] = []

        // 3× slack: BFS reaches rows roughly top-to-bottom, and `assemble` keeps
        // the SUFFIX (newest messages) — exiting too early would cut the bottom
        // of the conversation before the suffix-keep can prefer it.
        while !queue.isEmpty, visits < maxVisits, collectedChars < budget * 3 {
            let (element, depth) = queue.removeFirst()
            visits += 1
            if let excluded, CFEqual(element, excluded) { continue }   // never echo the input field

            if AccessibilityBridge.role(of: element) == kAXStaticTextRole as String {
                if let text = AccessibilityBridge.stringValue(of: element),
                   text.count >= 3,
                   !isUIAnnouncement(text),
                   let frame = AccessibilityBridge.elementFrame(of: element),
                   overlapsColumn(frame, columnFrame) {
                    lines.append((text, frame.minY, frame.minX))
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
                queue.append((child, depth + 1))
            }
        }
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

    /// Pure text assembly: reading order (y, then x), the shared OCR hygiene
    /// filters, then the most recent `budget` characters.
    nonisolated static func assemble(lines: [(text: String, y: CGFloat, x: CGFloat)],
                                     budget: Int) -> String? {
        let ordered = lines.sorted {
            $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x
        }.map(\.text)
        let cleaned = OCRCleaner.clean(ordered)
        guard !cleaned.isEmpty else { return nil }
        let text = cleaned.count > budget ? String(cleaned.suffix(budget)) : cleaned
        return text
    }
}
