import CoreVideo
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

/// Wave D (counsel SWE-11/ARP-8 + ARP-13): the perception request set as a
/// pure table — the sensor REQUEST must derive from the same predicate as the
/// sensor's USE.
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
    ) -> (reconstruction: Bool, person: Bool, depth: Bool) {
        GeoARSessionManager.perceptionPlan(
            tierAboveIdle: tierAboveIdle, fullTier: fullTier,
            cameraVisible: cameraVisible,
            cameraRecentlyVisible: cameraRecentlyVisible ?? cameraVisible,
            pedestrian: pedestrian,
            windowModeActive: windowModeActive, personLikely: personLikely,
            contentInViewRecently: contentInViewRecently,
            midFieldServiceable: midFieldServiceable,
            thermalSerious: thermalSerious,
            thermalCritical: thermalCritical,
            supportsCustomPersonOcclusion: supportsCustomPersonOcclusion,
            supportsSceneReconstruction: supportsSceneReconstruction,
            supportsSceneDepth: supportsSceneDepth,
            midFieldEnabled: midFieldEnabled
        )
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

    func testThermalCriticalShedsReconstructionOnly() {
        let result = plan(thermalCritical: true)
        XCTAssertFalse(result.reconstruction)
        XCTAssertTrue(result.person, "person occlusion correctness survives heat shedding")
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
