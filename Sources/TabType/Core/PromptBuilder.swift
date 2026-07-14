import Foundation

/// Builds the completion prompt body from a request. Screen/reference context comes
/// first (clearly labeled), and the text before the caret is rendered LAST with no
/// trailing newline, so a base model's next token continues exactly at the caret.
enum PromptBuilder {
    /// The prompt body shared by all engines. Screen/reference context is rendered as
    /// a clearly-subordinated preface ("use only if it helps"); the text before the
    /// caret is rendered LAST, plain, with trailing whitespace preserved so the model
    /// continues exactly at the caret. (Do NOT add bracketed pseudo-labels like
    /// "[Now typing]" — the model echoes them.)
    static func body(_ req: CompletionRequest, cap: Int, screenContextBudget: Int = 700) -> String {
        // Trim trailing whitespace so the model continues from a real token — a
        // dangling space makes some models (Apple Intelligence) echo the whole prefix.
        var prefix = req.beforeCursor
        while let last = prefix.last, last == " " || last == "\n" || last == "\t" {
            prefix.removeLast()
        }
        var body = ""

        let persona = req.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty { body += persona + "\n\n" }

        var ctxParts: [String] = []
        var remaining = max(0, min(screenContextBudget, cap - prefix.count - body.count - 40))
        var screen = req.screenContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !screen.isEmpty, remaining > 40 {
            let take = min(screen.count, remaining - 20)
            if screen.count > take { screen = String(screen.suffix(take)) }
            ctxParts.append("On screen:\n\(screen)")
            remaining -= screen.count
        }
        var clip = req.clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clip.isEmpty, remaining > 40 {
            if clip.count > remaining { clip = String(clip.prefix(remaining)) }
            ctxParts.append("Clipboard:\n\(clip)")
            remaining -= clip.count
        }
        // Text after the cursor — true fill-in-the-middle context. Kept out of the
        // prefix itself (which must stay last/plain for continuation to work) and
        // clearly labeled as reference only, not something to repeat.
        var after = req.afterCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty, remaining > 40 {
            let take = min(after.count, remaining - 20)
            if after.count > take { after = String(after.prefix(take)) }
            ctxParts.append("Text immediately after the cursor (do not repeat this):\n\(after)")
        }
        if !ctxParts.isEmpty {
            body += "Context (use only if it helps):\n" + ctxParts.joined(separator: "\n") + "\n\n"
        }

        body += prefix
        return body
    }
}
