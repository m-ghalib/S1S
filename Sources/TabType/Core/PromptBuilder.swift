import Foundation

/// Builds the completion prompt body from a request.
///
/// Two formats, chosen by `chatFormat`:
///  - `true` (instruct models / Apple Intelligence): optional `<context>` block
///    (text after cursor, clipboard, screen — in that trust order), then
///    `Input: <prefix>\nOutput:` scaffolding that pairs with the few-shot examples
///    in `CompletionInstructions`.
///  - `false` (legacy base models, raw token continuation): optional `<context>`
///    block, then the plain prefix LAST with trailing whitespace preserved, so the
///    model's next token continues exactly at the caret. No labels — a base model
///    would continue label patterns instead of the author's text.
///
/// Budget: the prefix always wins — it is truncated (from the front) to fit `cap`
/// minus a fixed reserve, and whatever room remains is handed out in priority
/// order: text after cursor → clipboard → screen context. Screen OCR is the least
/// trusted input, so it gets budgeted last and rendered last.
enum PromptBuilder {
    /// Room reserved out of `cap` for persona, tags, and scaffolding overhead.
    private static let reserve = 200
    /// Minimum leftover budget worth spending on another context section.
    private static let minSectionBudget = 40

    static func body(_ req: CompletionRequest, cap: Int,
                     chatFormat: Bool = true) -> String {
        var prefix = req.beforeCursor
        if chatFormat {
            // Trim trailing whitespace so the model continues from a real token — a
            // dangling space makes some models (Apple Intelligence) echo the prefix.
            while let last = prefix.last, last == " " || last == "\n" || last == "\t" {
                prefix.removeLast()
            }
        }
        // The prefix always wins the budget; keep its most recent characters.
        let prefixMax = max(0, cap - reserve)
        if prefix.count > prefixMax {
            prefix = String(prefix.suffix(prefixMax))
        }

        var body = ""
        let persona = req.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty { body += persona + "\n\n" }

        var ctxParts: [String] = []
        var remaining = max(0, cap - prefix.count - body.count - reserve / 2)

        // The author's own recent writing — voice + active-topics context, the
        // strongest personalization signal (rendered first as background; budgeted
        // after the fill-in-the-middle text below).
        var afterBudget = 0
        var after = req.afterCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty { afterBudget = min(after.count, remaining) }

        if !req.previousWriting.isEmpty, remaining - afterBudget > minSectionBudget {
            var writingBudget = remaining - afterBudget
            var samples: [String] = []
            for s in req.previousWriting {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t.count <= writingBudget else { continue }
                samples.append(t)
                writingBudget -= t.count
            }
            if !samples.isEmpty {
                ctxParts.append("<recently_written_by_author>\n"
                                + samples.joined(separator: "\n")
                                + "\n</recently_written_by_author>")
                remaining -= samples.reduce(0) { $0 + $1.count }
            }
        }

        // Text after the cursor — true fill-in-the-middle context, the most
        // trustworthy signal after the prefix itself. Kept out of the prefix
        // (which must stay last/plain for continuation to work).
        if !after.isEmpty, remaining > minSectionBudget {
            if after.count > remaining { after = String(after.prefix(remaining)) }
            ctxParts.append("<text_after_cursor>\n\(after)\n</text_after_cursor>")
            remaining -= after.count
        }
        var clip = req.clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clip.isEmpty, remaining > minSectionBudget {
            if clip.count > remaining { clip = String(clip.prefix(remaining)) }
            ctxParts.append("<clipboard>\n\(clip)\n</clipboard>")
            remaining -= clip.count
        }
        // Screen OCR last: least trusted, capped by its own budget too, and the
        // most recent characters (suffix) are the ones kept.
        var screen = req.screenContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !screen.isEmpty, remaining > minSectionBudget {
            let take = min(screen.count, min(remaining, req.screenContextBudget))
            if screen.count > take { screen = String(screen.suffix(take)) }
            ctxParts.append("<on_screen>\n\(screen)\n</on_screen>")
            remaining -= screen.count
        }
        if !ctxParts.isEmpty {
            body += "<context>\n" + ctxParts.joined(separator: "\n\n") + "\n</context>\n\n"
        }

        if chatFormat {
            body += "Input: " + prefix + "\nOutput:"
        } else {
            body += prefix
        }
        return body
    }
}
