import XCTest
@testable import AugmentMeReality

@MainActor
final class PerceptionCoordinatorTests: XCTestCase {
    private final class Clock {
        var time = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { time.addTimeInterval(seconds) }
    }

    /// Records individual side effects and uses the production admission-token
    /// primitive to complete delayed work. It never receives or stores a Plan.
    private final class Sink: PerceptionSubsystemSink {
        struct Configuration: Equatable {
            var reconstruction = false
            var person = false
            var depth = false
        }
        var configuration = Configuration()
        var configurations = 0
        var reconstructionStarts = 0
        var localization = PerceptionWorkAdmission()
        var sentinel = PerceptionWorkAdmission()
        var depth = PerceptionWorkAdmission()
        var pass = PerceptionWorkAdmission()
        var personUse = false
        var depthUse = false
        var semanticsRequested = false
        var semanticsActive = false
        var semanticConsumer = false
        var callbacks = false
        var failDisables = 0
        var failEnables = 0
        var depthHasSample = false
        var events: [String] = []

        func configure(reconstruction: Bool, person: Bool, depth: Bool) {
            events.append("configure")
            let next = Configuration(reconstruction: reconstruction, person: person, depth: depth)
            if configuration != next { configurations += 1 }
            if !configuration.reconstruction && reconstruction { reconstructionStarts += 1 }
            configuration = next
        }

        func setLocalizationAdmission(allowed: Bool, generation: UInt64) {
            events.append("localization:\(allowed)")
            localization.setAllowed(allowed, generation: generation)
        }

        func setSemanticsRequested(_ requested: Bool) -> Bool {
            events.append("semantics:\(requested)")
            semanticsRequested = requested
            if !requested && semanticsActive && failDisables > 0 {
                failDisables -= 1
            } else if requested && !semanticsActive && failEnables > 0 {
                failEnables -= 1
            } else {
                semanticsActive = requested && localization.allowed
            }
            return semanticsActive
        }

        var localizationCanUpdate: Bool {
            localization.allowed && !(semanticsActive && !semanticsRequested)
        }

        func setSentinelAdmission(allowed: Bool, generation: UInt64) {
            events.append("sentinel:\(allowed)")
            sentinel.setAllowed(allowed, generation: generation)
        }

        func setDepthAdmission(allowed: Bool, generation: UInt64) {
            events.append("depth:\(allowed)")
            if depth.setAllowed(allowed, generation: generation) { depthHasSample = false }
        }

        func setPassAdmission(allowed: Bool, generation: UInt64, person: Bool, depth: Bool) {
            events.append("pass:\(allowed)")
            pass.setAllowed(allowed, generation: generation)
            personUse = allowed && person
            depthUse = allowed && depth
        }

        func setSemanticConsumerEnabled(_ enabled: Bool) {
            events.append("semanticConsumer:\(enabled)")
            semanticConsumer = enabled
        }

        func setCallbacksActive(_ active: Bool) {
            events.append("callbacks:\(active)")
            callbacks = active
        }

        @discardableResult
        func completeDepth(_ token: PerceptionWorkAdmission.Token) -> Bool {
            guard depth.accepts(token) else { return false }
            depthHasSample = true
            return true
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

    private func assertClosed(_ sink: Sink, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(sink.localization.allowed, file: file, line: line)
        XCTAssertFalse(sink.localizationCanUpdate, file: file, line: line)
        XCTAssertFalse(sink.sentinel.allowed, file: file, line: line)
        XCTAssertFalse(sink.depth.allowed, file: file, line: line)
        XCTAssertFalse(sink.pass.allowed, file: file, line: line)
        XCTAssertFalse(sink.personUse, file: file, line: line)
        XCTAssertFalse(sink.depthUse, file: file, line: line)
        XCTAssertFalse(sink.semanticConsumer, file: file, line: line)
        XCTAssertFalse(sink.callbacks, file: file, line: line)
    }

    func testDemandOpensActualProducersConsumersAndConfigurationInOrder() throws {
        let clock = Clock()
        let sink = Sink()
        let coordinator = PerceptionCoordinator(sink: sink, now: { clock.time })
        var policy = PerceptionPolicy(now: { clock.time })
        policy.update(scene(), applyingTo: coordinator)
        XCTAssertEqual(sink.configuration, .init(reconstruction: true, person: true, depth: true))
        XCTAssertTrue(sink.localizationCanUpdate)
        XCTAssertTrue(sink.sentinel.allowed)
        XCTAssertTrue(sink.depth.allowed)
        XCTAssertTrue(sink.personUse)
        XCTAssertTrue(sink.depthUse)
        XCTAssertTrue(sink.semanticsActive)
        XCTAssertTrue(sink.semanticConsumer)
        XCTAssertTrue(sink.callbacks)
        XCTAssertLessThan(try XCTUnwrap(sink.events.firstIndex(of: "localization:true")),
                          try XCTUnwrap(sink.events.firstIndex(of: "semantics:true")))
        XCTAssertLessThan(try XCTUnwrap(sink.events.firstIndex(of: "configure")),
                          try XCTUnwrap(sink.events.firstIndex(of: "callbacks:true")))
    }

    func testCriticalClosesAllEffectsWhileGovernorSensorAndCallbackDwellsArePending() throws {
        let clock = Clock()
        let sink = Sink()
        let coordinator = PerceptionCoordinator(sink: sink, now: { clock.time })
        var policy = PerceptionPolicy(now: { clock.time })
        var demand = scene()
        policy.update(demand, applyingTo: coordinator)
        let oldToken = try XCTUnwrap(sink.depth.token)
        XCTAssertTrue(sink.completeDepth(oldToken))
        demand.content = [.init(distance: 80, isInView: false)]
        demand.personLikely = false
        clock.advance(1)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.configuration.person)
        XCTAssertTrue(sink.configuration.depth)
        XCTAssertTrue(sink.callbacks)
        XCTAssertEqual(coordinator.currentPlan.tier, .full)
        sink.events.removeAll()
        demand.thermalCritical = true
        clock.advance(0.1)
        policy.update(demand, applyingTo: coordinator)
        assertClosed(sink)
        XCTAssertEqual(sink.configuration, .init())
        XCTAssertFalse(sink.completeDepth(oldToken))
        XCTAssertFalse(sink.depthHasSample)
        XCTAssertFalse(coordinator.localizationAdmitted)
        XCTAssertFalse(coordinator.semanticConsumerEnabled)
        XCTAssertLessThan(try XCTUnwrap(sink.events.firstIndex(of: "semanticConsumer:false")),
                          try XCTUnwrap(sink.events.firstIndex(of: "semantics:false")))
    }

    func testFailedSeriousSemanticDisableClosesLocalizationUntilSuccessfulRetry() throws {
        let clock = Clock()
        let sink = Sink()
        let coordinator = PerceptionCoordinator(sink: sink, now: { clock.time })
        var policy = PerceptionPolicy(now: { clock.time })
        var demand = scene()
        policy.update(demand, applyingTo: coordinator)
        sink.events.removeAll()
        sink.failDisables = 1
        demand.thermalSerious = true
        clock.advance(0.4)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.semanticsActive, "the failed SDK disable remains truthful")
        XCTAssertFalse(sink.semanticsRequested)
        XCTAssertFalse(sink.semanticConsumer)
        XCTAssertFalse(sink.localization.allowed, "no GAR feed may keep unwanted inference running")
        XCTAssertFalse(sink.localizationCanUpdate)
        XCTAssertFalse(coordinator.localizationAdmitted)
        XCTAssertTrue(sink.personUse, "custom person occlusion survives serious")
        XCTAssertFalse(sink.depth.allowed)
        XCTAssertLessThan(try XCTUnwrap(sink.events.firstIndex(of: "semantics:false")),
                          try XCTUnwrap(sink.events.firstIndex(of: "localization:false")))
        clock.advance(0.4)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(sink.semanticsActive)
        XCTAssertTrue(sink.localizationCanUpdate)
        XCTAssertTrue(coordinator.localizationAdmitted)
        XCTAssertFalse(sink.semanticConsumer)
    }

    func testFailedSemanticEnableCannotAttachEmptyPass() {
        let sink = Sink()
        sink.failEnables = 1
        let coordinator = PerceptionCoordinator(sink: sink)
        var policy = PerceptionPolicy()
        var demand = scene()
        demand.personLikely = false
        demand.content = [.init(distance: 80, isInView: true)]
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.semanticsRequested)
        XCTAssertFalse(sink.semanticsActive)
        XCTAssertFalse(sink.semanticConsumer)
        XCTAssertTrue(sink.localizationCanUpdate)
        XCTAssertFalse(sink.callbacks)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.semanticsActive)
        XCTAssertTrue(sink.semanticConsumer)
        XCTAssertTrue(sink.callbacks)
    }

    func testHideInvalidatesLateCompletionWithoutDiscardingWarmMesh() throws {
        let clock = Clock()
        let sink = Sink()
        let coordinator = PerceptionCoordinator(sink: sink, now: { clock.time })
        var policy = PerceptionPolicy(now: { clock.time })
        var demand = scene()
        policy.update(demand, applyingTo: coordinator)
        let oldToken = try XCTUnwrap(sink.depth.token)
        let oldGeneration = coordinator.generation
        let configCount = sink.configurations
        coordinator.invalidate()
        XCTAssertEqual(coordinator.generation, oldGeneration + 1)
        XCTAssertEqual(sink.configurations, configCount, "invalidation itself must not rerun ARKit")
        assertClosed(sink)
        demand.cameraVisible = false
        policy.update(demand, applyingTo: coordinator)
        XCTAssertEqual(sink.configuration, .init(reconstruction: true, person: false, depth: false))
        clock.advance(4.5)
        demand.cameraVisible = true
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(sink.completeDepth(oldToken), "a pre-hide result cannot rearm a resumed feed")
        XCTAssertFalse(sink.depthHasSample)
        let freshToken = try XCTUnwrap(sink.depth.token)
        XCTAssertTrue(sink.completeDepth(freshToken))
        XCTAssertTrue(sink.depthHasSample)
        XCTAssertEqual(sink.reconstructionStarts, 1)
        XCTAssertEqual(freshToken.sessionGeneration, coordinator.generation)
    }

    func testInterruptedResumeWithCriticalRecoveryCannotReopenAnySinkEarly() {
        let clock = Clock()
        let sink = Sink()
        let coordinator = PerceptionCoordinator(sink: sink, now: { clock.time })
        var policy = PerceptionPolicy(now: { clock.time })
        var demand = scene()
        policy.update(demand, applyingTo: coordinator)
        demand.thermalCritical = true
        policy.update(demand, applyingTo: coordinator)
        coordinator.invalidate()
        policy.resetSessionRequests()
        demand.sessionRunning = false
        policy.update(demand, applyingTo: coordinator)
        assertClosed(sink)
        demand.sessionRunning = true
        demand.thermalCritical = false
        clock.advance(1)
        policy.update(demand, applyingTo: coordinator)
        assertClosed(sink)
        XCTAssertEqual(sink.configuration, .init())
        clock.advance(6)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.configuration.reconstruction)
        XCTAssertTrue(sink.depth.allowed)
        XCTAssertTrue(sink.callbacks)
    }

    func testCallbackOffDwellRequiresBothFiveIdleAndTenAttachedSeconds() {
        let clock = Clock()
        let sink = Sink()
        let coordinator = PerceptionCoordinator(sink: sink, now: { clock.time })
        var policy = PerceptionPolicy(now: { clock.time })
        var demand = scene()
        demand.personLikely = false
        demand.content = [.init(distance: 80, isInView: true)]
        policy.update(demand, applyingTo: coordinator)
        demand.content = [.init(distance: 80, isInView: false)]
        clock.advance(1)
        policy.update(demand, applyingTo: coordinator)
        clock.advance(5)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.callbacks, "five idle seconds do not bypass ten attached seconds")
        clock.advance(4.001)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(sink.callbacks)
        demand.content = [.init(distance: 80, isInView: true)]
        policy.update(demand, applyingTo: coordinator)
        clock.advance(20)
        demand.content = [.init(distance: 80, isInView: false)]
        policy.update(demand, applyingTo: coordinator)
        clock.advance(4.9)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.callbacks, "a long attachment does not bypass five idle seconds")
        clock.advance(0.101)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(sink.callbacks)
    }

    func testBuiltInPersonDwellRemainsTruthfulWithoutCustomCallbacks() {
        let clock = Clock()
        let sink = Sink()
        let coordinator = PerceptionCoordinator(sink: sink, now: { clock.time })
        var policy = PerceptionPolicy(now: { clock.time })
        var demand = scene()
        demand.supportsCustomPersonOcclusion = false
        demand.supportsSceneDepth = false
        demand.supportsSceneReconstruction = false
        demand.geospatialAvailable = false
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.configuration.person)
        XCTAssertFalse(sink.configuration.depth)
        XCTAssertFalse(sink.personUse, "built-in occlusion does not need the custom pass")
        XCTAssertFalse(sink.callbacks)
        demand.personLikely = false
        clock.advance(1)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(coordinator.currentPlan.personAdmitted)
        XCTAssertTrue(coordinator.currentPlan.personUse)
        XCTAssertTrue(sink.configuration.person)
        XCTAssertFalse(sink.callbacks)
        clock.advance(10)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(sink.configuration.person)
        XCTAssertFalse(coordinator.currentPlan.personUse)
    }

    func testEditingGlassAndTransitDriveActualDepthAndPersonSinks() {
        let clock = Clock()
        let sink = Sink()
        let coordinator = PerceptionCoordinator(sink: sink, now: { clock.time })
        var policy = PerceptionPolicy(now: { clock.time })
        var demand = scene()
        demand.personLikely = false
        demand.content = [.init(distance: 4.5, isInView: false, isEditing: true)]
        demand.heldGestures = 2
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.depth.allowed)
        XCTAssertTrue(sink.configuration.depth)
        demand.heldGestures = 1
        clock.advance(1)
        policy.update(demand, applyingTo: coordinator)
        XCTAssertTrue(sink.depth.allowed, "first finger lift cannot abandon the other editor")
        demand.windowModeActive = true
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(sink.depth.allowed)
        XCTAssertFalse(sink.depthUse)
        XCTAssertFalse(sink.configuration.depth)
        XCTAssertTrue(sink.configuration.reconstruction)
        demand.windowModeActive = false
        demand.pedestrian = false
        demand.personLikely = true
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(sink.configuration.reconstruction)
        XCTAssertTrue(sink.configuration.person)
        XCTAssertTrue(sink.configuration.depth, "transit keeps custom person depth")
        XCTAssertTrue(sink.personUse)
        XCTAssertFalse(sink.depth.allowed, "transit cannot run neural depth")
        demand.heldGestures = 0
        policy.update(demand, applyingTo: coordinator)
        XCTAssertFalse(sink.personUse)
        XCTAssertFalse(sink.depth.allowed)
        XCTAssertFalse(sink.sentinel.allowed)
    }
}
