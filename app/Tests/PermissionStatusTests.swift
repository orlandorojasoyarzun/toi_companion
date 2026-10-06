import XCTest
@testable import ToiCompanion

/// Tests for the PermissionStatus enum — the public-facing result of
/// permission prompts. PermissionGate itself is hard to unit-test because
/// it triggers real TCC dialogs, but the mapping logic is what we care about.
final class PermissionStatusTests: XCTestCase {

    func testRawValues_areUnique() {
        let statuses: [PermissionStatus] = [.granted, .denied, .restricted, .unknown]
        let rawValues = statuses.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, statuses.count)
    }

    func testRawValues_areStable() {
        // These raw values show up in logs and (potentially) persistence.
        // Don't change them without a migration plan.
        XCTAssertEqual(PermissionStatus.granted.rawValue,    "granted")
        XCTAssertEqual(PermissionStatus.denied.rawValue,     "denied")
        XCTAssertEqual(PermissionStatus.restricted.rawValue, "restricted")
        XCTAssertEqual(PermissionStatus.unknown.rawValue,    "unknown")
    }
}
