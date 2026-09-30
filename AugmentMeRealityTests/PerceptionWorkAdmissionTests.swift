import CoreVideo
import simd
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
    private func buffer(format: OSType = kCVPixelFormatType_OneComponent8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, 8, 8, format, nil, &result),
            kCVReturnSuccess
        )
        return try XCTUnwrap(result)
    }

    private func capture(generation: UInt64, timestamp: TimeInterval = 10,
                         revision: UInt64 = 0) -> OcclusionCapture {
        .init(identity: .init(sessionGeneration: generation, streamRevision: revision,
                              timestamp: timestamp),
              cameraToWorld: matrix_identity_float4x4,
              intrinsics: simd_float3x3(columns: (SIMD3(8, 0, 0), SIMD3(0, 8, 0), SIMD3(4, 4, 1))),
              imageResolution: .init(width: 8, height: 8), trackingNormal: true)
    }

    private func sample(generation: UInt64, timestamp: TimeInterval = 10) throws -> MidFieldDepthFeed.Sample {
        let relative = try buffer(format: kCVPixelFormatType_OneComponent16Half)
        return .init(relativeDepth: relative, a: 1, b: 0.25, relMin: 0, relMax: 1,
                     maxTrustedDepth: 5,
                     raster: .captureAligned(relative, capture: capture(generation: generation, timestamp: timestamp),
                                              encoding: .relativeInverseDepthFloat16,
                                              provenance: .visionScaleFill, ownership: .appOwnedCopy))
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
        XCTAssertNotNil(feed.snapshot(for: capture(generation: 2, timestamp: 10.1), framesAfter: 0, maxAge: 0.5))
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
        XCTAssertNil(feed.snapshot(for: capture(generation: 3, timestamp: 9.9), framesAfter: 0, maxAge: 0.5))
        XCTAssertNil(feed.snapshot(for: capture(generation: 3, timestamp: 10.6), framesAfter: 0, maxAge: 0.5))
        XCTAssertNil(feed.snapshot(for: capture(generation: 4, timestamp: 10.1), framesAfter: 0, maxAge: 0.5))
        XCTAssertNotNil(feed.snapshot(for: capture(generation: 3, timestamp: 10.1), framesAfter: 0, maxAge: 0.5))
    }

    func testSemanticFeedRejectsLateStreamInvalidFormatAndExpiredCapture() throws {
        let feed = SemanticFeed()
        feed.setWorkAdmission(true, generation: 1)
        feed.setStreamRevision(2)
        feed.setEnabled(true)
        let labels = try buffer(), confidence = try buffer()
        XCTAssertFalse(feed.update(labels: labels, confidence: confidence,
                                   capture: capture(generation: 1, revision: 1)))
        XCTAssertTrue(feed.update(labels: labels, confidence: confidence,
                                  capture: capture(generation: 1, revision: 2)))
        XCTAssertNotNil(feed.snapshot(for: capture(generation: 1, revision: 2), framesAfter: 0))
        XCTAssertNil(feed.snapshot(for: capture(generation: 1, timestamp: 11, revision: 2), framesAfter: 0))
        XCTAssertNil(feed.snapshot(for: capture(generation: 1, timestamp: 9, revision: 2), framesAfter: 0))
        XCTAssertFalse(feed.update(labels: try buffer(format: kCVPixelFormatType_DepthFloat32),
                                   confidence: confidence, capture: capture(generation: 1, revision: 2)))
        XCTAssertNil(feed.snapshot(for: capture(generation: 1, revision: 2), framesAfter: 0))
        feed.setStreamRevision(3)
        XCTAssertFalse(feed.update(labels: labels, confidence: confidence,
                                   capture: capture(generation: 1, revision: 2)))
    }

    func testSemanticFeedRequiresNewGenerationAndFreshEnableAfterResume() throws {
        let feed = SemanticFeed()
        let labels = try buffer()
        let confidence = try buffer()
        feed.setWorkAdmission(true, generation: 1)
        feed.update(labels: labels, confidence: confidence, capture: capture(generation: 1))
        feed.setEnabled(true)
        XCTAssertNotNil(feed.snapshot(for: capture(generation: 1), framesAfter: 0))
        feed.setWorkAdmission(false, generation: 2)
        feed.setEnabled(true)
        XCTAssertNil(feed.snapshot(for: capture(generation: 1), framesAfter: 0))
        feed.setWorkAdmission(true, generation: 2)
        feed.setEnabled(true)
        feed.update(labels: labels, confidence: confidence, capture: capture(generation: 1))
        XCTAssertNil(feed.snapshot(for: capture(generation: 2), framesAfter: 0))
        feed.update(labels: labels, confidence: confidence, capture: capture(generation: 2))
        XCTAssertEqual(feed.snapshot(for: capture(generation: 2), framesAfter: 0)?.sessionGeneration, 2)
        XCTAssertNil(feed.snapshot(for: capture(generation: 1), framesAfter: 0))
    }
}
