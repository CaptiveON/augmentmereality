import XCTest
@testable import AugmentMeReality

/// These drive the same demand-to-adapter entry point used by the manager.
/// No ARKit session, wall-clock waits or successful detector output is required.
@MainActor
final class PerceptionDemandTests: XCTestCase {
    private final class Clock {
        var time = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { time.addTimeInterval(seconds) }
    }

    private final class Subsystems: PerceptionSubsystemAdapter {
        var current = PerceptionPolicy.Plan()
        var configurations = 0
        var reconstructionStarts = 0
        var history: [PerceptionPolicy.Plan] = []

        func applyPerceptionPlan(_ plan: PerceptionPolicy.Plan) {
            if current.reconstruction != plan.reconstruction
                || current.person != plan.person || current.depth != plan.depth {
                configurations += 1
            }
            if !current.reconstruction && plan.reconstruction { reconstructionStarts += 1 }
            current = plan
            history.append(plan)
        }
    }

    private func scene() -> PerceptionDemand {
        var demand = PerceptionDemand()
        demand.cameraVisible = true
        demand.sessionRunning = true
        demand.cameraRecentlyVisible = true
        demand.content = [.init(distance: 4.5, isInView: true), .init(distance: 80, isInView: true)]
        demand.personLikely = true
        demand.supportsPersonSegmentation = true
        demand.supportsCustomPersonOcclusion = true
        demand.supportsSceneReconstruction = true
        demand.supportsSceneDepth = true
        demand.hasSemanticPass = true
        demand.geospatialAvailable = true
        demand.supportsSemantics = true
        demand.midFieldEnabled = true
        return demand
    }

    private func assertNoAdmittedWork(
        _ plan: PerceptionPolicy.Plan, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(plan.personAdmitted, file: file, line: line)
        XCTAssertFalse(plan.personUse, file: file, line: line)
        XCTAssertFalse(plan.midField, file: file, line: line)
        XCTAssertFalse(plan.semantics, file: file, line: line)
        XCTAssertFalse(plan.sentinel, file: file, line: line)
        XCTAssertFalse(plan.localization, file: file, line: line)
        XCTAssertFalse(plan.passNeeded, file: file, line: line)
    }

    func testSeriousStopsSemanticProductionAndUseTogether() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.semantics)
        XCTAssertTrue(subsystems.current.midField)
        clock.advance(0.4)
        demand.thermalSerious = true
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.semantics)
        XCTAssertFalse(subsystems.current.midField)
        XCTAssertTrue(subsystems.current.personUse)
        XCTAssertTrue(subsystems.current.depth, "a person still owns the custom depth test")
    }

    func testCriticalBypassesGovernorAndBothSensorDwellsOnNextUpdate() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        policy.update(demand, applyingTo: subsystems)
        clock.advance(1)
        demand.content = [.init(distance: 80, isInView: false)]
        demand.personLikely = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertEqual(subsystems.current.tier, .full, "ordinary tier downgrade is pending")
        XCTAssertTrue(subsystems.current.person, "ordinary person off dwell is pending")
        XCTAssertTrue(subsystems.current.depth, "ordinary depth off dwell is pending")
        clock.advance(0.1)
        demand.thermalCritical = true
        policy.update(demand, applyingTo: subsystems)
        XCTAssertEqual(subsystems.current.tier, .idle)
        XCTAssertFalse(subsystems.current.reconstruction)
        XCTAssertFalse(subsystems.current.person)
        XCTAssertFalse(subsystems.current.depth)
        XCTAssertTrue(subsystems.current.hardShutdown)
        assertNoAdmittedWork(subsystems.current)
    }

    func testCriticalRecoverySurvivesSessionResetAndRequiresSixCoolSeconds() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        policy.update(demand, applyingTo: subsystems)
        demand.thermalCritical = true
        policy.update(demand, applyingTo: subsystems)
        policy.resetSessionRequests()
        XCTAssertTrue(policy.plan.recoveringFromCritical,
                      "the resume configuration must see recovery before its next policy tick")
        clock.advance(1)
        demand.thermalCritical = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.recoveringFromCritical)
        clock.advance(5.9)
        policy.update(demand, applyingTo: subsystems)
        assertNoAdmittedWork(subsystems.current)
        XCTAssertFalse(subsystems.current.reconstruction)
        clock.advance(0.1)
        policy.update(demand, applyingTo: subsystems)
        XCTAssertEqual(subsystems.current.tier, .full)
        XCTAssertTrue(subsystems.current.reconstruction)
        XCTAssertTrue(subsystems.current.personUse)
        XCTAssertTrue(subsystems.current.semantics)
        XCTAssertFalse(subsystems.current.recoveringFromCritical)
    }

    func testHiddenGraceRetainsMeshButImmediatelyStopsAllNewMLAndCallbacks() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        policy.update(demand, applyingTo: subsystems)
        clock.advance(0.4)
        demand.cameraVisible = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.reconstruction)
        XCTAssertFalse(subsystems.current.person)
        XCTAssertFalse(subsystems.current.depth)
        assertNoAdmittedWork(subsystems.current)
        clock.advance(4)
        demand.cameraVisible = true
        policy.update(demand, applyingTo: subsystems)
        XCTAssertEqual(subsystems.reconstructionStarts, 1, "short tab return preserves mesh")
        XCTAssertTrue(subsystems.current.personUse)
        XCTAssertTrue(subsystems.current.midField)
    }

    func testHiddenCannotStartMeshAndExpiredGraceReleasesRetainedMesh() {
        let clock = Clock()
        let subsystems = Subsystems()
        var coldPolicy = PerceptionPolicy(now: { clock.time })
        var demand = scene()
        demand.cameraVisible = false
        coldPolicy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.reconstruction)
        var warmPolicy = PerceptionPolicy(now: { clock.time })
        demand.cameraVisible = true
        warmPolicy.update(demand, applyingTo: subsystems)
        demand.cameraVisible = false
        warmPolicy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.reconstruction)
        clock.advance(6)
        demand.cameraRecentlyVisible = false
        warmPolicy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.reconstruction)
        assertNoAdmittedWork(subsystems.current)
    }

    func testStoppedSessionCannotAdmitWorkAndResumeDoesNotInheritDwell() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        policy.update(demand, applyingTo: subsystems)
        demand.sessionRunning = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.reconstruction)
        XCTAssertFalse(subsystems.current.person)
        XCTAssertFalse(subsystems.current.depth)
        assertNoAdmittedWork(subsystems.current)
        policy.resetSessionRequests()
        demand.sessionRunning = true
        demand.personLikely = false
        demand.content = [.init(distance: 80, isInView: true)]
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.reconstruction)
        XCTAssertFalse(subsystems.current.person, "pre-pause person requests cannot restart")
        XCTAssertFalse(subsystems.current.depth)
        demand.personLikely = true
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.personUse, "fresh detection restores person occlusion")
    }

    func testOffscreenNearestCannotCombineWithDistantProjectedObject() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        demand.personLikely = false
        demand.content = [.init(distance: 4.5, isInView: false), .init(distance: 120, isInView: true)]
        policy.update(demand, applyingTo: subsystems)
        XCTAssertEqual(subsystems.current.tier, .cruise)
        XCTAssertFalse(subsystems.current.midField)
        XCTAssertFalse(subsystems.current.depth)
        XCTAssertTrue(subsystems.current.semantics, "far projected content still owns the matte")
        demand.content = [.init(distance: 20, isInView: true), .init(distance: 120, isInView: false)]
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.semantics, "an unrelated offscreen far object cannot request semantics")
    }

    func testFarVirtualContentCanStillBeOccludedByNearbyPerson() {
        var policy = PerceptionPolicy()
        let subsystems = Subsystems()
        var demand = scene()
        demand.content = [.init(distance: 200, isInView: true)]
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.personAdmitted)
        XCTAssertTrue(subsystems.current.personUse)
        XCTAssertTrue(subsystems.current.depth)
        XCTAssertFalse(subsystems.current.midField)
    }

    func testSecondEditingFingerKeepsItsContentRelevantUntilLastLift() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        demand.personLikely = false
        demand.content = [.init(distance: 4.5, isInView: false, isEditing: true)]
        demand.heldGestures = 2
        policy.update(demand, applyingTo: subsystems)
        XCTAssertEqual(subsystems.current.tier, .full)
        XCTAssertTrue(subsystems.current.midField)
        demand.heldGestures = 1
        clock.advance(1)
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.midField)
        demand.heldGestures = 0
        clock.advance(1)
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.midField)
        XCTAssertFalse(subsystems.current.passNeeded)
    }

    func testNormalOffDwellPreventsPersonChurnButNeverPretendsConsumerIsActive() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        demand.midFieldEnabled = false
        policy.update(demand, applyingTo: subsystems)
        demand.personLikely = false
        clock.advance(1)
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.person)
        XCTAssertTrue(subsystems.current.depth)
        XCTAssertFalse(subsystems.current.personUse)
        clock.advance(9)
        demand.personLikely = true
        policy.update(demand, applyingTo: subsystems)
        XCTAssertEqual(subsystems.configurations, 1, "short detection loss needs no session reconfiguration")
        demand.personLikely = false
        clock.advance(1)
        policy.update(demand, applyingTo: subsystems)
        clock.advance(10)
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.person)
        XCTAssertFalse(subsystems.current.depth)
        XCTAssertEqual(subsystems.configurations, 2)
        XCTAssertEqual(subsystems.reconstructionStarts, 1)
    }

    func testGlassAndTransitTransitionsPreserveSupportedOcclusion() {
        let clock = Clock()
        var policy = PerceptionPolicy(now: { clock.time })
        let subsystems = Subsystems()
        var demand = scene()
        policy.update(demand, applyingTo: subsystems)
        demand.windowModeActive = true
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.reconstruction, "brief glass detection does not discard the mesh")
        XCTAssertFalse(subsystems.current.person)
        XCTAssertFalse(subsystems.current.depth)
        XCTAssertFalse(subsystems.current.midField)
        XCTAssertTrue(subsystems.current.semantics)
        demand.windowModeActive = false
        demand.pedestrian = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.reconstruction)
        XCTAssertFalse(subsystems.current.midField)
        XCTAssertTrue(subsystems.current.personUse)
        XCTAssertTrue(subsystems.current.depth, "transit retains the existing custom person path")
        XCTAssertTrue(subsystems.current.semantics)
        demand.pedestrian = true
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.reconstruction)
        XCTAssertTrue(subsystems.current.midField)
    }

    func testTransitImmediatelyReleasesDepthOwnedOnlyByMidField() {
        var policy = PerceptionPolicy()
        let subsystems = Subsystems()
        var demand = scene()
        demand.personLikely = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.depth)
        demand.pedestrian = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.depth)
        XCTAssertFalse(subsystems.current.midField)
    }

    func testNonLiDARFallbackDoesNotRequestUnusableCustomPass() {
        var policy = PerceptionPolicy()
        let subsystems = Subsystems()
        var demand = scene()
        demand.supportsSceneReconstruction = false
        demand.supportsSceneDepth = false
        demand.supportsCustomPersonOcclusion = false
        demand.geospatialAvailable = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertTrue(subsystems.current.person)
        XCTAssertTrue(subsystems.current.personUse)
        XCTAssertFalse(subsystems.current.depth)
        XCTAssertFalse(subsystems.current.midField)
        XCTAssertFalse(subsystems.current.reconstruction)
        XCTAssertFalse(subsystems.current.passNeeded)
        XCTAssertFalse(subsystems.current.localization)
    }

    func testUnavailableCapabilitiesAndExperimentExclusionsDoNotRequestWork() {
        var policy = PerceptionPolicy()
        let subsystems = Subsystems()
        var demand = scene()
        demand.supportsPersonSegmentation = false
        demand.allowsReconstruction = false
        demand.allowsSentinel = false
        demand.hasSemanticPass = false
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.person)
        XCTAssertFalse(subsystems.current.depth)
        XCTAssertFalse(subsystems.current.reconstruction)
        XCTAssertFalse(subsystems.current.semantics)
        XCTAssertFalse(subsystems.current.midField)
        XCTAssertFalse(subsystems.current.sentinel)
        XCTAssertFalse(subsystems.current.passNeeded)
    }

    func testSemanticSupportAndExistingRangeFloorsArePreserved() {
        let subsystems = Subsystems()
        var demand = scene()
        demand.personLikely = false
        demand.midFieldEnabled = false
        for (pedestrian, distance, expected) in [
            (true, Float(55), false), (true, Float(55.1), true),
            (false, Float(15), false), (false, Float(15.1), true)
        ] {
            var policy = PerceptionPolicy()
            demand.pedestrian = pedestrian
            demand.content = [.init(distance: distance, isInView: true)]
            policy.update(demand, applyingTo: subsystems)
            XCTAssertEqual(subsystems.current.semantics, expected)
        }
        demand.supportsSemantics = false
        var policy = PerceptionPolicy()
        policy.update(demand, applyingTo: subsystems)
        XCTAssertFalse(subsystems.current.semantics)
        XCTAssertFalse(subsystems.current.passNeeded,
                       "an available GAR session without semantic support has no matte work")
    }
}
