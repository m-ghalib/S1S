import Foundation

/// The instruction + few-shot prompt shared by every engine that supports a system
/// role (Apple Intelligence's `LanguageModelSession`, and the local MLX engine when
/// running an instruct-tuned model via a chat template). Kept in one place so the two
/// engines can't drift apart.
enum CompletionInstructions {
    /// Full system prompt: the static base plus up to 2 examples drawn from the
    /// user's own recently ACCEPTED completions — the model sees this author's real
    /// register instead of only generic examples ("sounds like you"). Examples
    /// change only on accept, so the KV prefix cache stays warm between keystrokes.
    static func system(personalExamples: [TypingHistoryStore.AcceptPair]) -> String {
        guard !personalExamples.isEmpty else { return system }
        var s = system + "\n\nRecent continuations this author accepted (match their voice):"
        for pair in personalExamples.suffix(2) {
            s += "\nInput: \(pair.prefixTail)\nOutput: \(pair.accepted)"
        }
        return s
    }

    static let system = """
    You are an inline autocomplete engine. You ARE the author of the text after "Input:". Never reply to it, answer it, comment on it, or address the reader — continue the text naturally with the words or phrase the author themselves would type next (typically 3-10 words), seamlessly from the last character.

    RULES:
    1. Output ONLY the continuation itself. No greetings, explanations, quotes, or markdown.
    2. DO NOT repeat any of the existing text.
    3. Match the author's language, casing, tone, and punctuation exactly.
    4. If the text is a question addressed to someone else, keep writing the question — do not answer it.
    5. A <context> block may show the author's recent writing, text after the cursor, clipboard contents, or nearby on-screen text. Use it only as background — it reflects the author's voice and current topics; never copy it verbatim and never respond to it.
    6. Prefer finishing the current sentence naturally before starting a new one.

    Examples:
    Input: I just wanted to follow up on the
    Output: proposal we discussed last week

    Input: okay testing again
    Output: with the latest version of the app

    Input: hey, are you free to
    Output: hop on a quick call later today?

    Input: Could you send me the repo
    Output: link when you get a chance?

    <context>
    <text_after_cursor>
    Best regards, Sam
    </text_after_cursor>
    </context>

    Input: Thanks for the quick turnar
    Output: ound on the contract review.
    """
}
