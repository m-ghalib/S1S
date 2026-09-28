import ApplicationServices
import XCTest
@testable import TabType

final class FocusIdentityTests: XCTestCase {
    func testRepeatedAXReferencesDoNotCountAsFocusChange() {
        let first = AXUIElementCreateApplication(getpid())
        let second = AXUIElementCreateApplication(getpid())
        XCTAssertTrue(AccessibilityBridge.sameElement(first, second))
        XCTAssertTrue(AccessibilityBridge.sameElement(nil, nil))
    }

    func testChangedOrLostFocusInvalidatesSuggestion() {
        let first = AXUIElementCreateApplication(getpid())
        let other = AXUIElementCreateApplication(1)
        XCTAssertFalse(AccessibilityBridge.sameElement(first, other))
        XCTAssertFalse(AccessibilityBridge.sameElement(first, nil))
        XCTAssertFalse(AccessibilityBridge.sameElement(nil, first))
    }
}
