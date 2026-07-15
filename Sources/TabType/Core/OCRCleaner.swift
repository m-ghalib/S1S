import Foundation

/// Pure text-filtering half of the screen-context pipeline, kept free of
/// ScreenCaptureKit/Vision dependencies so it's independently testable.
enum OCRCleaner {
    /// Lowercased letters+digits only — robust against OCR punctuation/spacing noise.
    static func normalized(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }).lowercased()
    }

    private static let timeLike = try! NSRegularExpression(
        pattern: #"^\d{1,2}:\d{2}(\s?[AP]M)?$"#, options: [.caseInsensitive])

    /// Reduce UI-chrome noise: drop short fragments, whitespace-free tokens (menu
    /// items, button labels), timestamps, and symbol-heavy lines; dedupe globally.
    /// Returns "" unless enough prose survives to be worth sending to the model.
    static func clean(_ lines: [String]) -> String {
        var kept: [String] = []
        var seen = Set<String>()
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 4 else { continue }
            // Single tokens under 12 chars are almost always chrome (File, Edit,
            // Send, tab titles); real prose lines contain spaces.
            if !t.contains(" ") && t.count < 12 { continue }
            let range = NSRange(t.startIndex..., in: t)
            if timeLike.firstMatch(in: t, range: range) != nil { continue }
            let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letters >= 3, Double(letters) / Double(t.count) >= 0.6 else { continue }
            // 1-2 word lines are almost always chrome (buttons, tab titles, branch
            // names: "Commit changes", "TabType main") — unless punctuated like a
            // real sentence fragment ("Sounds good.").
            let lineWords = t.split(separator: " ").count
            if lineWords < 3, let last = t.last, !".;!?,:…".contains(last) { continue }
            if !seen.insert(t.lowercased()).inserted { continue }
            kept.append(t)
        }
        kept = suppressNearDuplicates(kept)
        let joined = kept.joined(separator: "\n")
        // A handful of surviving words is chrome residue, not context. (Floor of 5:
        // chat snippets are short — a higher bar discarded whole captures.)
        let wordCount = joined.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        return wordCount >= 5 ? joined : ""
    }

    /// Overlapping OCR boxes yield cascades of near-identical fragments
    /// ("Sync-up meeti", "Sync-up meeting (Sprint statu", …). Keep only the longest
    /// of any group whose normalized forms contain one another or share a long prefix.
    static func suppressNearDuplicates(_ lines: [String]) -> [String] {
        // Longest first, so the fullest variant of a group is kept.
        let ordered = lines.sorted { $0.count > $1.count }
        var keptNorms: [String] = []
        var kept = Set<String>()
        for line in ordered {
            let n = normalized(line)
            guard n.count >= 4 else { continue }
            let isDup = keptNorms.contains { prev in
                prev.contains(n) || (n.count >= 12 && prev.hasPrefix(String(n.prefix(12))))
            }
            if isDup { continue }
            keptNorms.append(n)
            kept.insert(line)
        }
        return lines.filter { kept.contains($0) }   // restore original reading order
    }
}
