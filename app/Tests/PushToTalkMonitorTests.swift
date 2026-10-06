import XCTest
import CoreGraphics
@testable import ToiCompanion

/// Tests for the press/release detection logic in PushToTalkMonitor.
/// The CGEvent tap itself can't be unit-tested (it requires macOS
/// to deliver real events to the app's session), so we exercise the
/// pure decision function instead.
final class PushToTalkMonitorTests: XCTestCase {

    // MARK: - Right Shift

    func testShift_pressWhenFlagSet() {
        let nowPressed = PushToTalkMonitor.updatePressedState(
            for: .rightShift,
            eventKeycode: 60,
            eventFlags: .maskShift,
            wasPressed: false
        )
        XCTAssertTrue(nowPressed)
    }

    func testShift_releaseWhenFlagClear() {
        let nowPressed = PushToTalkMonitor.updatePressedState(
            for: .rightShift,
            eventKeycode: 60,
            eventFlags: [],
            wasPressed: true
        )
        XCTAssertFalse(nowPressed)
    }

    func testShift_ignoresOtherKeycodes() {
        // Some other key changed flags (e.g. Caps Lock) — we don't care.
        let nowPressed = PushToTalkMonitor.updatePressedState(
            for: .rightShift,
            eventKeycode: 57,            // Caps Lock keycode
            eventFlags: .maskShift,
            wasPressed: false
        )
        XCTAssertFalse(nowPressed)
    }

    // MARK: - Right Option

    func testOption_pressWhenFlagSet() {
        let nowPressed = PushToTalkMonitor.updatePressedState(
            for: .rightOption,
            eventKeycode: 61,
            eventFlags: .maskAlternate,
            wasPressed: false
        )
        XCTAssertTrue(nowPressed)
    }

    func testOption_releaseWhenFlagClear() {
        let nowPressed = PushToTalkMonitor.updatePressedState(
            for: .rightOption,
            eventKeycode: 61,
            eventFlags: [.maskShift],    // shift held, option released
            wasPressed: true
        )
        XCTAssertFalse(nowPressed)
    }

    func testOption_ignoresLeftOptionKeycode() {
        // Left Option is keycode 58. If the user hits left option, we
        // should NOT trigger our hotkey (which targets the right one).
        let nowPressed = PushToTalkMonitor.updatePressedState(
            for: .rightOption,
            eventKeycode: 58,
            eventFlags: .maskAlternate,
            wasPressed: false
        )
        XCTAssertFalse(nowPressed)
    }

    // MARK: - State preservation

    func testPreservesState_whenEventIsForOtherKey() {
        // Shift was already pressed; an unrelated key changed flags.
        // The pressed state of our hotkey should not change.
        let nowPressed = PushToTalkMonitor.updatePressedState(
            for: .rightShift,
            eventKeycode: 0,             // some non-hotkey keycode
            eventFlags: [],
            wasPressed: true
        )
        XCTAssertTrue(nowPressed)
    }
}
