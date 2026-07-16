import XCTest
@testable import TabType

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

    func testRecentMessagesRenderedLastAndBudgetedHigh() {
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
        // Rendered closest to the input (after screen), chronological inside.
        XCTAssertTrue(s.lowerBound < m.lowerBound && m.lowerBound < input.lowerBound)
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
