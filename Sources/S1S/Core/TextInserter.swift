import AppKit
import CoreGraphics

/// Inserts accepted suggestion text into the frontmost app by synthesizing
/// keyboard events carrying the Unicode string. This avoids touching the
/// pasteboard, so the user's clipboard is never disturbed.
enum TextInserter {

    /// Marker written to each synthesized event's user-data field so our own
    /// `CGEventTap` can recognize and ignore events we injected (otherwise
    /// accepting a suggestion would look like the user typing it).
    static let injectedMarker: Int64 = 0x7AB7_79E5

    /// Insert `text` using the strategy chosen for the app + payload.
    @MainActor
    static func insert(_ text: String, strategy: InsertionStrategy) {
        guard !text.isEmpty else { return }
        let resolved = resolve(strategy, for: text)
        switch resolved {
        case .paste: paste(text)
        default: insert(text)
        }
    }

    /// Resolve `.auto` to a concrete strategy: paste for multiline or long text
    /// (keystroke injection is slow/unreliable there), keystroke otherwise.
    private static func resolve(_ strategy: InsertionStrategy, for text: String) -> InsertionStrategy {
        switch strategy {
        case .keystroke: return .keystroke
        case .paste: return .paste
        case .auto:
            if text.contains("\n") || text.count >= 80 { return .paste }
            return .keystroke
        }
    }

    /// Clipboard-paste strategy: snapshot the pasteboard, write the text, synthesize
    /// ⌘V, then restore the user's clipboard shortly after.
    @MainActor
    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyV: CGKeyCode = 0x09
        if let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: true) {
            down.flags = .maskCommand
            down.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: false) {
            up.flags = .maskCommand
            up.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
            up.post(tap: .cgSessionEventTap)
        }

        // Restore the user's clipboard after the paste has been consumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pb.clearContents()
            for item in saved {
                let pbItem = NSPasteboardItem()
                for (type, data) in item { pbItem.setData(data, forType: type) }
                pb.writeObjects([pbItem])
            }
        }
    }

    /// Delete `count` characters before the caret via synthesized Backspace presses.
    static func backspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey: CGKeyCode = 0x33   // Backspace
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true) {
                down.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false) {
                up.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Type `text` into the focused field via synthesized key events (clipboard-free).
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        // A single keyDown/keyUp pair carrying the whole string works for most
        // apps; some apps prefer per-character events, so chunk defensively.
        for scalarChunk in text.chunkedByUTF16(maxUnits: 16) {
            let utf16 = Array(scalarChunk.utf16)

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                up.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Split the accepted suggestion for word-by-word acceptance: returns the first
    /// word (including any leading whitespace and the trailing space) and the rest.
    static func firstWord(of suggestion: String) -> (accepted: String, remainder: String) {
        var idx = suggestion.startIndex
        // Keep leading whitespace with the first word.
        while idx < suggestion.endIndex, suggestion[idx] == " " {
            idx = suggestion.index(after: idx)
        }
        // Consume the word.
        while idx < suggestion.endIndex, suggestion[idx] != " " {
            idx = suggestion.index(after: idx)
        }
        // Include one trailing space if present.
        if idx < suggestion.endIndex, suggestion[idx] == " " {
            idx = suggestion.index(after: idx)
        }
        let accepted = String(suggestion[suggestion.startIndex ..< idx])
        let remainder = String(suggestion[idx...])
        return (accepted, remainder)
    }
}

private extension String {
    /// Split into substrings whose UTF-16 length is at most `maxUnits`.
    func chunkedByUTF16(maxUnits: Int) -> [String] {
        guard utf16.count > maxUnits else { return [self] }
        var result: [String] = []
        var chunk = ""
        for ch in self {
            if chunk.utf16.count + ch.utf16.count > maxUnits {
                result.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}
