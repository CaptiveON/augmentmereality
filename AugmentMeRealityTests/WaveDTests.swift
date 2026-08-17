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
        pedestrian: Bool = true,
        windowModeActive: Bool = false,
        personLikely: Bool = true,
        contentInViewRecently: Bool = true,
        anyContentBeyondMidMin: Bool = true,
        thermalCritical: Bool = false,
        supportsCustomPersonOcclusion: Bool = true,
        midFieldEnabled: Bool = true
    ) -> (reconstruction: Bool, person: Bool, depth: Bool) {
        GeoARSessionManager.perceptionPlan(
            tierAboveIdle: tierAboveIdle, fullTier: fullTier,
            cameraVisible: cameraVisible, pedestrian: pedestrian,
            windowModeActive: windowModeActive, personLikely: personLikely,
            contentInViewRecently: contentInViewRecently,
            anyContentBeyondMidMin: anyContentBeyondMidMin,
            thermalCritical: thermalCritical,
            supportsCustomPersonOcclusion: supportsCustomPersonOcclusion,
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
        let result = plan(anyContentBeyondMidMin: false, supportsCustomPersonOcclusion: false)
        XCTAssertTrue(result.person)
        XCTAssertFalse(result.depth)
    }

    func testCameraHiddenShedsEverythingStateful() {
        let result = plan(tierAboveIdle: false, cameraVisible: false, personLikely: false)
        XCTAssertFalse(result.reconstruction)
        XCTAssertFalse(result.person)
        XCTAssertFalse(result.depth)
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
