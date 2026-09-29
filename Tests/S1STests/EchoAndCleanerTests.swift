import XCTest
@testable import S1S

final class EchoAndCleanerTests: XCTestCase {

    // MARK: - stripEcho

    func testMidPrefixEchoRejected() {
        // A long echo of the middle of the typed text is still rejected (≥4 words).
        XCTAssertNil(Engine.stripEcho("how fast the autocomplete engine",
                                      prefix: "testing how fast the autocomplete engine works"))
    }

    func testShortMidPrefixRepeatSurvives() {
        // Re-using a short phrase from earlier text is normal writing, not an echo
        // ("sounds good" said twice in one chat) — only the caret-adjacent suffix
        // check treats short repeats as echoes.
        XCTAssertNotNil(Engine.stripEcho("how fast the",
                                         prefix: "testing how fast the autocomplete"))
    }

    func testSingleShortWordRepeatSurvives() {
        // Repeating one short word from earlier text is a legitimate continuation.
        XCTAssertNotNil(Engine.stripEcho("table",
                                         prefix: "put it on the table and grab the other"))
    }

    func testSuffixEchoStillRejected() {
        XCTAssertNil(Engine.stripEcho("fast the autocomplete",
                                      prefix: "testing how fast the autocomplete"))
    }

    func testForwardContinuationSurvives() {
        XCTAssertNotNil(Engine.stripEcho("engine feels today",
                                         prefix: "testing how fast the autocomplete"))
    }

    // MARK: - stripRestatedTail

    func testMidWordRestatementKeepsMissingLetters() {
        XCTAssertEqual(Engine.stripRestatedTail(" I think the key", prefix: "review and I thin"),
                       "k the key")
    }

    func testWordBoundaryRestatementStripped() {
        XCTAssertEqual(Engine.stripRestatedTail(" I think the key", prefix: "and I think"),
                       " the key")
        XCTAssertEqual(Engine.stripRestatedTail("I think the key", prefix: "and I think "),
                       " the key")
    }

    func testSingleWordRepeatNotStripped() {
        XCTAssertEqual(Engine.stripRestatedTail(" that we agreed", prefix: "I know that"),
                       " that we agreed")
    }

    func testForwardContinuationUnchanged() {
        XCTAssertEqual(Engine.stripRestatedTail(" look through it", prefix: "I had a chance to"),
                       " look through it")
    }

    func testFullRestatementRejected() {
        XCTAssertNil(Engine.stripRestatedTail(" I think", prefix: "and I think"))
    }

    // MARK: - OCRCleaner

    func testTwoWordChromeLinesDropped() {
        let out = OCRCleaner.clean([
            "Commit changes", "S1S main", "Fable 5",
            "this is a real sentence of prose text here and it keeps going",
        ])
        XCTAssertFalse(out.contains("Commit changes"))
        XCTAssertFalse(out.contains("S1S main"))
        XCTAssertFalse(out.contains("Fable 5"))
        XCTAssertTrue(out.contains("real sentence of prose"))
    }

    func testShortPunctuatedFragmentSurvives() {
        let out = OCRCleaner.clean([
            "Sounds good.",
            "we should be able to ship the new build by Friday afternoon",
        ])
        XCTAssertTrue(out.contains("Sounds good."))
    }

    func testNearDuplicateFragmentsSuppressed() {
        let out = OCRCleaner.suppressNearDuplicates([
            "Sync-up meeti",
            "Sync-up meeting (Sprint statu",
            "Sync-up meeting (Sprint status review)",
            "completely different content here",
        ])
        XCTAssertEqual(out, ["Sync-up meeting (Sprint status review)",
                             "completely different content here"])
    }

    func testDistinctLinesAllKept() {
        let lines = ["the quick brown fox jumps", "over the lazy dog today"]
        XCTAssertEqual(OCRCleaner.suppressNearDuplicates(lines), lines)
    }
}
