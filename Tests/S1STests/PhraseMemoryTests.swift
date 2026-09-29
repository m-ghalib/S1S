import XCTest
@testable import S1S

@MainActor
final class PhraseMemoryTests: XCTestCase {

    private func makeMemory(_ entries: [String]) -> PhraseMemory {
        let m = PhraseMemory.shared
        m.rebuild(from: entries)
        return m
    }

    func testRecurringPhraseSuggested() {
        let m = makeMemory([
            "please find the attached invoice for this month",
            "please find the attached invoice for last month",
        ])
        // "find the attached" recurred → continuation walks the chain.
        XCTAssertEqual(m.continuation(after: "hi, please find the attached"), "invoice for")
    }

    func testOneOffPhraseNotSuggested() {
        let m = makeMemory(["a unique sentence typed exactly once here"])
        XCTAssertNil(m.continuation(after: "a unique sentence typed"))
    }

    func testCaseInsensitivePrefixMatch() {
        let m = makeMemory([
            "best regards from the team",
            "best regards from the office",
        ])
        // "regards from" continuation diverges after 1 word ("the" recurs, then splits).
        XCTAssertEqual(m.continuation(after: "Best Regards From"), "the")
    }

    func testShortInputReturnsNil() {
        let m = makeMemory(["one two three four one two three four"])
        XCTAssertNil(m.continuation(after: "one"))
    }

    func testRecentMessagesRenderedBeforeScreenAndChronological() {
        let req = CompletionRequest(
            beforeCursor: "and then I ", afterCursor: "", screenContext: "SCREENTEXT",
            clipboard: "", persona: "",
            recentMessages: ["we should ship the build tonight", "the tests are all green"],
            maxWords: 8, maxTokens: 28, temperature: 0.1)
        let body = PromptBuilder.body(req, cap: 1500)
        guard let m = body.range(of: "<your_previous_messages>"),
              let s = body.range(of: "<on_screen>"),
              let input = body.range(of: "Input:") else {
            return XCTFail("missing sections in: \(body)")
        }
        // Volatility order: recentMessages (changes on send) render BEFORE screen
        // (changes every capture) so screen updates don't invalidate their KV prefix.
        XCTAssertTrue(m.lowerBound < s.lowerBound && s.lowerBound < input.lowerBound)
        let first = body.range(of: "ship the build")!.lowerBound
        let second = body.range(of: "tests are all green")!.lowerBound
        XCTAssertTrue(first < second)
    }

    func testPreviousWritingRenderedBeforeClipboardAndScreen() {
        let req = CompletionRequest(
            beforeCursor: "Hello wor", afterCursor: "", screenContext: "SCREENTEXT",
            clipboard: "CLIPTEXT", persona: "",
            previousWriting: ["I write about distributed systems quite often lately"],
            maxWords: 8, maxTokens: 28, temperature: 0.1)
        let body = PromptBuilder.body(req, cap: 1500)
        guard let w = body.range(of: "<recently_written_by_author>"),
              let c = body.range(of: "<clipboard>"),
              let s = body.range(of: "<on_screen>") else {
            return XCTFail("missing sections in: \(body)")
        }
        XCTAssertTrue(w.lowerBound < c.lowerBound && c.lowerBound < s.lowerBound)
        XCTAssertTrue(body.contains("distributed systems"))
    }

    func testAlternativesRankedByFrequency() {
        let m = makeMemory([
            "let me know if that works",
            "let me know if that helps",
            "let me know if that works",
        ])
        let alts = m.alternatives(after: "please let me know if that", limit: 2)
        XCTAssertEqual(alts.first, "works")
        XCTAssertEqual(alts.count, 2)
    }

    func testTranscriptAssemblyOrdersAndBudgets() {
        let lines: [(text: String, y: CGFloat, x: CGFloat)] = [
            ("second message arrives here with more words", 200, 10),
            ("the first message in the conversation thread", 100, 10),
            ("third reply lands at the bottom of the chat", 300, 10),
        ]
        let out = TranscriptExtractor.assemble(lines: lines, budget: 2000)
        XCTAssertNotNil(out)
        let first = out!.range(of: "first message")!.lowerBound
        let second = out!.range(of: "second message")!.lowerBound
        let third = out!.range(of: "third reply")!.lowerBound
        XCTAssertTrue(first < second && second < third)
        // Budget keeps the SUFFIX (most recent messages).
        let tight = TranscriptExtractor.assemble(lines: lines, budget: 50)
        XCTAssertTrue(tight?.contains("third reply") == true)
        XCTAssertFalse(tight?.contains("first message") == true)
    }

    /// Electron web views clamp scrolled-off rows to the scroll view's top edge,
    /// so many rows share one y. Ties must keep document order, not sort by x.
    func testTranscriptAssemblyKeepsDocumentOrderForClampedRows() {
        let lines: [(text: String, y: CGFloat, x: CGFloat)] = [
            ("The clip: an older heading row", 364, 3232),
            ("an older paragraph that was scrolled away", 364, 3193),
            ("the newest visible reply at the bottom", 900, 3193),
        ]
        let out = TranscriptExtractor.assemble(lines: lines, budget: 2000)!
        let heading = out.range(of: "The clip")!.lowerBound
        let paragraph = out.range(of: "older paragraph")!.lowerBound
        let newest = out.range(of: "newest visible")!.lowerBound
        XCTAssertTrue(heading < paragraph && paragraph < newest)
    }

    func testColumnAnchorRejectsMissingNarrowOrFullWidthFields() {
        let window = CGRect(x: 0, y: 0, width: 1800, height: 1000)
        let composer = CGRect(x: 660, y: 900, width: 781, height: 25)
        XCTAssertEqual(ScreenContextProvider.columnAnchor(field: composer, window: window), composer)
        XCTAssertNil(ScreenContextProvider.columnAnchor(field: nil, window: window))
        XCTAssertNil(ScreenContextProvider.columnAnchor(field: CGRect(x: 0, y: 0, width: 50, height: 20), window: window))
        // A focused web area spans the sidebar too — not a column.
        XCTAssertNil(ScreenContextProvider.columnAnchor(field: CGRect(x: 0, y: 40, width: 1800, height: 960), window: window))
        // No window frame: trust the field.
        XCTAssertEqual(ScreenContextProvider.columnAnchor(field: composer, window: nil), composer)
    }

    func testDomainOverrideAppliesOnTopOfAppPolicy() {
        let saved = AppPolicyStore.userOverrides
        defer { AppPolicyStore.userOverrides = saved }
        var override = AppOverride()
        override.customInstructions = "Formal tone."
        AppPolicyStore.userOverrides = [AppPolicyStore.domainKey("linkedin.com"): override]

        let p = AppPolicyStore.policy(forBundleId: "com.google.Chrome", host: "www.linkedin.com")
        XCTAssertTrue(p.customInstructions.contains("Formal tone."))
        let other = AppPolicyStore.policy(forBundleId: "com.google.Chrome", host: "github.com")
        XCTAssertFalse(other.customInstructions.contains("Formal tone."))
    }

    func testDynamicFewShotRendering() {
        let pairs = [
            TypingHistoryStore.AcceptPair(prefixTail: "see you", accepted: "tomorrow at the office"),
            TypingHistoryStore.AcceptPair(prefixTail: "thanks for", accepted: "the quick review"),
        ]
        let rendered = CompletionInstructions.system(personalExamples: pairs)
        XCTAssertTrue(rendered.contains("Input: see you"))
        XCTAssertTrue(rendered.contains("Output: tomorrow at the office"))
        XCTAssertTrue(rendered.contains("Input: thanks for"))
        // Empty examples → identical to base prompt.
        XCTAssertEqual(CompletionInstructions.system(personalExamples: []), CompletionInstructions.system)
    }
}
