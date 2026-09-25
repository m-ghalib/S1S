import XCTest
@testable import TabType

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
