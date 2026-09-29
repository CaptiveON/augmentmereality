import XCTest
import simd
@testable import AugmentMeReality

final class ARReadinessEpochTests: XCTestCase {
    private let hero = UUID()

    func testCameraHidePreservesSelectionAndExplicitNewIntentReplacesIt() async {
        await MainActor.run {
            let manager = GeoARSessionManager()
            let firstHero = UUID()
            manager.markCameraIntent(heroID: firstHero)
            manager.markCameraHidden()
            XCTAssertEqual(manager.readiness?.heroID, firstHero,
                           "A hidden camera must retain the intended target for warm resume")
            let replacement = UUID()
            manager.markCameraIntent(heroID: replacement)
            XCTAssertEqual(manager.readiness?.heroID, replacement)
            XCTAssertEqual(manager.readiness?.generation, 2)
            XCTAssertNil(manager.readiness?.firstFreshFrameAt)
            XCTAssertNil(manager.readiness?.heroSceneUpdateProxyAt)
        }
    }

    func testRetainedHolderAndStaleFrameCannotSatisfyResume() {
        var epoch = ARReadinessEpoch(kind: .warmResume, generation: 2, startedAt: 10)
        epoch.selectHero(hero)
        epoch.observeContent(id: hero, ready: true, at: 10)
        epoch.observeCamera(capturedAt: 9, observedAt: 10.1, sessionRunAt: 10)
        epoch.observeSceneUpdate(id: hero, contentReady: true, inViewport: true,
                                 freshCamera: true, at: 10.2)
        XCTAssertNil(epoch.firstFreshFrameAt)
        XCTAssertNil(epoch.heroSceneUpdateProxyAt)
        epoch.observeCamera(capturedAt: 10.3, observedAt: 10.4, sessionRunAt: 10)
        epoch.observeSceneUpdate(id: hero, contentReady: true, inViewport: true,
                                 freshCamera: true, at: 10.5)
        XCTAssertEqual(epoch.milliseconds(to: epoch.heroSceneUpdateProxyAt), 500)
    }

    func testDelayedOrMissingAssetNeverCountsPlaceholderAsHero() {
        var epoch = ARReadinessEpoch(kind: .coldStart, generation: 1, startedAt: 1)
        epoch.selectHero(hero)
        epoch.observeCamera(capturedAt: 1.1, observedAt: 1.2, sessionRunAt: 1)
        epoch.observeContent(id: hero, ready: false, at: 1.3)
        epoch.observeSceneUpdate(id: hero, contentReady: false, inViewport: true,
                                 freshCamera: true, at: 2)
        XCTAssertEqual(epoch.milliseconds(to: epoch.placeholderAt), 300)
        XCTAssertNil(epoch.assetReadyAt)
        XCTAssertNil(epoch.heroSceneUpdateProxyAt)
        epoch.observeContent(id: hero, ready: true, at: 4)
        epoch.observeSceneUpdate(id: hero, contentReady: true, inViewport: true,
                                 freshCamera: true, at: 4)
        XCTAssertNil(epoch.heroSceneUpdateProxyAt, "Requires a later scene update")
        epoch.observeSceneUpdate(id: hero, contentReady: true, inViewport: true,
                                 freshCamera: true, at: 4.1)
        XCTAssertEqual(epoch.milliseconds(to: epoch.heroSceneUpdateProxyAt), 3100)
    }

    func testAnotherReadyDropCannotReplaceTheSelectedMissingHero() {
        var epoch = ARReadinessEpoch(kind: .coldStart, generation: 1, startedAt: 0)
        let other = UUID()
        epoch.selectHero(hero)
        epoch.selectHero(other)
        epoch.observeContent(id: other, ready: true, at: 1)
        epoch.observeCamera(capturedAt: 1, observedAt: 1, sessionRunAt: 0)
        epoch.observeSceneUpdate(id: other, contentReady: true, inViewport: true,
                                 freshCamera: true, at: 2)
        XCTAssertEqual(epoch.heroID, hero)
        XCTAssertNil(epoch.assetReadyAt)
        XCTAssertNil(epoch.heroSceneUpdateProxyAt)
    }

    func testRecoveryIsIndependentAndOffscreenOrFrozenContentIsNotReady() {
        var epoch = ARReadinessEpoch(kind: .recovery, generation: 3, startedAt: 20)
        epoch.selectHero(hero)
        epoch.observeContent(id: hero, ready: true, at: 20.1)
        epoch.observeCamera(capturedAt: 20.2, observedAt: 20.3, sessionRunAt: 20)
        epoch.observeSceneUpdate(id: hero, contentReady: true, inViewport: false,
                                 freshCamera: true, at: 21)
        epoch.observeSceneUpdate(id: hero, contentReady: true, inViewport: true,
                                 freshCamera: false, at: 22)
        XCTAssertNil(epoch.heroSceneUpdateProxyAt)
        XCTAssertEqual(epoch.kind, .recovery)
        XCTAssertEqual(epoch.generation, 3)
    }

    func testRoomDropRecoveryWaitsForFreshNormalFrame() {
        XCTAssertFalse(GeoARSessionManager.canRestoreRoomDrops(
            frameCapturedAt: 100, sessionRunAt: 100, trackingNormal: true))
        XCTAssertFalse(GeoARSessionManager.canRestoreRoomDrops(
            frameCapturedAt: 101, sessionRunAt: 100, trackingNormal: false))
        XCTAssertFalse(GeoARSessionManager.canRestoreRoomDrops(
            frameCapturedAt: .nan, sessionRunAt: 100, trackingNormal: true))
        XCTAssertTrue(GeoARSessionManager.canRestoreRoomDrops(
            frameCapturedAt: 100.1, sessionRunAt: 100, trackingNormal: true))
    }

    func testRoomDropRecoveryReanchorsFromOldToNewCameraFrame() {
        var oldCamera = matrix_identity_float4x4
        oldCamera.columns.3 = SIMD4<Float>(10, 1, 0, 1)
        var oldHolder = matrix_identity_float4x4
        oldHolder.columns.3 = SIMD4<Float>(11, 0.5, -2, 1)
        let relative = GeoARSessionManager.roomCameraRelativeTransform(
            camera: oldCamera, holder: oldHolder)

        var newCamera = matrix_identity_float4x4
        newCamera.columns.3 = SIMD4<Float>(100, 3, 50, 1)
        let restored = GeoARSessionManager.reanchoredRoomTransform(
            camera: newCamera, relativeHolder: relative)
        XCTAssertEqual(restored.columns.3.x, 101, accuracy: 0.0001)
        XCTAssertEqual(restored.columns.3.y, 2.5, accuracy: 0.0001)
        XCTAssertEqual(restored.columns.3.z, 48, accuracy: 0.0001)
        XCTAssertEqual(restored.columns.0.x, oldHolder.columns.0.x, accuracy: 0.0001)
    }
}
