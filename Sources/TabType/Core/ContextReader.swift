import AppKit
import ApplicationServices

/// Reads the text context for a prediction: the current input (text before the caret
/// in the focused field, or the keystroke buffer as a fallback) and the text after
/// the caret. Prompt assembly — including screen context — happens in `PromptBuilder`.
enum ContextReader {

    struct Result {
        /// Dedup key: has the effective model input (screen context + typed input)
        /// changed since the last prediction? Never sent to the model itself.
        var dedupKey: String
        /// Just the text before the caret (the thing to continue).
        var input: String
        /// Text immediately after the caret, if the AX element exposes it (true
        /// fill-in-the-middle context — may be empty if the caret is at the end, or if
        /// AX text isn't available).
        var afterCursor: String
        /// The focused text element, if found (for caret positioning).
        var focused: AXUIElement?
        /// The focused window, if found (for HUD fallback positioning).
        var window: AXUIElement?
        /// Whether any typed input was present (avoid predicting on empty).
        var hasInput: Bool
    }

    /// - fallbackBuffer: keystroke buffer used when AX text isn't available.
    /// - screenContext: remembered on-screen text (may be empty).
    /// - inputChars: cap on how much of the current input (before the caret) to send.
    /// - afterChars: cap on how much text after the caret to send, for fill-in-the-middle.
    static func gather(fallbackBuffer: String,
                       screenContext: String,
                       inputChars: Int,
                       afterChars: Int = 300) -> Result {
        let focused = AccessibilityBridge.focusedElement()
        let window = focused.flatMap { windowOf($0) }

        var input = ""
        if let focused,
           let axText = AccessibilityBridge.textBeforeCaret(of: focused, maxChars: inputChars),
           !axText.isEmpty {
            input = axText
        } else {
            input = String(fallbackBuffer.suffix(inputChars))
        }

        let afterCursor = focused.flatMap {
            AccessibilityBridge.textAfterCaret(of: $0, maxChars: afterChars)
        } ?? ""

        let dedupKey = screenContext.isEmpty ? input : "\(screenContext.hashValue)|\(input)"

        return Result(dedupKey: dedupKey, input: input, afterCursor: afterCursor,
                      focused: focused, window: window,
                      hasInput: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Frame of the window enclosing `element`, if resolvable.
    static func windowRect(of element: AXUIElement) -> CGRect? {
        windowOf(element).flatMap { AccessibilityBridge.elementFrame(of: $0) }
    }

    /// Walk up to the enclosing window element.
    private static func windowOf(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
           let value {
            return (value as! AXUIElement)
        }
        var current = element
        for _ in 0..<25 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else { return nil }
            let parent = parentRef as! AXUIElement
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == (kAXWindowRole as String) { return parent }
            current = parent
        }
        return nil
    }
}
