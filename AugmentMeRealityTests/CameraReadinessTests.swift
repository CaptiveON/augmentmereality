import XCTest
@testable import AugmentMeReality

final class CameraReadinessTests: XCTestCase {
    private func heroUpdate(
        observedAt: TimeInterval, capturedAt: TimeInterval? = nil,
        trackingNormal: Bool = true, holderEnabled: Bool = true,
        fullContent: Bool = true, contentActive: Bool = true,
        assetReady: Bool = true,
        inViewport: Bool = true, sessionRunAt: TimeInterval
    ) -> CameraReadiness.HeroSceneEvidence {
        CameraReadiness.HeroSceneEvidence(
            capturedAt: capturedAt ?? observedAt - 0.05,
            observedAt: observedAt, sessionRunAt: sessionRunAt,
            trackingNormal: trackingNormal, holderEnabled: holderEnabled,
            fullContent: fullContent, contentActive: contentActive,
            assetReady: assetReady,
            inViewport: inViewport
        )
    }

    func testOrdinaryCameraCanDiscoverWithoutInventingAHero() {
        var readiness = CameraReadiness(timeoutSeconds: 1.6)
        readiness.begin(generation: 1, kind: .coldStart, at: 100)
        XCTAssertEqual(readiness.snapshot.phase, .opening)
        XCTAssertEqual(readiness.snapshot.waitingFor, .camera)
        XCTAssertFalse(readiness.snapshot.showsLiveViewfinder)

        // The retained frame from before this run cannot open the viewfinder.
        readiness.observeCamera(generation: 1, capturedAt: 99.9,
                                observedAt: 100.1, sessionRunAt: 100)
        XCTAssertEqual(readiness.snapshot.phase, .opening)
        readiness.observeCamera(generation: 1, capturedAt: 100.2,
                                observedAt: 100.23, sessionRunAt: 100)
        XCTAssertEqual(readiness.snapshot.phase, .discovering)
        XCTAssertEqual(readiness.snapshot.waitingFor, .selection)
        XCTAssertTrue(readiness.snapshot.showsLiveViewfinder)
        XCTAssertEqual(readiness.snapshot.suggestedAction, .scanSurroundings)

        // A deadline with no intended drop stays discovery, not hero success.
        readiness.expireDeadline(generation: 1, at: 102)
        XCTAssertEqual(readiness.snapshot.phase, .discovering)
        XCTAssertNil(readiness.snapshot.firstHeroSceneUpdateProxyAt)
    }

    func testDelayedAssetTimeoutShowsGuidanceThenRealHeroUpdateRecovers() {
        let hero = UUID()
        var readiness = CameraReadiness(timeoutSeconds: 1.6)
        readiness.begin(generation: 1, kind: .coldStart, heroID: hero, at: 1)
        let token = try! XCTUnwrap(readiness.snapshot.selection)
        readiness.observeCamera(generation: 1, capturedAt: 1.1,
                                observedAt: 1.11, sessionRunAt: 1)
        readiness.observeTracking(.normal, generation: 1, at: 1.12)
        readiness.observeAsset(.loading, for: token, at: 1.2)
        readiness.observeHeroSceneUpdate(
            for: token,
            evidence: heroUpdate(observedAt: 1.3, assetReady: false,
                                 sessionRunAt: 1)
        )
        XCTAssertEqual(readiness.snapshot.phase, .loading)
        XCTAssertNil(readiness.snapshot.firstHeroSceneUpdateProxyAt)

        readiness.expireDeadline(generation: 1, at: 2.6)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.assetDelayed))
        XCTAssertEqual(readiness.snapshot.suggestedAction, .wait)
        XCTAssertTrue(readiness.snapshot.showsLiveViewfinder)
        XCTAssertNil(readiness.snapshot.firstHeroSceneUpdateProxyAt)

        readiness.observeAsset(.ready, for: token, at: 3)
        readiness.observeHeroSceneUpdate(
            for: token, evidence: heroUpdate(observedAt: 3.1, sessionRunAt: 1)
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)
        XCTAssertEqual(readiness.snapshot.firstHeroSceneUpdateProxyAt, 3.1)
        XCTAssertNil(readiness.snapshot.deadlineAt)
    }

    func testSelectionChangeRejectsLateAssetAndFailedAssetIsExplicit() {
        let first = UUID()
        let second = UUID()
        var readiness = CameraReadiness(timeoutSeconds: 1)
        readiness.begin(generation: 7, kind: .coldStart, heroID: first, at: 10)
        let firstToken = try! XCTUnwrap(readiness.snapshot.selection)
        readiness.observeCamera(generation: 7, capturedAt: 10.1,
                                observedAt: 10.12, sessionRunAt: 10)
        readiness.observeTracking(.normal, generation: 7, at: 10.13)
        let secondToken = try! XCTUnwrap(
            readiness.selectHero(second, generation: 7, at: 10.2)
        )
        XCTAssertNotEqual(firstToken, secondToken)
        readiness.observeAsset(.ready, for: firstToken, at: 10.3)
        readiness.observeHeroSceneUpdate(
            for: firstToken, evidence: heroUpdate(observedAt: 10.4, sessionRunAt: 10)
        )
        XCTAssertEqual(readiness.snapshot.asset, .unrequested)
        XCTAssertNil(readiness.snapshot.firstHeroSceneUpdateProxyAt)

        readiness.observeAsset(.failed, for: secondToken, at: 10.5)
        XCTAssertEqual(readiness.snapshot.phase, .failed(.selectedAssetFailed))
        XCTAssertEqual(readiness.snapshot.suggestedAction, .retry)
        XCTAssertNil(readiness.snapshot.deadlineAt)
        readiness.expireDeadline(generation: 7, at: 20)
        XCTAssertFalse(readiness.snapshot.timedOut)

        let thirdToken = try! XCTUnwrap(
            readiness.selectHero(first, generation: 7, at: 20.1)
        )
        readiness.observeAsset(.ready, for: secondToken, at: 20.2)
        XCTAssertEqual(readiness.snapshot.asset, .unrequested)
        readiness.observeAsset(.ready, for: thirdToken, at: 20.3)
        readiness.observeHeroSceneUpdate(
            for: thirdToken, evidence: heroUpdate(observedAt: 20.4, sessionRunAt: 10)
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)
    }

    func testHeroProxyNeedsFreshNormalFullEnabledInViewportSceneEvidence() {
        var readiness = CameraReadiness(timeoutSeconds: 3)
        let hero = UUID()
        readiness.begin(generation: 2, kind: .coldStart, heroID: hero, at: 50)
        let token = try! XCTUnwrap(readiness.snapshot.selection)
        readiness.observeCamera(generation: 2, capturedAt: 50.1,
                                observedAt: 50.12, sessionRunAt: 50)
        readiness.observeTracking(.normal, generation: 2, at: 50.13)
        readiness.observeAsset(.ready, for: token, at: 50.14)

        // Each of these represents a real failure mode: frozen capture,
        // limited tracking, disabled transit holder, budget cue, placeholder,
        // or a selected object outside the viewfinder.
        let rejected: [CameraReadiness.HeroSceneEvidence] = [
            heroUpdate(observedAt: 50.5, capturedAt: 50.1, sessionRunAt: 50),
            heroUpdate(observedAt: 50.6, trackingNormal: false, sessionRunAt: 50),
            heroUpdate(observedAt: 50.7, holderEnabled: false, sessionRunAt: 50),
            heroUpdate(observedAt: 50.8, fullContent: false, sessionRunAt: 50),
            heroUpdate(observedAt: 50.9, contentActive: false, sessionRunAt: 50),
            heroUpdate(observedAt: 51.0, assetReady: false, sessionRunAt: 50),
            heroUpdate(observedAt: 51.1, inViewport: false, sessionRunAt: 50)
        ]
        for evidence in rejected {
            readiness.observeHeroSceneUpdate(for: token, evidence: evidence)
            XCTAssertEqual(readiness.snapshot.phase, .loading)
            XCTAssertNil(readiness.snapshot.firstHeroSceneUpdateProxyAt)
        }

        readiness.observeHeroSceneUpdate(
            for: token, evidence: heroUpdate(observedAt: 51.2, sessionRunAt: 50)
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)
        XCTAssertEqual(readiness.snapshot.firstHeroSceneUpdateProxyAt, 51.2)

        // The first proxy remains measurable; current readiness is revoked
        // until a normally tracked scene update qualifies again.
        readiness.observeTracking(.limited, generation: 2, at: 51.3)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.trackingLimited))
        readiness.observeTracking(.normal, generation: 2, at: 51.4)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.heroNotVisible))
        readiness.observeHeroSceneUpdate(
            for: token, evidence: heroUpdate(observedAt: 51.5, sessionRunAt: 50)
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)
        XCTAssertEqual(readiness.snapshot.firstHeroSceneUpdateProxyAt, 51.2)

        // A transit holder suppressed by stale GPS cannot keep claiming that
        // the selected hero is currently ready just because it appeared once.
        readiness.observeHeroSceneUpdate(
            for: token,
            evidence: heroUpdate(observedAt: 51.6, holderEnabled: false,
                                 sessionRunAt: 50)
        )
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.heroNotVisible))
        XCTAssertEqual(readiness.snapshot.firstHeroSceneUpdateProxyAt, 51.2)
    }

    func testTrackingProblemOutranksDiscoveryWithoutASelectedHero() {
        var readiness = CameraReadiness(timeoutSeconds: 1)
        readiness.begin(generation: 3, kind: .coldStart, at: 30)
        readiness.observeCamera(generation: 3, capturedAt: 30.1,
                                observedAt: 30.12, sessionRunAt: 30)
        readiness.observeTracking(.limited, generation: 3, at: 30.13)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.trackingLimited))
        XCTAssertEqual(readiness.snapshot.waitingFor, .tracking)

        readiness.expireDeadline(generation: 3, at: 31)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.trackingLimited))
        readiness.observeTracking(.normal, generation: 3, at: 31.1)
        XCTAssertEqual(readiness.snapshot.phase, .discovering)
        readiness.observeTracking(.unavailable, generation: 3, at: 31.2)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.trackingLimited))
    }

    func testCaptureLivenessRevokesCurrentReadinessButPreservesFirstProof() {
        var readiness = CameraReadiness(timeoutSeconds: 2)
        let hero = UUID()
        readiness.begin(generation: 4, kind: .coldStart, heroID: hero, at: 40)
        let token = try! XCTUnwrap(readiness.snapshot.selection)
        readiness.observeCamera(generation: 4, capturedAt: 40.1,
                                observedAt: 40.12, sessionRunAt: 40)
        readiness.observeTracking(.normal, generation: 4, at: 40.13)
        readiness.observeAsset(.ready, for: token, at: 40.14)
        readiness.observeHeroSceneUpdate(
            for: token, evidence: heroUpdate(observedAt: 40.2, sessionRunAt: 40)
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)

        readiness.revokeStaleCamera(
            generation: 4, latestCapturedAt: 40.3, lastSceneUpdateAt: 40.2,
            observedAt: 40.32, sessionRunAt: 40
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)
        readiness.revokeStaleCamera(
            generation: 4, latestCapturedAt: 40.3, lastSceneUpdateAt: 40.2,
            observedAt: 40.7, sessionRunAt: 40
        )
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.cameraUnavailable))
        XCTAssertFalse(readiness.snapshot.cameraLive)
        XCTAssertEqual(readiness.snapshot.waitingFor, .camera)
        XCTAssertEqual(readiness.snapshot.firstFreshCameraAt, 40.12)
        XCTAssertEqual(readiness.snapshot.firstHeroSceneUpdateProxyAt, 40.2)

        readiness.revokeStaleCamera(
            generation: 3, latestCapturedAt: nil, lastSceneUpdateAt: nil,
            observedAt: 40.8, sessionRunAt: 40
        )
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.cameraUnavailable))
        readiness.observeCamera(generation: 4, capturedAt: 40.8,
                                observedAt: 40.82, sessionRunAt: 40)
        XCTAssertTrue(readiness.snapshot.cameraLive)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.heroNotVisible))
        readiness.observeHeroSceneUpdate(
            for: token, evidence: heroUpdate(observedAt: 40.9, sessionRunAt: 40)
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)
        XCTAssertEqual(readiness.snapshot.firstHeroSceneUpdateProxyAt, 40.2)
    }

    func testSceneUpdateStallRevokesReadyWhileCaptureRemainsFresh() {
        var readiness = CameraReadiness(timeoutSeconds: 2)
        let hero = UUID()
        readiness.begin(generation: 5, kind: .coldStart, heroID: hero, at: 50)
        let token = try! XCTUnwrap(readiness.snapshot.selection)
        readiness.observeCamera(generation: 5, capturedAt: 50.1,
                                observedAt: 50.12, sessionRunAt: 50)
        readiness.observeTracking(.normal, generation: 5, at: 50.13)
        readiness.observeAsset(.ready, for: token, at: 50.14)
        readiness.observeHeroSceneUpdate(
            for: token, evidence: heroUpdate(observedAt: 50.2, sessionRunAt: 50)
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)

        readiness.revokeStaleCamera(
            generation: 5, latestCapturedAt: 51.25, lastSceneUpdateAt: 50.2,
            observedAt: 51.3, sessionRunAt: 50
        )
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.viewfinderStalled))
        XCTAssertEqual(readiness.snapshot.suggestedAction, .retry)
        XCTAssertTrue(readiness.snapshot.cameraLive)
        XCTAssertEqual(readiness.snapshot.firstHeroSceneUpdateProxyAt, 50.2)

        readiness.observeCamera(generation: 5, capturedAt: 51.35,
                                observedAt: 51.37, sessionRunAt: 50)
        readiness.observeHeroSceneUpdate(
            for: token, evidence: heroUpdate(observedAt: 51.4, sessionRunAt: 50)
        )
        XCTAssertEqual(readiness.snapshot.phase, .ready)
        XCTAssertEqual(readiness.snapshot.firstHeroSceneUpdateProxyAt, 50.2)
    }

    func testRecoveryAndHideRejectOldEpochEventsAndCancelDeadline() {
        let hero = UUID()
        var readiness = CameraReadiness(timeoutSeconds: 1.6)
        readiness.begin(generation: 1, kind: .coldStart, heroID: hero, at: 1)
        let oldToken = try! XCTUnwrap(readiness.snapshot.selection)
        readiness.begin(generation: 2, kind: .recovery, heroID: hero, at: 10)
        let recoveryToken = try! XCTUnwrap(readiness.snapshot.selection)
        XCTAssertEqual(readiness.snapshot.phase, .recovering)
        XCTAssertNotEqual(oldToken, recoveryToken)
        readiness.observeCamera(generation: 1, capturedAt: 10.1,
                                observedAt: 10.12, sessionRunAt: 10)
        readiness.observeAsset(.ready, for: oldToken, at: 10.2)
        readiness.expireDeadline(generation: 1, at: 100)
        XCTAssertNil(readiness.snapshot.firstFreshCameraAt)
        XCTAssertEqual(readiness.snapshot.asset, .unrequested)
        XCTAssertFalse(readiness.snapshot.timedOut)

        readiness.observeCamera(generation: 2, capturedAt: 10.3,
                                observedAt: 10.32, sessionRunAt: 10)
        readiness.observeTracking(.limited, generation: 2, at: 10.33)
        readiness.observeAsset(.ready, for: recoveryToken, at: 10.4)
        readiness.expireDeadline(generation: 2, at: 11.6)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.trackingLimited))
        XCTAssertTrue(readiness.snapshot.showsLiveViewfinder)

        readiness.hide(generation: 2)
        XCTAssertEqual(readiness.snapshot.phase, .hidden)
        XCTAssertNil(readiness.snapshot.deadlineAt)
        readiness.observeHeroSceneUpdate(
            for: recoveryToken,
            evidence: heroUpdate(observedAt: 12, sessionRunAt: 10)
        )
        XCTAssertNil(readiness.snapshot.firstHeroSceneUpdateProxyAt)

        readiness.begin(generation: 3, kind: .warmResume, heroID: hero, at: 20)
        XCTAssertEqual(readiness.snapshot.phase, .recovering)
        readiness.expireDeadline(generation: 2, at: 22)
        XCTAssertFalse(readiness.snapshot.timedOut)
        readiness.expireDeadline(generation: 3, at: 21.6)
        XCTAssertEqual(readiness.snapshot.phase, .degraded(.cameraUnavailable))
        XCTAssertTrue(readiness.snapshot.showsLiveViewfinder)
        readiness.failSession(.cameraPermissionDenied, generation: 3)
        XCTAssertEqual(readiness.snapshot.phase, .failed(.cameraPermissionDenied))
        XCTAssertEqual(readiness.snapshot.suggestedAction, .openSettings)
    }
}
