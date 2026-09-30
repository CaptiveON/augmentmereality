#if DEBUG
import XCTest
@testable import AugmentMeReality

/// Opt-in native SDK regression against the loopback owner-page fixture.
final class FirestoreOwnerPagingEmulatorTests: XCTestCase {
    func testProductionOwnerPagingIsBoundedScopedAndPreservesPendingProvenance() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AMR_NATIVE_FIRESTORE_EMULATOR_TEST"] == "1",
            "Requires the explicit loopback demo Firestore SDK fixture"
        )
        let report = try await FirestoreOwnerPagingEmulatorProbe.run()
        XCTAssertEqual(report.smallPageCount, 10)
        XCTAssertEqual(report.largePageCounts, [64, 64, 2])
        XCTAssertEqual(report.largeUniqueRows, 130)
        XCTAssertTrue(report.foreignQueriesDenied)
        XCTAssertTrue(report.pendingRowWasDisplayed)
        XCTAssertTrue(report.pendingRowWasUnconfirmed)
        XCTAssertTrue(report.pendingPageWasServerServed)
        XCTAssertTrue(report.pendingPageBlockedCursor)
        XCTAssertTrue(report.heldOwnerWriteRPC)
        XCTAssertTrue(report.pendingDeleteCacheMissing)
        XCTAssertLessThanOrEqual(report.pendingDeletePageCount, OwnerLibraryPagingPolicy.pageSize)
        XCTAssertTrue(report.pendingDeletePageWasServerServed)
        XCTAssertTrue(report.pendingDeletePageBlockedCursor)
        XCTAssertTrue(report.heldOwnerDeleteRPC)
        XCTAssertGreaterThan(report.smallPageMilliseconds, 0)
        XCTAssertEqual(report.largePageMilliseconds.count, 3)
        XCTAssertTrue(report.largePageMilliseconds.allSatisfy { $0 > 0 })
    }
}
#endif
