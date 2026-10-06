import XCTest
@testable import ToiCompanion

/// Tests for CursorPositioner.
/// The sticky note should be positioned near the cursor, clamped to the screen.
final class CursorPositionerTests: XCTestCase {

    func testComputedOrigin_isWithinScreenBounds() {
        let positioner = CursorPositioner()
        let origin = positioner.computeOrigin()

        // Origin should always be within reasonable screen bounds.
        // macOS screens are at least 800x600 in practice.
        XCTAssertGreaterThan(origin.x, 0, "Origin X should be positive")
        XCTAssertGreaterThan(origin.y, 0, "Origin Y should be positive")
    }

    func testPanelSize_isReasonable() {
        let positioner = CursorPositioner()

        // Panel should be between 200-400pt wide and 100-300pt tall.
        XCTAssertGreaterThan(positioner.panelWidth, 200)
        XCTAssertLessThan(positioner.panelWidth, 400)
        XCTAssertGreaterThan(positioner.panelHeight, 100)
        XCTAssertLessThan(positioner.panelHeight, 300)
    }

    func testPanelIsWiderThanTall() {
        let positioner = CursorPositioner()
        XCTAssertGreaterThan(positioner.panelWidth, positioner.panelHeight)
    }
}
