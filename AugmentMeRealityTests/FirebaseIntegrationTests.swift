import XCTest

@testable import AugmentMeReality

/// ADR-039 acceptance: proves the user's Firebase console setup end-to-end on
/// device via the app-module probe (the test bundle must not link Firebase —
/// Firestore's gRPC double-links). Skips clean on unconfigured checkouts.
final class FirebaseIntegrationTests: XCTestCase {

    func testAnonymousAuthAndFirestoreRoundTrip() async throws {
        try XCTSkipUnless(
            AppConfig.firebaseConfigured,
            "GoogleService-Info.plist not bundled — Firebase off"
        )
        let report = try await FirebaseHealthcheck.run()
        XCTAssertTrue(report.contains("dropStoreOK"), report)
    }
}
