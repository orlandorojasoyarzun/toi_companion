import XCTest
import CoreGraphics
@testable import ToiCompanion

/// Tests for the HotkeyKey enum: keycodes, display names, and the
/// CGEventFlags bit associated with each key.
final class HotkeyKeyTests: XCTestCase {

    func testRightShift_keycode() {
        XCTAssertEqual(HotkeyKey.rightShift.rawValue, 60)
    }

    func testRightOption_keycode() {
        XCTAssertEqual(HotkeyKey.rightOption.rawValue, 61)
    }

    func testRightShift_displayName() {
        XCTAssertEqual(HotkeyKey.rightShift.displayName, "Right Shift")
    }

    func testRightOption_displayName() {
        XCTAssertEqual(HotkeyKey.rightOption.displayName, "Right Option")
    }

    func testRightShift_pressedFlag_isShift() {
        XCTAssertEqual(HotkeyKey.rightShift.pressedFlag, .maskShift)
    }

    func testRightOption_pressedFlag_isAlternate() {
        XCTAssertEqual(HotkeyKey.rightOption.pressedFlag, .maskAlternate)
    }

    func testRawValue_unknownReturnsNil() {
        XCTAssertNil(HotkeyKey(rawValue: 999))
    }

    func testAllCases_haveUniqueRawValues() {
        let rawValues = HotkeyKey.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }
}
