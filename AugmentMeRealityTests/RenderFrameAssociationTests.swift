import Foundation
import simd
import XCTest

@testable import AugmentMeReality

final class RenderFrameAssociationTests: XCTestCase {
    private let generation: UInt64 = 9
    private let revision: UInt64 = 3

    private func capture(
        at timestamp: TimeInterval,
        generation: UInt64 = 9,
        revision: UInt64 = 3,
        trackingNormal: Bool = true,
        translation: Float = 0,
        yaw: Float = 0,
        principalX: Float = 623
    ) -> OcclusionCapture {
        var pose = matrix_identity_float4x4
        pose.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
        pose.columns.2 = SIMD4(sin(yaw), 0, cos(yaw), 0)
        pose.columns.3.x = translation
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(1_103, 0, 0),
            SIMD3<Float>(0, 713, 0),
            SIMD3<Float>(principalX, 411, 1)
        ))
        return OcclusionCapture(
            identity: .init(sessionGeneration: generation, streamRevision: revision,
                            timestamp: timestamp),
            cameraToWorld: pose,
            intrinsics: intrinsics,
            imageResolution: .init(width: 1_600, height: 900),
            trackingNormal: trackingNormal
        )
    }

    private func context(
        observedAt: TimeInterval,
        sceneElapsed: TimeInterval,
        viewportSize: SIMD2<Float> = [720, 1_280],
        targetSize: SIMD2<Float> = [720, 1_280],
        orientation: Int = 1,
        viewportObservedAt: TimeInterval? = nil,
        projection: simd_float4x4 = matrix_identity_float4x4,
        captureProjection: simd_float4x4 = matrix_identity_float4x4,
        mapping: simd_float3x3 = matrix_identity_float3x3
    ) -> RenderFrameAssociation.Context {
        .init(
            observedAt: observedAt,
            sceneElapsedTime: sceneElapsed,
            viewport: .init(size: viewportSize, orientation: orientation,
                            observedAt: viewportObservedAt ?? observedAt),
            targetSize: targetSize,
            renderProjection: projection,
            captureProjection: captureProjection,
            viewToCapture: mapping
        )
    }

    func testStableFreshCapturesAdmitOnlyAfterBoundedMotionHistory() {
        var policy = RenderFrameAssociation()
        let first = capture(at: 100)
        let second = capture(at: 100.04)
        XCTAssertEqual(policy.evaluate(capture: first,
            context: context(observedAt: 100.02, sceneElapsed: 4.0),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.warmingUp))
        // Scene elapsed time is a separate clock; 4.016 is never subtracted
        // from ARKit's 100.04-second uptime timestamp.
        XCTAssertEqual(policy.evaluate(capture: second,
            context: context(observedAt: 100.06, sceneElapsed: 4.016),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .approximate)
    }

    func testDelayedInferenceRequiresTheSameCaptureStreamCalibrationAndPose() {
        let sample = capture(at: 100)
        let current = capture(at: 100.04)
        func reject(_ candidate: OcclusionCapture, _ frame: OcclusionCapture,
                    framesAfter: TimeInterval = 99) -> RenderFrameAssociation.Rejection? {
            RenderFrameAssociation.sampleRejection(
                candidate, relativeTo: frame, framesAfter: framesAfter, maxAge: 0.075)
        }
        XCTAssertNil(reject(sample, current))
        XCTAssertEqual(reject(capture(at: 100.05), current), .future)
        XCTAssertEqual(reject(capture(at: 99.9), current), .expired)
        XCTAssertEqual(reject(capture(at: 100, generation: 8), current), .generation)
        XCTAssertEqual(reject(capture(at: 100, revision: 2), current), .stream)
        XCTAssertEqual(reject(sample, current, framesAfter: 100), .beforeStream)
        XCTAssertEqual(reject(capture(at: 100, trackingNormal: false), current), .tracking)
        XCTAssertEqual(reject(capture(at: 100, principalX: 625), current), .calibration)
        XCTAssertEqual(reject(capture(at: 100, translation: 0.01), current), .motion)
        XCTAssertEqual(reject(capture(at: 100, yaw: 0.02), current), .motion)
    }

    func testLiveRenderRejectsFutureExpiredAndResetStreamFrames() {
        var policy = RenderFrameAssociation()
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.1),
            context: context(observedAt: 100.09, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.future))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.051, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.expired))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100, generation: 8),
            context: context(observedAt: 100.01, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.generation))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100, revision: 2),
            context: context(observedAt: 100.01, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.stream))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 100),
            .rejected(.beforeStream))
    }

    func testProjectionMismatchAndViewportChangeResetAssociationHistory() {
        var policy = RenderFrameAssociation()
        let first = capture(at: 100)
        XCTAssertEqual(policy.evaluate(capture: first,
            context: context(observedAt: 100.01, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.warmingUp))

        // A 0.01 NDC x shift moves these rays 3.6 pixels in a 720-pixel
        // target, well beyond the one-pixel agreement limit.
        var shiftedProjection = matrix_identity_float4x4
        shiftedProjection.columns.3.x = 0.01
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.04),
            context: context(observedAt: 100.05, sceneElapsed: 1.016,
                             captureProjection: shiftedProjection),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.projection))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.08),
            context: context(observedAt: 100.09, sceneElapsed: 1.032),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.warmingUp), "rejected geometry must discard old history")
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.12),
            context: context(observedAt: 100.13, sceneElapsed: 1.048),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .approximate)

        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.16),
            context: context(observedAt: 100.17, sceneElapsed: 1.064,
                             viewportSize: [900, 1_600], targetSize: [900, 1_600]),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.viewport))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.20),
            context: context(observedAt: 100.21, sceneElapsed: 1.080,
                             viewportSize: [900, 1_600], targetSize: [900, 1_600]),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .approximate)
    }

    func testPanAndClockRegressionRefuseApproximateAssociation() {
        var policy = RenderFrameAssociation()
        _ = policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 12),
            generation: generation, streamRevision: revision, framesAfter: 99)
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.04, yaw: 0.02),
            context: context(observedAt: 100.05, sceneElapsed: 12.016),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.motion))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.08, yaw: 0.02),
            context: context(observedAt: 100.09, sceneElapsed: 12.016),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.renderClock))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.12, yaw: 0.02),
            context: context(observedAt: 100.13, sceneElapsed: 0.1),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.warmingUp), "clock reset starts a new association history")
    }

    func testCalibrationOrientationAndCropChangeRequireFreshHistory() {
        var policy = RenderFrameAssociation()
        _ = policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 99)
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.04, principalX: 625),
            context: context(observedAt: 100.05, sceneElapsed: 1.016),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.calibration))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.08, principalX: 625),
            context: context(observedAt: 100.09, sceneElapsed: 1.032),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .approximate)

        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.12, principalX: 625),
            context: context(observedAt: 100.13, sceneElapsed: 1.048,
                             orientation: 3),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.viewport))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.16, principalX: 625),
            context: context(observedAt: 100.17, sceneElapsed: 1.064,
                             orientation: 3),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .approximate)

        var shiftedCrop = matrix_identity_float3x3
        shiftedCrop.columns.2.x = 0.02
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.20, principalX: 625),
            context: context(observedAt: 100.21, sceneElapsed: 1.080,
                             orientation: 3, mapping: shiftedCrop),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.viewport))
    }

    func testCalibrationDriftCannotAccumulateAcrossMotionHistory() {
        var policy = RenderFrameAssociation()
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100, principalX: 623),
            context: context(observedAt: 100.01, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.warmingUp))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.04, principalX: 623.2),
            context: context(observedAt: 100.05, sceneElapsed: 1.016),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .approximate)
        // Each adjacent K differs by 0.2 px; the oldest and newest differ
        // by 0.4 px, exceeding the 0.25 px history tolerance.
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100.08, principalX: 623.4),
            context: context(observedAt: 100.09, sceneElapsed: 1.032),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.calibration))
    }

    func testViewportAndTrackingInputsMustBeCurrentAndWellFormed() {
        var policy = RenderFrameAssociation()
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100, trackingNormal: false),
            context: context(observedAt: 100.01, sceneElapsed: 1),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.tracking))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 1,
                             viewportSize: [720, 1_280], targetSize: [1_280, 720]),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.viewport))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 1, orientation: 0),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.viewport))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 1,
                             viewportObservedAt: 99.7),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.viewport))
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 1,
                             viewportObservedAt: 99.95),
            generation: generation, streamRevision: revision, framesAfter: 99.97),
            .rejected(.viewport), "a recently measured pre-run viewport is stale")
        var offImage = matrix_identity_float3x3
        offImage.columns.2.x = 5
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 1,
                             mapping: offImage),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.viewport), "valid affine algebra can still sample outside the image")
        var croppedEdge = matrix_identity_float3x3
        croppedEdge.columns.0.x = 1.1
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: 1,
                             mapping: croppedEdge),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.viewport), "a centered mapping may still clamp an edge")
        XCTAssertEqual(policy.evaluate(capture: capture(at: 100),
            context: context(observedAt: 100.01, sceneElapsed: .nan),
            generation: generation, streamRevision: revision, framesAfter: 99),
            .rejected(.renderClock))
    }
}
