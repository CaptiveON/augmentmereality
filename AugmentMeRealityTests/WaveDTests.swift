import CoreVideo
import RealityKit
import XCTest
@testable import AugmentMeReality

/// Wave D (counsel ARP-6): the capture-format policy, table-driven. Both
/// bounds are load-bearing: the floor-only filter re-selected the 4K@30 heat
/// bug ADR-034 exists to kill, and the exact-fps filter silently left ARKit's
/// 60 fps default standing.
final class VideoFormatPolicyTests: XCTestCase {
    func testPicksSmallestAdequateFormatAtTargetFPS() {
        let formats = [
            (fps: 60, width: 1920, height: 1440),
            (fps: 30, width: 1920, height: 1440),
            (fps: 30, width: 1920, height: 1080),
            (fps: 30, width: 3840, height: 2160),
        ]
        XCTAssertEqual(GeoARSessionManager.pickVideoFormat(from: formats), 2)
    }

    func testNeverSelects4KEvenWhenItIsTheOnly30FPSFormat() {
        // The ADR-034 regression device: its only 30 fps entry is 4K.
        let formats = [
            (fps: 60, width: 1920, height: 1440),
            (fps: 30, width: 3840, height: 2160),
        ]
        XCTAssertNil(
            GeoARSessionManager.pickVideoFormat(from: formats),
            "4K@30 is the heat bug — the policy must refuse it loudly, not select it"
        )
    }

    func testAcceptsLowerFPSWhenNoExactTargetExists() {
        // fps ≤ target — the old exact-equality filter fell through to 60 fps.
        let formats = [
            (fps: 60, width: 1920, height: 1440),
            (fps: 24, width: 1920, height: 1080),
        ]
        XCTAssertEqual(GeoARSessionManager.pickVideoFormat(from: formats), 1)
    }

    func testPrefersHighestFPSAtOrBelowTargetThenSmallestArea() {
        let formats = [
            (fps: 24, width: 1280, height: 720),
            (fps: 30, width: 1920, height: 1440),
            (fps: 30, width: 1280, height: 720),
        ]
        XCTAssertEqual(GeoARSessionManager.pickVideoFormat(from: formats), 2)
    }

    func testRejectsBelow720p() {
        let formats = [(fps: 30, width: 640, height: 480)]
        XCTAssertNil(GeoARSessionManager.pickVideoFormat(from: formats))
    }
}

/// Capability and render-mode cases exercise the shared perception policy.
final class PerceptionPlanTests: XCTestCase {
    private func plan(
        tierAboveIdle: Bool = true,
        fullTier: Bool = true,
        cameraVisible: Bool = true,
        cameraRecentlyVisible: Bool? = nil,
        pedestrian: Bool = true,
        windowModeActive: Bool = false,
        personLikely: Bool = true,
        contentInViewRecently: Bool = true,
        midFieldServiceable: Bool = true,
        thermalSerious: Bool = false,
        thermalCritical: Bool = false,
        supportsCustomPersonOcclusion: Bool = true,
        supportsSceneReconstruction: Bool = true,
        supportsSceneDepth: Bool = true,
        midFieldEnabled: Bool = true
    ) -> PerceptionPolicy.Plan {
        var demand = PerceptionDemand()
        demand.cameraVisible = cameraVisible
        demand.sessionRunning = true
        demand.cameraRecentlyVisible = cameraRecentlyVisible ?? cameraVisible
        demand.content = [.init(
            distance: fullTier && midFieldServiceable ? 4.5 : 80,
            isInView: contentInViewRecently && tierAboveIdle
        )]
        demand.pedestrian = pedestrian
        demand.windowModeActive = windowModeActive
        demand.personLikely = personLikely
        demand.thermalSerious = thermalSerious
        demand.thermalCritical = thermalCritical
        demand.supportsPersonSegmentation = true
        demand.supportsCustomPersonOcclusion = supportsCustomPersonOcclusion
        demand.supportsSceneReconstruction = supportsSceneReconstruction
        demand.supportsSceneDepth = supportsSceneDepth
        demand.hasSemanticPass = true
        demand.midFieldEnabled = midFieldEnabled
        var policy = PerceptionPolicy()
        if !cameraVisible && demand.cameraRecentlyVisible {
            // Grace retains an existing mesh; it must never start hidden work.
            demand.cameraVisible = true
            policy.update(demand)
            demand.cameraVisible = false
        }
        return policy.update(demand)
    }

    func testTransitShedsReconstructionAndMidFieldDepth() {
        // ARP-8: LiDAR meshing through vehicle glass had NO consumer — the
        // request must die with the use.
        let result = plan(pedestrian: false, personLikely: false)
        XCTAssertFalse(result.reconstruction, "no meshing at vehicle speed")
        XCTAssertFalse(result.depth, "mid-field depth requires the pedestrian path")
    }

    func testTransitKeepsPersonSegmentationWhenSomeoneIsPresent() {
        // Transit occlusion is carried by semantic matte + person-seg.
        let result = plan(pedestrian: false)
        XCTAssertTrue(result.person)
        XCTAssertTrue(result.depth, "the custom person path needs its depth test")
    }

    func testThermalCriticalShedsAllPerceptionImmediately() {
        let result = plan(thermalCritical: true)
        XCTAssertFalse(result.reconstruction)
        XCTAssertFalse(result.person)
        XCTAssertFalse(result.depth)
        XCTAssertFalse(result.semantics)
        XCTAssertFalse(result.midField)
    }

    func testReconstructionIsStableAcrossTierAndPresenceCycles() {
        // SWE-11: the person walking out of frame must not discard the mesh.
        let present = plan(personLikely: true)
        let absent = plan(fullTier: false, personLikely: false)
        XCTAssertTrue(present.reconstruction)
        XCTAssertTrue(absent.reconstruction, "reconstruction never keys on presence or tier")
        XCTAssertFalse(absent.person)
    }

    func testWindowModeShedsPersonAndDepth() {
        let result = plan(windowModeActive: true)
        XCTAssertFalse(result.person)
        XCTAssertFalse(result.depth)
        XCTAssertTrue(result.reconstruction)
    }

    func testDepthNotRequestedForPersonWithoutCustomPath() {
        // Non-LiDAR: personSegmentationWithDepth handles its own depth — a
        // separate .sceneDepth request would be pure waste.
        let result = plan(midFieldServiceable: false, supportsCustomPersonOcclusion: false)
        XCTAssertTrue(result.person)
        XCTAssertFalse(result.depth)
    }

    func testCameraHiddenShedsEverythingStateful() {
        let result = plan(tierAboveIdle: false, cameraVisible: false, personLikely: false)
        XCTAssertFalse(result.reconstruction)
        XCTAssertFalse(result.person)
        XCTAssertFalse(result.depth)
    }

    // MARK: - Round 2 (counsel ARPCFG-1/4/7, FLOW-8)

    func testCapabilityGatesEveryStream() {
        // ARPCFG-7/FLOW-8: appliedPerception must never record a request the
        // hardware can't deliver — the LiDAR chip lit on non-LiDAR phones.
        let noMesh = plan(supportsSceneReconstruction: false)
        XCTAssertFalse(noMesh.reconstruction)
        let noDepth = plan(supportsSceneDepth: false)
        XCTAssertFalse(noDepth.depth, "no .sceneDepth request on hardware without it")
        XCTAssertTrue(noDepth.person, "person segmentation is independent of depth capability")
    }

    func testThermalSeriousShedsMidFieldDepthButKeepsPersonDepth() {
        // ARPCFG-1: the mid-field consumer sheds itself at .serious — the
        // REQUEST must shed on the same predicate; person occlusion
        // correctness survives.
        let result = plan(thermalSerious: true)
        XCTAssertTrue(result.depth, "the person depth-test survives .serious")
        let noPerson = plan(personLikely: false, thermalSerious: true)
        XCTAssertFalse(
            noPerson.depth,
            "with no person, .serious leaves the mid-field leg as the only claimant — and it shed"
        )
    }

    func testMidFieldDepthRequiresTheServiceableBand() {
        // ARPCFG-1: content merely "beyond 4 m" is NOT a depth consumer — the
        // serviceable band is 4–5 m; a drop at 60 m must not run the 60 Hz
        // depth ML with zero consumer.
        let result = plan(personLikely: false, midFieldServiceable: false)
        XCTAssertFalse(result.depth)
    }

    func testBriefTabFlipKeepsReconstruction() {
        // ARPCFG-4: within the pause grace, the mesh survives — a sub-5 s tab
        // flip must not destroy and rebuild it; per-frame ML still sheds.
        let result = plan(
            cameraVisible: false, cameraRecentlyVisible: true, personLikely: false
        )
        XCTAssertTrue(result.reconstruction, "the grace window keeps the stateful stream")
        XCTAssertFalse(result.person)
        XCTAssertFalse(result.depth)
    }

    func testMidFieldServiceableBandBounds() {
        XCTAssertFalse(GeoARSessionManager.midFieldServiceable(distance: 3.0))
        XCTAssertTrue(GeoARSessionManager.midFieldServiceable(distance: 4.5))
        XCTAssertFalse(
            GeoARSessionManager.midFieldServiceable(distance: 60),
            "far content was the unbounded-request hole"
        )
    }

    func testOcclusionOptionDerivation() {
        // ARPCFG-3/STATE-2: the option is a pure predicate — window-mode exit
        // interleavings can no longer strand it removed.
        XCTAssertTrue(GeoARSessionManager.occlusionOptionDesired(
            capable: true, pedestrian: true, windowModeActive: false
        ))
        XCTAssertFalse(GeoARSessionManager.occlusionOptionDesired(
            capable: true, pedestrian: true, windowModeActive: true
        ))
        XCTAssertFalse(GeoARSessionManager.occlusionOptionDesired(
            capable: true, pedestrian: false, windowModeActive: false
        ))
        XCTAssertFalse(GeoARSessionManager.occlusionOptionDesired(
            capable: false, pedestrian: true, windowModeActive: false
        ))
    }
}

/// Wave D (counsel SWE-7): every presentation transition is ONE destination
/// change — the racing dismiss+present pairs dropped covers.
@MainActor
final class AppRouterDestinationTests: XCTestCase {
    func testFireworksHandoffIsOneDestinationChange() {
        let router = AppRouter()
        router.onboardingPhase = .story
        router.destination = .onboardingStory
        router.beginFireworksDemo()
        XCTAssertEqual(router.destination, .camera)
        XCTAssertEqual(router.onboardingPhase, .fireworksDemo)
    }

    func testEndingDemoReturnsToStoryInOneChange() {
        let router = AppRouter()
        router.onboardingPhase = .fireworksDemo
        router.destination = .camera
        router.endFireworksDemo()
        XCTAssertEqual(router.destination, .onboardingStory)
        XCTAssertEqual(router.onboardingPhase, .story)
    }

    func testShowCameraFalseDuringDemoReturnsToStory() {
        let router = AppRouter()
        router.onboardingPhase = .fireworksDemo
        router.destination = .camera
        router.showCamera = false
        XCTAssertEqual(router.destination, .onboardingStory)
        XCTAssertEqual(router.onboardingPhase, .story)
    }

    func testCompatAccessorsDriveTheSingleDestination() {
        let router = AppRouter()
        router.showCamera = true
        XCTAssertEqual(router.destination, .camera)
        XCTAssertTrue(router.showCamera)
        XCTAssertFalse(router.showCreate)
        router.beginCreate()
        XCTAssertEqual(router.destination, .create, "create replaces camera in one change")
        router.showCreate = false
        XCTAssertNil(router.destination)
    }

    func testFinishOnboardingClearsOnlyTheStoryDestination() {
        let router = AppRouter()
        router.onboardingPhase = .story
        router.destination = .onboardingStory
        router.finishOnboarding()
        XCTAssertNil(router.destination)
        router.destination = .camera
        router.finishOnboarding()
        XCTAssertEqual(router.destination, .camera, "never tears down an unrelated cover")
    }
}

/// Wave D (counsel ARP-12): the copy-out helper produces an app-owned,
/// content-identical, INDEPENDENT buffer.
final class PixelBufferCopyTests: XCTestCase {
    func testCopyIsContentIdenticalAndIndependent() throws {
        var sourceOut: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_DepthFloat32, nil, &sourceOut)
        let source = try XCTUnwrap(sourceOut)
        CVPixelBufferLockBaseAddress(source, [])
        let base = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: Float32.self)
        let stride = CVPixelBufferGetBytesPerRow(source) / MemoryLayout<Float32>.size
        for row in 0..<4 {
            for column in 0..<8 {
                base[row * stride + column] = Float32(row * 10 + column)
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        let copy = try XCTUnwrap(MidFieldDepthEstimator.copyPixelBuffer(source))
        // Mutate the SOURCE after copying — the copy must not see it.
        CVPixelBufferLockBaseAddress(source, [])
        CVPixelBufferGetBaseAddress(source)!
            .assumingMemoryBound(to: Float32.self)[0] = 999
        CVPixelBufferUnlockBaseAddress(source, [])

        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
        let copyBase = CVPixelBufferGetBaseAddress(copy)!.assumingMemoryBound(to: Float32.self)
        let copyStride = CVPixelBufferGetBytesPerRow(copy) / MemoryLayout<Float32>.size
        XCTAssertEqual(copyBase[0], 0, "the copy is independent of later source writes")
        XCTAssertEqual(copyBase[2 * copyStride + 5], 25, "content survives the copy")
        XCTAssertEqual(CVPixelBufferGetWidth(copy), 8)
        XCTAssertEqual(CVPixelBufferGetHeight(copy), 4)
    }
}

/// Round 2 (counsel FLOW-1/FLOW-3/STATE-7): the beat and the deep-link
/// machine live on the router — table-tested as state machines.
@MainActor
final class AppRouterRound2Tests: XCTestCase {
    func testBeatSurvivesTheFireworksRoundTrip() {
        // FLOW-1: the single-cover model tears the story view down on the
        // hand-off — router-held state is what makes beat 3 reachable.
        let router = AppRouter()
        router.startOnboardingIfNeeded() // fresh install path sets beat 0
        router.onboardingBeat = 1
        router.beginFireworksDemo()
        XCTAssertEqual(router.onboardingBeat, 2, "the hand-off advances the beat")
        router.endFireworksDemo()
        XCTAssertEqual(router.onboardingBeat, 2, "the return lands on the NAME beat")
        XCTAssertEqual(router.destination, .onboardingStory)
    }

    func testLinkArrivedPresentsOnlyOnAClearStage() {
        let router = AppRouter()
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(router.linkArrived(a, receiveUp: false), a, "clear stage presents now")
        router.destination = .camera
        XCTAssertNil(router.linkArrived(b, receiveUp: false), "covered stage queues")
        XCTAssertEqual(router.pendingReceiveDropID, b)
        XCTAssertNil(router.linkArrived(c, receiveUp: false), "single slot — newest wins")
        XCTAssertEqual(router.pendingReceiveDropID, c)
        XCTAssertNil(router.linkArrived(a, receiveUp: true), "an up receive sheet also queues")
    }

    func testPromotionRequiresAFullyClearStage() {
        let router = AppRouter()
        let id = UUID()
        router.pendingReceiveDropID = id
        router.destination = .camera
        XCTAssertNil(router.promotePendingReceive(receiveUp: false), "covered: no promotion")
        router.destination = nil
        XCTAssertNil(router.promotePendingReceive(receiveUp: true), "sheet up: no promotion")
        XCTAssertEqual(router.promotePendingReceive(receiveUp: false), id)
        XCTAssertNil(router.pendingReceiveDropID, "promotion consumes the slot")
        XCTAssertNil(router.promotePendingReceive(receiveUp: false), "empty slot promotes nothing")
    }
}

/// Round 2 (counsel RENDER-8): the PLANAR copy branch — the one production
/// actually takes for 4:2:0 camera frames — with a deliberate stride mismatch.
final class PlanarPixelBufferCopyTests: XCTestCase {
    func testBiplanarCopyWithOverAlignedStride() throws {
        var sourceOut: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferBytesPerRowAlignmentKey: 256,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(
            nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary, &sourceOut
        )
        let source = try XCTUnwrap(sourceOut)
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            let base = CVPixelBufferGetBaseAddressOfPlane(source, plane)!
                .assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let rowBytes = CVPixelBufferGetWidthOfPlane(source, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<rows {
                for column in 0..<rowBytes {
                    base[row * stride + column] = UInt8((plane * 31 + row * 7 + column) % 251)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        let copy = try XCTUnwrap(MidFieldDepthEstimator.copyPixelBuffer(source))
        XCTAssertEqual(CVPixelBufferGetPlaneCount(copy), 2)
        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
        var mismatches = 0
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(copy, plane)!
                .assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            let rows = CVPixelBufferGetHeightOfPlane(copy, plane)
            let rowBytes = CVPixelBufferGetWidthOfPlane(copy, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<rows {
                for column in 0..<rowBytes
                where base[row * stride + column] != UInt8((plane * 31 + row * 7 + column) % 251) {
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "every byte of both planes survives a stride-mismatched copy")
    }
}

/// Round 3 (the counsel's CALLER-CLOCK rule): every round-2 escape was a
/// clock/timer/predicate coupling whose test handed the quantized input to
/// the predicate as a literal. These drive the caller's clock arithmetic —
/// Date pairs, not booleans.
final class CallerClockTests: XCTestCase {
    func testHeldGestureIsNeverAbandonedByTickSilence() {
        // STATE-L1: a stationary finger sends no value ticks — the designed
        // interaction the round-2 expiry misclassified as abandonment,
        // letting the still-live gesture re-bind to a different drop.
        let start = Date()
        XCTAssertFalse(GeoARSessionManager.gestureAbandoned(
            now: start.addingTimeInterval(10), lastTick: start, held: true
        ), "10 s of stationary hold is a drag, not abandonment")
        XCTAssertTrue(GeoARSessionManager.gestureAbandoned(
            now: start.addingTimeInterval(31), lastTick: start, held: true
        ), "the 30 s backstop covers a lost end event")
        XCTAssertTrue(GeoARSessionManager.gestureAbandoned(
            now: start.addingTimeInterval(2), lastTick: start, held: false
        ), "an unheld capture is truly abandoned and expires fast")
        XCTAssertFalse(GeoARSessionManager.gestureAbandoned(
            now: start.addingTimeInterval(1.0), lastTick: start, held: false
        ))
    }

    func testVisibilityGraceStrictlyOutlastsThePause() {
        // ARPCFG-R2-1: for a hide-edge stamp at t, the grace must still hold
        // at t + pauseGraceSeconds + a full tick of drift — the round-2
        // window expired 0–400 ms BEFORE the pause it existed to cover, so
        // half of tab flips still destroyed the mesh.
        let hideEdge = Date()
        let pauseMoment = hideEdge.addingTimeInterval(AppConfig.pauseGraceSeconds)
        XCTAssertTrue(GeoARSessionManager.cameraRecentlyVisible(
            now: pauseMoment, lastVisible: hideEdge
        ), "the grace covers the pause moment itself")
        XCTAssertTrue(GeoARSessionManager.cameraRecentlyVisible(
            now: pauseMoment.addingTimeInterval(0.4), lastVisible: hideEdge
        ), "…and a full 400 ms tick of drift past it")
        XCTAssertFalse(GeoARSessionManager.cameraRecentlyVisible(
            now: pauseMoment.addingTimeInterval(1.5), lastVisible: hideEdge
        ), "well past the pause the grace releases honestly")
    }

    func testPassDetachBothConjunctsBind() {
        // RENDER-LENS-1: the round-2 idle threshold dominated the attach
        // term, making it dead code — both conjuncts must bind independently.
        XCTAssertFalse(
            GeoARSessionManager.passShouldDetach(idleFor: 6, attachedFor: 8),
            "freshly attached: the min-attach dwell holds even when idle"
        )
        XCTAssertFalse(
            GeoARSessionManager.passShouldDetach(idleFor: 4, attachedFor: 60),
            "recent work holds the pass regardless of attach age"
        )
        XCTAssertTrue(GeoARSessionManager.passShouldDetach(idleFor: 6, attachedFor: 11))
    }
}

/// Round 4 (counsel F-D3-01/F-D3-02): the caller-CONTEXT rule — round 3's
/// escapes were correct pure functions evaluated against wrong caller state.
final class Round4BindingTests: XCTestCase {
    func testEditTargetBindsInBothDirections() {
        let captured = UUID()
        let nearest = UUID()
        // A live capture is never overridden by a moved nearest.
        XCTAssertEqual(
            GeoARSessionManager.editTarget(
                capture: captured, held: true, nearest: nearest
            ), captured
        )
        // …and survives the finger-up race window (capture set, held gone) —
        // the 1.5 s expiry, not the binding, retires it.
        XCTAssertEqual(
            GeoARSessionManager.editTarget(
                capture: captured, held: false, nearest: nearest
            ), captured
        )
        // An unheld tick with no capture is refused (STATE-L1 holds).
        XCTAssertNil(GeoARSessionManager.editTarget(
            capture: nil, held: false, nearest: nearest
        ))
        // Finger provably down, no capture yet → binds to nearest.
        XCTAssertEqual(
            GeoARSessionManager.editTarget(
                capture: nil, held: true, nearest: nearest
            ), nearest
        )
        // Round 5 (counsel F-D4-DEADPARAM): the round-4 `authored:` rows are
        // gone WITH the parameter — they guarded a branch that was a literal
        // nil at the one call site. Authored edits never bind: ground snap
        // and relocate carry their explicit target straight to applyEdit.
    }

    func testVisibilityTermTable() {
        // Round 5 (counsel F-D4-04): the round-4 "2^4 equality" test was a
        // tautology — perceptionPlan DELEGATES to reconstructionDesired, so
        // it asserted f(x) == f(x) sixteen ways while the real divergence
        // surface (this composition, then inlined at two call sites) went
        // unpinned. The composition is now ONE definition consumed by both
        // the tick plan and the resume plan — agreement by construction —
        // and this table pins the term's own truth, caller-clock style.
        let hideEdge = Date()
        // Camera visible NOW: true regardless of how stale the hide stamp is.
        XCTAssertTrue(GeoARSessionManager.visibilityTerm(
            cameraVisible: true, now: hideEdge.addingTimeInterval(9999),
            lastVisible: .distantPast
        ))
        // Hidden, within the grace (the pause moment itself + tick drift).
        XCTAssertTrue(GeoARSessionManager.visibilityTerm(
            cameraVisible: false,
            now: hideEdge.addingTimeInterval(AppConfig.pauseGraceSeconds + 0.4),
            lastVisible: hideEdge
        ), "a tab flip inside the grace must not read as hidden")
        // Hidden, past the grace: honestly released.
        XCTAssertFalse(GeoARSessionManager.visibilityTerm(
            cameraVisible: false,
            now: hideEdge.addingTimeInterval(AppConfig.pauseGraceSeconds + 1.5),
            lastVisible: hideEdge
        ))
    }
}

/// Round 5 (counsel F-D4-01): the commit tail as a table — the capture (and
/// with it the nearest freeze) survives until the LAST finger lifts.
final class CommitBookkeepingTests: XCTestCase {
    func testCaptureSurvivesUntilTheLastFingerLifts() {
        let capture = UUID()
        // Two thumbs down, first commit: decrement, capture SURVIVES — the
        // round-4 form cleared it here, un-freezing nearest under the still-
        // held second thumb (the STATE-L1 wrong-drop persist, resurrected).
        let first = GeoARSessionManager.commitBookkeeping(
            heldGestures: 2, capture: capture, committed: capture
        )
        XCTAssertEqual(first.remainingHeld, 1)
        XCTAssertEqual(first.capture, capture, "capture must outlive the first commit")
        // Second commit (last finger): capture clears, next drag re-captures.
        let last = GeoARSessionManager.commitBookkeeping(
            heldGestures: first.remainingHeld, capture: first.capture, committed: capture
        )
        XCTAssertEqual(last.remainingHeld, 0)
        XCTAssertNil(last.capture)
        // A commit of a DIFFERENT id never clears someone else's capture.
        let foreign = GeoARSessionManager.commitBookkeeping(
            heldGestures: 1, capture: capture, committed: UUID()
        )
        XCTAssertEqual(foreign.capture, capture)
    }

    func testHeldGestureCounterFloorsAtZero() {
        // Round 3 verdict's hygiene bar: a stray commit with no held gesture
        // (lost begin event) must not drive the count negative — a negative
        // count masked by a later clamp would hide a real begin/end imbalance.
        let stray = GeoARSessionManager.commitBookkeeping(
            heldGestures: 0, capture: nil, committed: UUID()
        )
        XCTAssertEqual(stray.remainingHeld, 0)
        XCTAssertNil(stray.capture)
        // And the floor composes: floor then decrement again stays floored.
        let again = GeoARSessionManager.commitBookkeeping(
            heldGestures: stray.remainingHeld, capture: nil, committed: UUID()
        )
        XCTAssertEqual(again.remainingHeld, 0)
    }
}

/// Round 4 (field protocol Session 1c), rebuilt round 5 (counsel RSCH4-01):
/// under simulator TSan this is the race detector for the pass's lock
/// discipline. The round-4 form never executed the renderCallbacks slot
/// assignment (no ARView → early return), had no rendezvous (a run with zero
/// concurrency was a legal outcome), and asserted a tautology.
@MainActor
final class SemanticPassCrossThreadTests: XCTestCase {
    func testCallbackToggleIsSafeUnderConcurrentReads() {
        let pass = SemanticOcclusionPass(
            feed: SemanticFeed(), labelBuilding: 1, labelTree: 2,
            labelStructure: 3, personOcclusionEnabled: false, midDepthFeed: nil
        )
        // RSCH4-01 leg (2): the probe must EXECUTE the slot assignment the
        // honest unknown is about. Round 6 (counsel F-D5-02): the pass holds
        // the view WEAKLY — a temporary passed inline can be gone by the
        // first toggle, silently reverting this probe to the round-4 vacuity
        // — so the view is a test-scope strong local, and the probe PROVES
        // its own coverage before the hammering starts (also F-R5-07: this
        // assertion fails if prepare(on:) or the slot writes ever rot).
        let view = ARView(frame: .zero)
        pass.prepare(on: view)
        pass.setCallbacksActive(true)
        XCTAssertNotNil(
            view.renderCallbacks.postProcess,
            "the probe must actually execute the renderCallbacks slot assignment"
        )
        XCTAssertNotNil(view.renderCallbacks.prepareWithDevice)
        pass.setCallbacksActive(false)
        XCTAssertNil(view.renderCallbacks.postProcess, "detach must clear the slot")
        let started = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue(label: "toggler").async {
            started.signal()
            for index in 0..<4000 {
                pass.setWorkAdmission(index % 2 == 0, generation: UInt64(index / 2),
                                      person: false, depth: false)
                pass.setCallbacksActive(index % 2 == 0)
            }
            group.leave()
        }
        // RSCH4-01 leg (1): rendezvous, then a DEADLINE-bounded reader — the
        // toggler is provably running before the first read, and the reads
        // span real wall-clock instead of racing a fixed count to the end.
        started.wait()
        let deadline = Date().addingTimeInterval(0.5)
        var reads = 0
        var observedActive = 0
        while Date() < deadline {
            reads += 1
            if pass.callbacksActive { observedActive += 1 }
        }
        // F-D5-02: the view must outlive the toggler, or the weak ref nils
        // mid-run and the remaining toggles exercise nothing.
        withExtendedLifetime(view) { group.wait() }
        pass.setCallbacksActive(false)
        // The sanitizer is the real assertion; these prove the probe RAN
        // (reader iterated against a live toggler), not that it is safe.
        XCTAssertGreaterThan(reads, 0)
        XCTAssertGreaterThanOrEqual(observedActive, 0)
    }
}

/// Round 5 (counsel RSCH4-01): the sentinel's cross-queue state (busy /
/// lastRunAt / lastSeenAt / throttle stamp) had never been executed under the
/// sanitizer at all — leg 1 claimed coverage the suite did not have.
final class PersonSentinelCrossQueueTests: XCTestCase {
    func testTwoQueueFeedersAndAReaderAreLockSafe() throws {
        let sentinel = PersonSentinel()
        sentinel.setWorkAdmission(true, generation: 1)
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &created)
        let buffer = try XCTUnwrap(created, "CVPixelBufferCreate failed")
        let started = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for name in ["sentinel-feeder-a", "sentinel-feeder-b"] {
            group.enter()
            DispatchQueue(label: name).async {
                started.signal()
                // hz high enough that most calls exercise the busy/throttle
                // lock dance rather than Vision itself — the LOCKS are the
                // subject; the detector result on a blank frame is noise.
                for _ in 0..<300 {
                    sentinel.update(pixelBuffer: buffer, hz: 1000)
                }
                group.leave()
            }
        }
        started.wait()
        started.wait()
        let deadline = Date().addingTimeInterval(0.3)
        var reads = 0
        while Date() < deadline {
            _ = sentinel.personLikely
            reads += 1
        }
        group.wait()
        XCTAssertGreaterThan(reads, 0, "the reader must overlap the feeders")
    }
}
