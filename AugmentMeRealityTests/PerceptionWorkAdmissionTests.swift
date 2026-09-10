import CoreVideo
import XCTest

@testable import AugmentMeReality

final class PerceptionWorkAdmissionTests: XCTestCase {
    func testHiddenStateAdmitsNoWork() {
        var admission = PerceptionWorkAdmission()
        XCTAssertNil(admission.token)
        admission.setAllowed(false, generation: 1)
        XCTAssertNil(admission.token)
    }

    func testPrePauseCompletionCannotPublishAfterResume() throws {
        var admission = PerceptionWorkAdmission()
        admission.setAllowed(true, generation: 1)
        let pending = try XCTUnwrap(admission.token)
        admission.setAllowed(false, generation: 2)
        XCTAssertFalse(admission.accepts(pending))
        admission.setAllowed(true, generation: 2)
        XCTAssertFalse(admission.accepts(pending))
        XCTAssertTrue(admission.accepts(try XCTUnwrap(admission.token)))
    }

    func testDisableAndReenableWithinSessionRejectsOldWork() throws {
        var admission = PerceptionWorkAdmission()
        admission.setAllowed(true, generation: 7)
        let pending = try XCTUnwrap(admission.token)
        admission.setAllowed(false, generation: 7)
        admission.setAllowed(true, generation: 7)
        XCTAssertFalse(admission.accepts(pending))
        XCTAssertEqual(admission.token?.sessionGeneration, 7)
    }

    func testRepeatedPolicyUpdateDoesNotInvalidateCurrentWork() throws {
        var admission = PerceptionWorkAdmission()
        admission.setAllowed(true, generation: 4)
        let pending = try XCTUnwrap(admission.token)
        XCTAssertFalse(admission.setAllowed(true, generation: 4))
        XCTAssertTrue(admission.accepts(pending))
        admission.setAllowed(true, generation: 5)
        XCTAssertFalse(admission.accepts(pending))
    }
}

final class PerceptionFeedGenerationTests: XCTestCase {
    private func buffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_OneComponent8, nil, &result),
            kCVReturnSuccess
        )
        return try XCTUnwrap(result)
    }

    private func sample(generation: UInt64, timestamp: TimeInterval = 10) throws -> MidFieldDepthFeed.Sample {
        .init(relativeDepth: try buffer(), a: 1, b: 0, relMin: 0, relMax: 1,
              maxTrustedDepth: 5, frameTimestamp: timestamp, sessionGeneration: generation)
    }

    func testDelayedDepthCannotRepublishAfterResumeAndFreshDepthRecovers() throws {
        let feed = MidFieldDepthFeed()
        feed.setWorkAdmission(true, generation: 1)
        let pending = try XCTUnwrap(feed.admissionToken())
        XCTAssertTrue(feed.publish(try sample(generation: 1), token: pending))
        feed.setWorkAdmission(false, generation: 2)
        XCTAssertFalse(feed.hasSample)
        feed.setWorkAdmission(true, generation: 2)
        XCTAssertFalse(feed.publish(try sample(generation: 1), token: pending))
        XCTAssertFalse(feed.hasSample)
        let fresh = try XCTUnwrap(feed.admissionToken())
        XCTAssertTrue(feed.publish(try sample(generation: 2), token: fresh))
        XCTAssertNotNil(feed.snapshot(forFrameAt: 10.1, maxAge: 0.5, generation: 2))
    }

    func testDepthPublicationRejectsPolicyShedCompletionWithinSameSession() throws {
        let feed = MidFieldDepthFeed()
        feed.setWorkAdmission(true, generation: 9)
        let pending = try XCTUnwrap(feed.admissionToken())
        feed.setWorkAdmission(false, generation: 9)
        feed.setWorkAdmission(true, generation: 9)
        XCTAssertFalse(feed.publish(try sample(generation: 9), token: pending))
    }

    func testDepthConsumerRejectsFutureExpiredAndOtherSessionSamples() throws {
        let feed = MidFieldDepthFeed()
        feed.setWorkAdmission(true, generation: 3)
        let token = try XCTUnwrap(feed.admissionToken())
        XCTAssertTrue(feed.publish(try sample(generation: 3), token: token))
        XCTAssertNil(feed.snapshot(forFrameAt: 9.9, maxAge: 0.5, generation: 3))
        XCTAssertNil(feed.snapshot(forFrameAt: 10.6, maxAge: 0.5, generation: 3))
        XCTAssertNil(feed.snapshot(forFrameAt: 10.1, maxAge: 0.5, generation: 4))
        XCTAssertNotNil(feed.snapshot(forFrameAt: 10.1, maxAge: 0.5, generation: 3))
    }

    func testSemanticFeedRequiresNewGenerationAndFreshEnableAfterResume() throws {
        let feed = SemanticFeed()
        let labels = try buffer()
        let confidence = try buffer()
        feed.setWorkAdmission(true, generation: 1)
        feed.update(labels: labels, confidence: confidence, generation: 1)
        feed.setEnabled(true)
        XCTAssertNotNil(feed.snapshot(generation: 1))
        feed.setWorkAdmission(false, generation: 2)
        feed.setEnabled(true)
        XCTAssertNil(feed.snapshot(generation: 1))
        feed.setWorkAdmission(true, generation: 2)
        feed.setEnabled(true)
        feed.update(labels: labels, confidence: confidence, generation: 1)
        XCTAssertNil(feed.snapshot(generation: 2))
        feed.update(labels: labels, confidence: confidence, generation: 2)
        XCTAssertEqual(feed.snapshot(generation: 2)?.sessionGeneration, 2)
        XCTAssertNil(feed.snapshot(generation: 1))
    }
}
