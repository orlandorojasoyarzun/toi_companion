import XCTest
@testable import ToiCompanion

/// Tests for StickyNoteViewModel.
/// StickyNoteViewModel is @MainActor, so these tests run on the main actor.
@MainActor
final class StickyNoteViewModelTests: XCTestCase {

    func testInitialState_isEmptyAndHidden() {
        let vm = StickyNoteViewModel()
        XCTAssertEqual(vm.text, "")
        XCTAssertFalse(vm.isVisible)
    }

    func testShow_setsVisibleAndInitialText() {
        let vm = StickyNoteViewModel()
        vm.show(initialText: "testing")

        XCTAssertTrue(vm.isVisible)
        XCTAssertEqual(vm.text, "testing")
    }

    func testUpdateText_replacesText() {
        let vm = StickyNoteViewModel()
        vm.show(initialText: "initial")
        vm.updateText("updated")

        XCTAssertEqual(vm.text, "updated")
        XCTAssertTrue(vm.isVisible)  // visibility unchanged
    }

    func testHide_clearsTextAndHides() {
        let vm = StickyNoteViewModel()
        vm.show(initialText: "hello")
        vm.hide()

        XCTAssertFalse(vm.isVisible)
        XCTAssertEqual(vm.text, "")
    }
}
