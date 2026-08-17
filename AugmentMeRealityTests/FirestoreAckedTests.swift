import XCTest
@testable import AugmentMeReality

/// Round 8 (counsel process item): the single write seam previously had ZERO
/// executing tests — its race was private and required a Firestore connection.
/// `race` is the injectable seam: the stream IS the ack source, so all four
/// outcome mappings run here without Firebase (which this bundle must not
/// link — gRPC double-links).
final class FirestoreAckedTests: XCTestCase {

    func testServerAckResolvesAcked() async {
        let ack = AsyncThrowingStream<Void, Error> { continuation in
            continuation.yield(())
            continuation.finish()
        }
        let outcome = await FirestoreAcked.race(ack, timeout: 5)
        guard case .acked = outcome else {
            return XCTFail("a yielded ack must resolve .acked, got \(outcome)")
        }
    }

    func testServerRefusalResolvesRejected() async {
        let refusal = NSError(
            domain: "test", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        let ack = AsyncThrowingStream<Void, Error> { continuation in
            continuation.finish(throwing: refusal)
        }
        let outcome = await FirestoreAcked.race(ack, timeout: 5)
        guard case .rejected(let error) = outcome else {
            return XCTFail("a thrown ack must resolve .rejected, got \(outcome)")
        }
        XCTAssertEqual((error as NSError).code, 7)
    }

    func testSilenceResolvesQueuedLocallyAtDeadline() async {
        let ack = AsyncThrowingStream<Void, Error> { _ in } // never answers
        let outcome = await FirestoreAcked.race(ack, timeout: 0.05)
        guard case .queuedLocally = outcome else {
            return XCTFail("an unanswered ack must resolve .queuedLocally, got \(outcome)")
        }
    }

    /// Round 10 (counsel seams-6): a stream that ends WITHOUT a yield is not
    /// a server confirmation — `.acked` is earned only by an explicit ack;
    /// every other end of the stream is the truthful unknown.
    func testNoYieldFinishResolvesQueuedLocallyNeverAcked() async {
        let ack = AsyncThrowingStream<Void, Error> { continuation in
            continuation.finish()
        }
        let outcome = await FirestoreAcked.race(ack, timeout: 5)
        guard case .queuedLocally = outcome else {
            return XCTFail("a no-yield finish fabricated a verdict: \(outcome)")
        }
    }

    /// Round 8 (counsel seam-1 regression lock): cancelling the caller must
    /// resolve `.queuedLocally` — the AsyncThrowingStream iterator returns nil
    /// on cancellation exactly as it does on a clean finish, and the old code
    /// read that as a server confirmation the server never issued.
    func testCancellationResolvesQueuedLocallyNeverAcked() async {
        let ack = AsyncThrowingStream<Void, Error> { _ in } // never answers
        let racing = Task { await FirestoreAcked.race(ack, timeout: 10) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        racing.cancel()
        let outcome = await racing.value
        guard case .queuedLocally = outcome else {
            return XCTFail("cancellation fabricated a verdict: \(outcome)")
        }
    }
}
