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
    nonisolated static func extract(windowElement: AXUIElement,
                                    excludingSubtreeOf excluded: AXUIElement?,
                                    budget: Int) -> String? {
        let maxVisits = 800
        let maxDepth = 14
        var visits = 0
        var queue: [(AXUIElement, Int)] = [(windowElement, 0)]
        var lines: [(text: String, y: CGFloat, x: CGFloat)] = []

        while !queue.isEmpty, visits < maxVisits {
            let (element, depth) = queue.removeFirst()
            visits += 1
            if let excluded, CFEqual(element, excluded) { continue }   // never echo the input field

            if AccessibilityBridge.role(of: element) == kAXStaticTextRole as String {
                if let text = AccessibilityBridge.stringValue(of: element),
                   text.count >= 3,
                   let frame = AccessibilityBridge.elementFrame(of: element) {
                    lines.append((text, frame.minY, frame.minX))
                }
                continue   // static text is a leaf for our purposes
            }
            guard depth < maxDepth else { continue }
            for child in AccessibilityBridge.children(of: element) {
                queue.append((child, depth + 1))
            }
        }
        guard !lines.isEmpty else { return nil }
        return assemble(lines: lines, budget: budget)
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
