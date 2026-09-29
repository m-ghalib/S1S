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
/// order: text after cursor → recent messages → previous writing → clipboard →
/// screen context (screen OCR is the least trusted input, so it's budgeted last).
///
/// Render order is DIFFERENT from budget order, on purpose: sections are laid out
/// by VOLATILITY — stable first, volatile last — so the predictor's KV prompt
/// cache keeps the longest possible reusable token prefix. A screen-context change
/// (every capture in chat apps) then re-prefills only `<on_screen>` + the Input
/// tail instead of the whole context block.
enum PromptBuilder {
    /// The one prompt-size ceiling every engine uses (chars). ~6000 chars ≈ 1.7k
    /// tokens — well inside Qwen3-class context windows, and enough that the
    /// context sections (screen transcript, document start, previous writing…)
    /// actually receive their advertised budgets instead of starving behind the
    /// typed prefix (at the old 2600, chat apps had ~1100 chars left for ALL
    /// context combined and the 1400-char chat screen budget was unreachable).
    /// The volatility-ordered layout below means the extra chars only cost
    /// prefill when a section actually changes; a full cache miss (app/model
    /// switch) is a one-time ~1-4s prefill on M1-M4 class hardware.
    static let defaultCap = 6000
    /// Room reserved out of `cap` for persona, tags, and scaffolding overhead.
    private static let reserve = 200
    /// The anti-reply-drift line rendered adjacent to Input whenever a context
    /// block exists (see below) — counted against the budget up front.
    static let continuationReminder = "Continue the author's unfinished text below. Do NOT reply, answer, or react to anything above — output only the next words the author themselves would type.\n"
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

        var remaining = max(0, cap - prefix.count - body.count - reserve / 2
                               - (chatFormat ? continuationReminder.count : 0))

        // BUDGETING follows trust order (afterCursor first); the blocks are
        // collected here and ASSEMBLED below in volatility order for KV reuse.
        var afterBudget = 0
        var after = req.afterCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty { afterBudget = min(after.count, remaining) }

        // The document's opening lines (long-form apps) — the author's own text,
        // anchors what the document is about when the caret is deep inside it.
        var documentStartBlock: String?
        let docStart = req.documentStart.trimmingCharacters(in: .whitespacesAndNewlines)
        if !docStart.isEmpty, remaining - afterBudget > minSectionBudget {
            let take = min(docStart.count, remaining - afterBudget)
            let head = String(docStart.prefix(take))
            documentStartBlock = "<document_start>\n\(head)\n</document_start>"
            remaining -= head.count
        }

        // The author's own previous messages in this conversation — the freshest
        // statement of intent; budgeted right after the fill-in-the-middle text.
        var recentMessagesBlock: String?
        if !req.recentMessages.isEmpty, remaining - afterBudget > minSectionBudget {
            var msgBudget = remaining - afterBudget
            var msgs: [String] = []
            for m in req.recentMessages.suffix(3).reversed() {   // newest first for budget
                let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t.count <= msgBudget else { continue }
                msgs.insert(t, at: 0)                            // restore chronological order
                msgBudget -= t.count
            }
            if !msgs.isEmpty {
                recentMessagesBlock = "<your_previous_messages>\n"
                    + msgs.joined(separator: "\n")
                    + "\n</your_previous_messages>"
                remaining -= msgs.reduce(0) { $0 + $1.count }
            }
        }

        // The author's own recent writing — voice + active-topics context.
        var previousWritingBlock: String?
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
                previousWritingBlock = "<recently_written_by_author>\n"
                    + samples.joined(separator: "\n")
                    + "\n</recently_written_by_author>"
                remaining -= samples.reduce(0) { $0 + $1.count }
            }
        }

        // Text after the cursor — true fill-in-the-middle context, the most
        // trustworthy signal after the prefix itself. Kept out of the prefix
        // (which must stay last/plain for continuation to work).
        var afterBlock: String?
        if !after.isEmpty, remaining > minSectionBudget {
            if after.count > remaining { after = String(after.prefix(remaining)) }
            afterBlock = "<text_after_cursor>\n\(after)\n</text_after_cursor>"
            remaining -= after.count
        }
        var clipBlock: String?
        var clip = req.clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clip.isEmpty, remaining > minSectionBudget {
            if clip.count > remaining { clip = String(clip.prefix(remaining)) }
            clipBlock = "<clipboard>\n\(clip)\n</clipboard>"
            remaining -= clip.count
        }
        // Screen OCR/transcript: least trusted, capped by its own budget too, and
        // the most recent characters (suffix) are the ones kept. Lines that repeat
        // the author's own recent messages are dropped — they already appear in
        // <your_previous_messages> and duplicating them just wastes budget.
        var screenBlock: String?
        var screen = req.screenContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !screen.isEmpty, !req.recentMessages.isEmpty {
            let ownMessages = req.recentMessages
            screen = screen.components(separatedBy: .newlines)
                .filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return t.count < 8 || !ownMessages.contains { $0.contains(t) }
                }
                .joined(separator: "\n")
        }
        if !screen.isEmpty, remaining > minSectionBudget {
            let take = min(screen.count, min(remaining, req.screenContextBudget))
            if screen.count > take { screen = String(screen.suffix(take)) }
            let hint = req.screenIsConversation ? " note=\"conversation, newest last\"" : ""
            screenBlock = "<on_screen\(hint)>\n\(screen)\n</on_screen>"
            remaining -= screen.count
        }

        // Previous app/site: explicitly labeled background — budgeted LAST (least
        // trusted), rendered in a stable-ish slot so it doesn't thrash the cache.
        var previousAppBlock: String?
        let prevCtx = req.previousAppContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prevCtx.isEmpty, remaining > minSectionBudget {
            let take = min(prevCtx.count, remaining)
            let snippet = String(prevCtx.suffix(take))
            previousAppBlock = "<from_previous_app name=\"\(req.previousAppName)\">\n\(snippet)\n</from_previous_app>"
            remaining -= snippet.count
        }

        // ASSEMBLY in volatility order: stable sections first, volatile last, so a
        // context change invalidates the smallest possible KV-cache suffix.
        //   documentStart (most stable) → previousWriting → recentMessages
        //   (changes on send) → clipboard (rare) → afterCursor (rare while typing
        //   at the end) → screen (changes every capture).
        let ctxParts = [documentStartBlock, previousWritingBlock, previousAppBlock,
                        recentMessagesBlock, clipBlock, afterBlock, screenBlock].compactMap(\.self)

        if !ctxParts.isEmpty {
            body += "<context>\n" + ctxParts.joined(separator: "\n\n") + "\n</context>\n\n"
        }

        if chatFormat {
            // Recency wins in LLMs: with a big conversation in <context>, the
            // far-away system rules lose and the model starts REPLYING to the
            // other person. This static line sits adjacent to the input — and
            // being constant, it never invalidates the KV prefix.
            if !ctxParts.isEmpty {
                body += Self.continuationReminder
            }
            body += "Input: " + prefix + "\nOutput:"
        } else {
            body += prefix
        }
        return body
    }
}
