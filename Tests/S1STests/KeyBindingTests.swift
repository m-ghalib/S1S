import XCTest
@testable import S1S

final class KeyBindingTests: XCTestCase {

    func testBacktickKeyName() {
        XCTAssertEqual(KeyBinding.keyName(50), "`")
    }

    func testForceSuggestDefaultDisplay() {
        XCTAssertEqual(KeyBinding.controlBacktick.displayString, "⌃`")
    }

    func testDigitPunctuationAndFunctionKeys() {
        XCTAssertEqual(KeyBinding.keyName(18), "1")
        XCTAssertEqual(KeyBinding.keyName(42), "\\")
        XCTAssertEqual(KeyBinding.keyName(117), "⌦")
        XCTAssertEqual(KeyBinding.keyName(122), "F1")
    }
}
