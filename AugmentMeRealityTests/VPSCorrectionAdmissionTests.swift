import XCTest
import simd
@testable import AugmentMeReality

final class VPSCorrectionAdmissionTests: XCTestCase {
    private let id = UUID()
    private let camera = SIMD3<Float>(0, 0, 0)

    private func pose(x: Float = 0, yawDegrees: Float = 0) -> VPSCorrectionAdmission.Pose {
        VPSCorrectionAdmission.Pose(
            position: SIMD3(x, 0, -5),
            rotation: simd_quatf(angle: yawDegrees * .pi / 180, axis: [0, 1, 0])
        )
    }

    private func matrix(x: Float = 0, yawDegrees: Float = 0,
                        z: Float = -5) -> simd_float4x4 {
        let angle = yawDegrees * Float.pi / 180
        let c = cos(angle)
        let s = sin(angle)
        var result = matrix_identity_float4x4
        result.columns.0 = SIMD4(c, 0, -s, 0)
        result.columns.2 = SIMD4(s, 0, c, 0)
        result.columns.3 = SIMD4(x, 0, z, 1)
        return result
    }

    private func version(_ sequence: UInt64, capturedAt: TimeInterval? = nil,
                         session: UInt64 = 1, anchor: UInt64 = 1) -> VPSPoseVersion {
        VPSPoseVersion(sessionGeneration: session, anchorGeneration: anchor,
                       capturedAt: capturedAt ?? TimeInterval(sequence), sequence: sequence)
    }

    @discardableResult
    private func accept(_ admission: inout VPSCorrectionAdmission, x: Float = 0,
                        yaw: Float = 0, version: VPSPoseVersion,
                        current: VPSCorrectionAdmission.Pose? = nil,
                        first: Bool = false, glideActive: Bool = false,
                        editing: Bool = false)
        -> VPSCorrectionAdmission.Decision {
        admission.accept(
            id: id, transform: matrix(x: x, yawDegrees: yaw),
            pose: pose(x: x, yawDegrees: yaw), version: version,
            current: current ?? pose(), cameraPosition: camera,
            isVisible: true, isFirst: first, glideActive: glideActive,
            isEditing: editing
        )
    }

    func testNewerVisiblePoseReplacesOneMeterDeferredCorrection() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, x: 1, version: version(1)), .deferUntilOffscreen)
        XCTAssertEqual(accept(&admission, x: 0.1, version: version(2)), .deferUntilOffscreen)
        XCTAssertEqual(admission.pendingTransform(for: id)?.columns.3.x, 0.1)

        XCTAssertEqual(admission.reconsider(id: id, current: pose(),
                                          cameraPosition: camera, isVisible: true,
                                          glideActive: false), .deferUntilOffscreen)
        XCTAssertEqual(admission.reconsider(id: id, current: pose(),
                                          cameraPosition: camera, isVisible: false,
                                          glideActive: false), .glide)
        XCTAssertEqual(admission.pendingTransform(for: id)?.columns.3.x, nil)
    }

    func testNewerDeadbandPoseCancelsOldCorrection() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, x: 1, version: version(1)), .deferUntilOffscreen)
        XCTAssertEqual(accept(&admission, x: 0.001, version: version(2)), .ignore)
        XCTAssertFalse(admission.hasPending)
        XCTAssertNil(admission.reconsider(id: id, current: pose(),
                                         cameraPosition: camera, isVisible: false,
                                         glideActive: false))
    }

    func testYawOnlyCorrectionWaitsForOffscreenAndIsNotLostAtZeroTranslation() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, yaw: 30, version: version(1)), .deferUntilOffscreen)
        XCTAssertEqual(admission.reconsider(id: id, current: pose(),
                                          cameraPosition: camera, isVisible: true,
                                          glideActive: false), .deferUntilOffscreen)
        XCTAssertEqual(admission.reconsider(id: id, current: pose(),
                                          cameraPosition: camera, isVisible: false,
                                          glideActive: false), .glide)
        XCTAssertFalse(admission.hasPending)
    }

    func testTinyPositionAndYawCanSnap() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, x: 0.01, yaw: 0.2,
                              version: version(1)), .snap)
        XCTAssertFalse(admission.hasPending)
    }

    func testSamePhysicalShiftUsesViewingAngleAtNearAndFarRange() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, x: 0.025, version: version(1)),
                       .deferUntilOffscreen)
        admission.remove(id)
        let far = VPSCorrectionAdmission.Pose(
            position: SIMD3(0, 0, -20),
            rotation: simd_quatf(angle: 0, axis: [0, 1, 0]))
        let farTarget = VPSCorrectionAdmission.Pose(
            position: SIMD3(0.025, 0, -20), rotation: far.rotation)
        XCTAssertEqual(admission.accept(
            id: id, transform: matrix(x: 0.025, z: -20), pose: farTarget,
            version: version(2), current: far, cameraPosition: camera,
            isVisible: true, isFirst: false, glideActive: false,
            isEditing: false), .snap)
    }

    func testEqualCaptureTimeUsesSequenceToRejectReordering() {
        XCTAssertTrue(version(2, capturedAt: 10).isNewer(than: version(1, capturedAt: 10)))
        XCTAssertFalse(version(1, capturedAt: 10).isNewer(than: version(2, capturedAt: 10)))
    }

    func testUpdateDuringFirstGlideReplacesLatestTargetAndWaitsForGlide() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, x: 1, version: version(1), first: true), .glide)
        XCTAssertEqual(accept(&admission, x: 0.1, version: version(2),
                              current: pose(x: 0.5), glideActive: true), .interruptGlide)
        // The caller responds to .interruptGlide by stopping the holder-level
        // animation at x=0.5; no path to the old x=1 target remains.
        XCTAssertEqual(admission.pendingTransform(for: id)?.columns.3.x, 0.1)
        XCTAssertEqual(admission.reconsider(id: id, current: pose(x: 0.5),
                                          cameraPosition: camera, isVisible: true,
                                          glideActive: false), .deferUntilOffscreen)
        XCTAssertEqual(admission.reconsider(id: id, current: pose(x: 0.5),
                                          cameraPosition: camera, isVisible: false,
                                          glideActive: false), .glide)
    }

    func testReorderedCaptureAndOlderAnchorCannotReplaceLatestPose() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, x: 0.2,
                              version: version(10, capturedAt: 20, anchor: 2)),
                       .deferUntilOffscreen)
        XCTAssertEqual(accept(&admission, x: 1,
                              version: version(11, capturedAt: 19, anchor: 2)), .reject)
        XCTAssertEqual(accept(&admission, x: 2,
                              version: version(12, capturedAt: 30, anchor: 1)), .reject)
        XCTAssertEqual(admission.pendingTransform(for: id)?.columns.3.x, 0.2)
        XCTAssertEqual(accept(&admission, x: 0.3,
                              version: version(1, capturedAt: 1, anchor: 3)),
                       .deferUntilOffscreen)
        XCTAssertEqual(admission.pendingTransform(for: id)?.columns.3.x, 0.3)
    }

    func testRemovalRecreationAndWorldResetRetireQueuedPoses() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, x: 1, version: version(1)), .deferUntilOffscreen)
        admission.remove(id)
        XCTAssertFalse(admission.hasPending)
        let stale = version(2, session: 1, anchor: 1)
        XCTAssertFalse(stale.matches(sessionGeneration: 1, anchorGeneration: 2))
        XCTAssertEqual(accept(&admission, x: 0.2,
                              version: version(3, anchor: 2)), .deferUntilOffscreen)
        admission.resetGeneration()
        XCTAssertFalse(admission.hasPending)
        XCTAssertNil(admission.reconsider(id: id, current: pose(),
                                         cameraPosition: camera, isVisible: false,
                                         glideActive: false))
        XCTAssertFalse(version(4, session: 1, anchor: 2)
            .matches(sessionGeneration: 2, anchorGeneration: 3))
    }

    func testHeldEditKeepsLatestPoseAndRepinReplacesUnresolvedAnchor() {
        var admission = VPSCorrectionAdmission()
        XCTAssertEqual(accept(&admission, x: 1,
                              version: version(1, anchor: 4), first: true), .glide)
        XCTAssertEqual(accept(&admission, x: 2,
                              version: version(2, anchor: 4), editing: true), .holdForEdit)
        XCTAssertEqual(admission.pendingTransform(for: id)?.columns.3.x, 2)

        // A height/rotation commit retires the old request even if its first
        // anchor completion has not yet arrived. The engine checks this epoch.
        admission.remove(id)
        XCTAssertFalse(version(3, anchor: 4)
            .matches(sessionGeneration: 1, anchorGeneration: 5))
        XCTAssertEqual(accept(&admission, x: 0.25,
                              version: version(4, anchor: 5), first: true), .glide)
        XCTAssertEqual(admission.pendingTransform(for: id)?.columns.3.x, 0.25)
    }

    func testNewerCorrectionReplacesPendingPoseAndItsQualityTogether() {
        var admission = VPSCorrectionAdmission()
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let coarse = VPSPoseQuality(
            horizontalAccuracyMeters: 8, yawAccuracyDegrees: 7,
            observedAt: observedAt
        )
        let refined = VPSPoseQuality(
            horizontalAccuracyMeters: 1, yawAccuracyDegrees: 2,
            observedAt: observedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(admission.accept(
            id: id, transform: matrix(x: 1), pose: pose(x: 1),
            version: version(1), quality: coarse, current: pose(),
            cameraPosition: camera, isVisible: true, isFirst: false,
            glideActive: false, isEditing: false, at: observedAt
        ), .deferUntilOffscreen)
        XCTAssertEqual(admission.pendingQuality(for: id), coarse)

        XCTAssertEqual(admission.accept(
            id: id, transform: matrix(x: 0.1), pose: pose(x: 0.1),
            version: version(2), quality: refined, current: pose(),
            cameraPosition: camera, isVisible: true, isFirst: false,
            glideActive: false, isEditing: false,
            at: observedAt.addingTimeInterval(1)
        ), .deferUntilOffscreen)
        XCTAssertEqual(admission.pendingTransform(for: id)?.columns.3.x, 0.1)
        XCTAssertEqual(admission.pendingQuality(for: id), refined)
        XCTAssertEqual(admission.acceptedQuality(for: id), refined)

        XCTAssertEqual(admission.accept(
            id: id, transform: matrix(x: 0.2), pose: pose(x: 0.2),
            version: version(3), quality: refined, current: pose(),
            cameraPosition: camera, isVisible: true, isFirst: false,
            glideActive: false, isEditing: false,
            at: observedAt.addingTimeInterval(4)
        ), .reject)
        XCTAssertEqual(admission.pendingQuality(for: id), refined)

        let malformed = VPSPoseQuality(
            horizontalAccuracyMeters: -1, yawAccuracyDegrees: 2,
            observedAt: observedAt
        )
        XCTAssertEqual(admission.accept(
            id: id, transform: matrix(x: 0.2), pose: pose(x: 0.2),
            version: version(3), quality: malformed, current: pose(),
            cameraPosition: camera, isVisible: true, isFirst: false,
            glideActive: false, isEditing: false,
            at: observedAt.addingTimeInterval(1)
        ), .reject)
        XCTAssertEqual(admission.pendingQuality(for: id), refined)
        admission.remove(id)
        XCTAssertNil(admission.acceptedQuality(for: id))
    }
}
