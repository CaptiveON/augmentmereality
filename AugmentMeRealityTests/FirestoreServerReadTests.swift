import XCTest
@testable import AugmentMeReality

/// Exercises the production callback/deadline seam without linking Firebase
/// into the hosted test bundle. SDK lookup behavior has a separate emulator test.
final class FirestoreServerReadTests: XCTestCase {
    func testConfirmedResponseIsReturned() async throws {
        let responses = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(42)
            continuation.finish()
        }
        let result = try await FirestoreServerRead.race(responses, timeout: 5)
        XCTAssertEqual(result, 42)
    }

    func testPermissionErrorSurvivesForCapabilityClassification() async {
        let refusal = NSError(domain: "test-rules", code: 7)
        let responses = AsyncThrowingStream<Int, Error> { continuation in
            continuation.finish(throwing: refusal)
        }
        do {
            _ = try await FirestoreServerRead.race(responses, timeout: 5)
            XCTFail("A refusal cannot become a document or an absence verdict")
        } catch {
            XCTAssertEqual((error as NSError).domain, refusal.domain)
            XCTAssertEqual((error as NSError).code, refusal.code)
        }
    }

    func testDeadlineTerminatesWaitAndRejectsLateSDKResult() async {
        let (responses, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        defer { continuation.finish() }
        let started = ContinuousClock.now
        do {
            _ = try await FirestoreServerRead.race(responses, timeout: 0.05)
            XCTFail("A silent SDK must not fabricate a response")
        } catch FirestoreServerRead.ReadError.timedOut {
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        } catch {
            XCTFail("Expected the bounded deadline, received \(error)")
        }
        guard case .terminated = continuation.yield(42) else {
            return XCTFail("A late SDK completion must be discarded after timeout")
        }
    }

    func testCancellationTerminatesWaitAndRejectsLateSDKResult() async {
        let (responses, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        defer { continuation.finish() }
        let waiting = Task { try await FirestoreServerRead.race(responses, timeout: 10) }
        // Enter the asynchronous stream wait before cancelling the caller.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let cancelledAt = ContinuousClock.now
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Cancellation must not become a response")
        } catch is CancellationError {
            XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(2))
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
        guard case .terminated = continuation.yield(42) else {
            return XCTFail("A late SDK completion must be discarded after cancellation")
        }
    }

    func testCompletionWithoutSnapshotIsUnknown() async {
        let responses = AsyncThrowingStream<Int, Error> { $0.finish() }
        do {
            _ = try await FirestoreServerRead.race(responses, timeout: 5)
            XCTFail("An empty completion is not a server fact")
        } catch FirestoreServerRead.ReadError.missingResult {
            // The caller maps this to unknown, never absent.
        } catch {
            XCTFail("Expected a missing result, received \(error)")
        }
    }
}
