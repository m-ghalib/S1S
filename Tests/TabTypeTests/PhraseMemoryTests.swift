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
