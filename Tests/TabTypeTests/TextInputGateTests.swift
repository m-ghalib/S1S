import XCTest
@testable import TabType

/// Keys typed outside an editable text field (games, Finder, web-page
/// shortcuts) must never reach the predictor.
final class TextInputGateTests: XCTestCase {
    func testTextRolesAreInputsEvenWithoutSettableValue() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(AccessibilityBridge.isTextInput(role: role, valueSettable: false), role)
        }
    }

    func testGameAndPageSurfacesAreNotInputs() {
        for role in ["AXWindow", "AXGroup", "AXWebArea", "AXApplication", "AXOutline", "AXList"] {
            XCTAssertFalse(AccessibilityBridge.isTextInput(role: role, valueSettable: false), role)
        }
        XCTAssertFalse(AccessibilityBridge.isTextInput(role: nil, valueSettable: false))
    }

    func testSettableNonTextControlsAreNotInputs() {
        for role in ["AXSlider", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXIncrementor"] {
            XCTAssertFalse(AccessibilityBridge.isTextInput(role: role, valueSettable: true), role)
        }
    }

    func testUnknownRoleWithSettableValueCountsAsEditable() {
        // Custom editors (e.g. contenteditable hosts) expose a settable value
        // under a nonstandard role.
        XCTAssertTrue(AccessibilityBridge.isTextInput(role: "AXGroup", valueSettable: true))
        XCTAssertTrue(AccessibilityBridge.isTextInput(role: nil, valueSettable: true))
    }
}
