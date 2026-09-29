import XCTest
@testable import S1S

final class CaretTextTests: XCTestCase {
    private func split(_ full: String, rawCaret: Int, runs: [String]) throws -> AccessibilityBridge.CaretText {
        let candidates = AccessibilityBridge.valueCarets(full: full, caret: rawCaret, runs: runs)
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        return AccessibilityBridge.splitText(full, caret: candidate.valueOffset)
    }

    func testParagraphSeparatorsAreRetainedAtEnd() throws {
        let runs = ["First paragraph.", "Second paragraph.", "Third ends with zebra"]
        let full = runs.joined(separator: "\n")
        let text = try split(full, rawCaret: runs.joined().utf16.count, runs: runs)
        XCTAssertEqual(text.before, full)
        XCTAssertEqual(text.after, "")
    }

    func testMiddleParagraphHasExactBeforeAndAfterText() throws {
        let runs = ["First.", "Second paragraph.", "Third."]
        let full = runs.joined(separator: "\n")
        let text = try split(full, rawCaret: "First.Second par".utf16.count, runs: runs)
        XCTAssertEqual(text.before, "First.\nSecond par")
        XCTAssertEqual(text.after, "agraph.\nThird.")
    }

    func testBlankParagraphsAndUnicodeArePreserved() throws {
        let runs = ["Hi 👩🏽‍💻 cafe\u{301}", "Next", "Ends here"]
        let full = runs.joined(separator: "\n\n")
        let text = try split(full, rawCaret: runs.joined().utf16.count, runs: runs)
        XCTAssertEqual(text.before, full)
        XCTAssertEqual(text.after, "")
    }

    func testParagraphBoundaryHasTwoValueOffsetsForLineDisambiguation() {
        let candidates = AccessibilityBridge.valueCarets(full: "abc\n\nde", caret: 3, runs: ["abc", "de"])
        XCTAssertEqual(candidates, [
            .init(run: 0, localOffset: 3, valueOffset: 3),
            .init(run: 1, localOffset: 0, valueOffset: 5)
        ])
    }

    func testInlineRunsDoNotIntroduceSeparators() {
        let candidates = AccessibilityBridge.valueCarets(full: "abcde\nfgh", caret: 4, runs: ["abc", "de", "fgh"])
        XCTAssertEqual(candidates, [.init(run: 1, localOffset: 1, valueOffset: 4)])
    }

    func testStaleOrIncompleteRunsAreRejected() {
        XCTAssertTrue(AccessibilityBridge.valueCarets(full: "abc\ndef", caret: 5, runs: ["abc", "xyz"]).isEmpty)
        XCTAssertTrue(AccessibilityBridge.valueCarets(full: "abc\ndef", caret: 3, runs: ["abc"]).isEmpty)
        XCTAssertTrue(AccessibilityBridge.valueCarets(full: "abc\ndef", caret: 99, runs: ["abc", "def"]).isEmpty)
    }

    func testNativeUTF16OffsetWithEmojiAndCombiningCharacters() {
        let before = "Hi 👩🏽‍💻 cafe\u{301}\n"
        let text = AccessibilityBridge.splitText(before + "next", caret: before.utf16.count)
        XCTAssertEqual(text.before, before)
        XCTAssertEqual(text.after, "next")
    }

    func testEmptyComposerAndNativeFallback() {
        XCTAssertEqual(AccessibilityBridge.splitText("\n", caret: 0).before, "")
        XCTAssertEqual(AccessibilityBridge.splitText("abc", caret: nil).before, "abc")
        XCTAssertEqual(AccessibilityBridge.splitText("abc", caret: 999).before, "abc")
        XCTAssertEqual(AccessibilityBridge.splitText("abc", caret: -1).before, "")
    }
}
