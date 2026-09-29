import XCTest
@testable import S1S

/// Decides when the post-paint caret re-check redraws a ghost drawn at a stale caret.
final class CaretPlacementTests: XCTestCase {

    private let painted = CGRect(x: 200, y: 400, width: 1, height: 17)

    func testStaleCaretFromBurstTriggersRedraw() {
        // Caret read mid-burst; the real caret is 180pt further right.
        let fresh = painted.offsetBy(dx: 180, dy: 0)
        XCTAssertTrue(Engine.caretMoved(from: painted, to: fresh))
    }

    func testLineChangeTriggersRedraw() {
        XCTAssertTrue(Engine.caretMoved(from: painted, to: painted.offsetBy(dx: 0, dy: 18)))
    }

    func testSubPointJitterIgnored() {
        XCTAssertFalse(Engine.caretMoved(from: painted, to: painted.offsetBy(dx: 0.5, dy: -0.5)))
        XCTAssertFalse(Engine.caretMoved(from: painted, to: painted))
    }
}

/// Caret resolution for Chromium composers whose own bounds queries fail
/// (Claude Desktop): line-box rejection and caret-to-text-run mapping.
final class StaticTextCaretTests: XCTestCase {

    func testLineBoxIsNotACaret() {
        XCTAssertFalse(AccessibilityBridge.isCaretWidth(CGRect(x: 941, y: 985, width: 691, height: 24)))
        XCTAssertTrue(AccessibilityBridge.isCaretWidth(CGRect(x: 1165, y: 986, width: 0, height: 21)))
        XCTAssertTrue(AccessibilityBridge.isCaretWidth(CGRect(x: 955, y: 282, width: 2, height: 22)))
    }

    private func locs(_ caret: Int, _ lengths: [Int]) -> [[Int]] {
        AccessibilityBridge.runLocations(caret: caret, runLengths: lengths).map { [$0.run, $0.offset] }
    }

    func testCaretInSingleRun() {
        XCTAssertEqual(locs(1, [1]), [[0, 1]])
        XCTAssertEqual(locs(0, [1]), [[0, 0]])
    }

    func testCaretAtEndOfSecondParagraphSkipsSeparator() {
        // "some…okay\nnext para": Chromium reports the end caret as 109 + 9.
        XCTAssertEqual(locs(118, [109, 9]), [[1, 9]])
        XCTAssertEqual(locs(112, [109, 9]), [[1, 3]])
    }

    func testRunBoundaryIsAmbiguous() {
        // End of paragraph 1 and start of paragraph 2 share offset 5.
        XCTAssertEqual(locs(5, [5, 3]), [[0, 5], [1, 0]])
    }

    func testCaretPastAllRunsOrNoRuns() {
        XCTAssertEqual(locs(9, [5, 3]), [])
        XCTAssertEqual(locs(0, []), [])
        XCTAssertEqual(locs(-1, [5]), [])
    }

    func testBoundaryCaretSettledByLineBox() {
        let endOfLine1 = CGRect(x: 1203, y: 963, width: 1, height: 21)
        let startOfLine2 = CGRect(x: 1093, y: 986, width: 1, height: 21)
        let line2 = CGRect(x: 1093, y: 985, width: 756, height: 24)
        XCTAssertEqual(AccessibilityBridge.pickCaret([endOfLine1, startOfLine2], line: line2), startOfLine2)
        // No line box, or one spanning both lines: no guess.
        XCTAssertNil(AccessibilityBridge.pickCaret([endOfLine1, startOfLine2], line: nil))
        XCTAssertNil(AccessibilityBridge.pickCaret(
            [endOfLine1, startOfLine2], line: CGRect(x: 1093, y: 939, width: 756, height: 70)))
        // Unambiguous caret passes through.
        XCTAssertEqual(AccessibilityBridge.pickCaret([startOfLine2], line: nil), startOfLine2)
    }
}

/// When the engine retries because AX may not have published a keystroke yet.
final class LateAXPublishTests: XCTestCase {

    func testRecentTypingWithEmptyFieldRetries() {
        XCTAssertTrue(Engine.awaitingLateAXPublish(buffer: "s", sinceKeystroke: 0.45))
    }

    func testStaleBufferDoesNotRetry() {
        XCTAssertFalse(Engine.awaitingLateAXPublish(buffer: "there has to be another", sinceKeystroke: 4))
        XCTAssertFalse(Engine.awaitingLateAXPublish(buffer: "  ", sinceKeystroke: 0.1))
    }
}

/// When the keystroke buffer may stand in for the field's AX text.
final class InputResolutionTests: XCTestCase {

    func testEmptyReadableFieldIgnoresStaleBuffer() {
        // Claude Desktop's composer right after sending: AX "" before caret 0.
        XCTAssertEqual(ContextReader.resolveInput(
            axText: "", caretReadable: true,
            fallbackBuffer: " there has to be another", inputChars: 40), "")
    }

    func testUnreadableFieldUsesBuffer() {
        XCTAssertEqual(ContextReader.resolveInput(
            axText: nil, caretReadable: false, fallbackBuffer: "hello", inputChars: 40), "hello")
        XCTAssertEqual(ContextReader.resolveInput(
            axText: "", caretReadable: false, fallbackBuffer: "hello", inputChars: 3), "llo")
    }

    func testAXTextWins() {
        XCTAssertEqual(ContextReader.resolveInput(
            axText: "gho", caretReadable: true, fallbackBuffer: "zzz", inputChars: 40), "gho")
    }
}
