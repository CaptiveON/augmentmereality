#if DEBUG
import XCTest
@testable import AugmentMeReality

/// Opt-in native SDK semantics test, separate from the live console probe and
/// from rules authorization tests. See web/rules-tests/NATIVE-SDK-TESTS.md.
final class FirestoreServerReadEmulatorTests: XCTestCase {
    func testPendingDeleteCannotFabricateAuthoritativeAbsence() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AMR_NATIVE_FIRESTORE_EMULATOR_TEST"] == "1",
            "Requires the explicit loopback demo Firestore SDK fixture"
        )
        let report = try await FirestoreServerReadEmulatorProbe.run()
        check(report)
    }

    private func check(_ report: FirestoreServerReadEmulatorProbe.Report) {
        XCTAssertFalse(report.oldServerReadExists, "Exercise the original .server overlay defect")
        XCTAssertFalse(report.oldServerReadHasPendingWrites, "Metadata alone cannot detect this delete")
        XCTAssertTrue(report.authoritativeReadExistsDuringPendingDelete)
        XCTAssertEqual(report.rejectedDeleteCode, 7, "The fixture must reject the queued delete")
        XCTAssertTrue(report.authoritativeReadExistsAfterRejection)
        XCTAssertFalse(report.authoritativeReadExistsAfterAckedDelete)
        XCTAssertEqual(report.deniedReadCode, 7, "Read denial is an error, never absence")
        XCTAssertTrue(report.unansweredReadProducedNoSnapshot)
        XCTAssertLessThan(report.unansweredReadElapsed, 2, "An unreachable read must respect its deadline")
        XCTAssertGreaterThan(report.heldWriteRPCs, 0, "The delayed-write path must really run")
        XCTAssertGreaterThan(report.heldReadRPCs, 0, "The unresponsive-read path must really run")
        XCTAssertTrue(report.nativeReactionWireShapeMatches, "Exercise the actual native Firestore encoder")
    }
}
#endif
