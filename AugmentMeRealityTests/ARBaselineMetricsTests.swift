import XCTest

@testable import AugmentMeReality

final class ARBaselineMetricsTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 100

        func now() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return time
        }

        func advance(_ interval: TimeInterval) {
            lock.lock()
            time += interval
            lock.unlock()
        }
    }

    private func recorder(_ clock: Clock, limits: ARBaselineMetrics.Limits = .init(), enabled: Bool = true) -> ARBaselineMetrics {
        ARBaselineMetrics(enabled: enabled, limits: limits, clock: { clock.now() }, environment: [:])
    }

    func testDisabledRecorderDoesNotCollectAnything() {
        let clock = Clock()
        let metrics = recorder(clock, enabled: false)
        metrics.beginEpoch(kind: "cold_start", generation: 1)
        metrics.event("selected_asset_ready")
        metrics.observe("capture", at: 100)
        metrics.sample("depth_sample_age", milliseconds: 5)
        metrics.setWorkload("reconstruction", enabled: true)
        let token = metrics.measure("inference")
        metrics.end(token)
        metrics.export()
        XCTAssertNil(token)
        XCTAssertTrue(metrics.snapshot().epochs.isEmpty)
    }

    func testCaptureAndRenderCadenceQuantilesAndSampleAge() throws {
        let clock = Clock()
        let metrics = recorder(clock)
        metrics.beginEpoch(kind: "cold_start", generation: 4)
        metrics.observe("capture", at: 100)
        // 100 intervals: nearest-rank p95=95ms, p99=99ms.
        var timestamp = 100.0
        for milliseconds in 1...100 {
            timestamp += Double(milliseconds) / 1000
            metrics.observe("capture", at: timestamp)
        }
        metrics.observe("render_scene_update_proxy", at: 100)
        metrics.observe("render_scene_update_proxy", at: 100.04)
        clock.advance(6)
        let epoch = try XCTUnwrap(metrics.snapshot().epochs.first)
        let capture = try XCTUnwrap(epoch.series.first { $0.name == "capture.interval" })
        let render = try XCTUnwrap(epoch.series.first { $0.name == "render_scene_update_proxy.interval" })
        XCTAssertEqual(capture.totalCount, 100)
        XCTAssertEqual(try XCTUnwrap(capture.meanMilliseconds), 50.5, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(capture.recentSamples.p95Milliseconds), 95, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(capture.recentSamples.p99Milliseconds), 99, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(capture.sampleAgeMilliseconds), 950, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(render.meanMilliseconds), 40, accuracy: 0.000001)
        XCTAssertEqual(epoch.generation, 4)
    }

    func testRecentSamplesAreBoundedAndStartupSamplesRemainSeparate() throws {
        let clock = Clock()
        var limits = ARBaselineMetrics.Limits()
        limits.samplesPerSeries = 3
        let metrics = recorder(clock, limits: limits)
        metrics.beginEpoch(kind: "cold_start", generation: 1)
        for value in 1...3 { metrics.sample("inference", milliseconds: Double(value)) }
        clock.advance(11)
        for value in 11...15 { metrics.sample("inference", milliseconds: Double(value)) }
        let series = try XCTUnwrap(metrics.snapshot().epochs.first?.series.first)
        XCTAssertEqual(series.totalCount, 8)
        XCTAssertEqual(series.recentSamples.count, 3)
        XCTAssertEqual(series.recentSamples.minimumMilliseconds, 13)
        XCTAssertEqual(series.recentSamples.p95Milliseconds, 15)
        XCTAssertEqual(series.startupFirstTenSeconds.count, 3)
        XCTAssertEqual(series.startupFirstTenSeconds.maximumMilliseconds, 3)
        XCTAssertEqual(series.minimumMilliseconds, 1)
        XCTAssertEqual(series.maximumMilliseconds, 15)
    }

    func testLateDurationStaysWithOriginatingEpochAndResumeCadenceStartsFresh() throws {
        let clock = Clock()
        let metrics = recorder(clock)
        metrics.beginEpoch(kind: "cold_start", generation: 8)
        metrics.observe("capture", at: 100)
        let token = metrics.measure("asset_decode")
        clock.advance(2)
        metrics.beginEpoch(kind: "warm_resume", generation: 9)
        metrics.observe("capture", at: 102)
        clock.advance(1)
        metrics.end(token)
        let epochs = metrics.snapshot().epochs
        XCTAssertEqual(epochs.map(\.kind), ["cold_start", "warm_resume"])
        XCTAssertEqual(epochs.map(\.generation), [8, 9])
        let duration = try XCTUnwrap(epochs[0].series.first { $0.name == "asset_decode.duration" })
        XCTAssertEqual(duration.meanMilliseconds, 3000)
        XCTAssertFalse(epochs[1].series.contains { $0.name == "asset_decode.duration" })
        let resumedCapture = try XCTUnwrap(epochs[1].series.first { $0.name == "capture.interval" })
        XCTAssertEqual(resumedCapture.totalCount, 0, "Background time must not become a capture interval.")
        XCTAssertEqual(epochs[0].endedUptime, 102)
        XCTAssertEqual(epochs[1].firstEventsByName["epoch_begin"]?.secondsSinceIntent, 0)
        XCTAssertNil(epochs[1].firstEventsByName["camera_intent"], "The caller distinguishes camera and recovery intent.")
    }

    func testEpochEvictionDropsLateTokensInsteadOfAttributingToRecovery() throws {
        let clock = Clock()
        var limits = ARBaselineMetrics.Limits()
        limits.epochs = 1
        let metrics = recorder(clock, limits: limits)
        metrics.beginEpoch(kind: "cold_start", generation: 1)
        let token = metrics.measure("inference")
        clock.advance(1)
        metrics.beginEpoch(kind: "recovery", generation: 2)
        metrics.end(token)
        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.epochs.count, 1)
        XCTAssertEqual(snapshot.epochs[0].kind, "recovery")
        XCTAssertTrue(snapshot.epochs[0].series.isEmpty)
        XCTAssertEqual(snapshot.droppedEpochs, 1)
        XCTAssertEqual(snapshot.droppedLateMeasurements, 1)
    }

    func testEventsSeriesAndWorkloadBoundsAndMilestoneRetention() throws {
        let clock = Clock()
        var limits = ARBaselineMetrics.Limits()
        limits.eventsPerEpoch = 2
        limits.eventNamesPerEpoch = 3
        limits.seriesPerEpoch = 2
        limits.workloadsPerEpoch = 1
        let metrics = recorder(clock, limits: limits)
        metrics.beginEpoch(kind: "cold_start", generation: 1)
        metrics.event("first_fresh_camera_frame")
        for value in 0..<20 {
            metrics.event("update", details: "\(value)")
            metrics.sample("series_\(value)", milliseconds: 1)
        }
        metrics.setWorkload("reconstruction", enabled: true)
        metrics.setWorkload("neural_depth", enabled: true)
        let epoch = try XCTUnwrap(metrics.snapshot().epochs.first)
        XCTAssertEqual(epoch.recentEvents.count, 2)
        XCTAssertEqual(epoch.firstEventsByName.count, 3)
        XCTAssertNotNil(epoch.firstEventsByName["first_fresh_camera_frame"])
        XCTAssertEqual(epoch.series.count, 2)
        XCTAssertEqual(epoch.workloads, ["reconstruction": true])
        XCTAssertEqual(epoch.droppedEvents, 21)
        XCTAssertEqual(epoch.droppedSeries, 18)
        XCTAssertEqual(epoch.droppedEventNames, 1)
        XCTAssertEqual(epoch.droppedWorkloads, 1)
    }

    func testInvalidObservationsDoNotCorruptFutureIntervalsOrJSON() throws {
        let clock = Clock()
        let metrics = recorder(clock)
        metrics.beginEpoch(kind: "cold_start", generation: 1)
        metrics.observe("capture", at: 99) // Pre-intent frame.
        metrics.observe("capture", at: 100)
        metrics.observe("capture", at: 100) // Duplicate.
        metrics.observe("capture", at: .nan)
        metrics.observe("capture", at: 100.04)
        metrics.sample("inference", milliseconds: .infinity)
        metrics.sample("inference", milliseconds: -1)
        let snapshot = metrics.snapshot()
        let capture = try XCTUnwrap(snapshot.epochs[0].series.first { $0.name == "capture.interval" })
        let inference = try XCTUnwrap(snapshot.epochs[0].series.first { $0.name == "inference" })
        XCTAssertEqual(capture.totalCount, 1)
        XCTAssertEqual(capture.invalidSamples, 3)
        XCTAssertEqual(try XCTUnwrap(capture.meanMilliseconds), 40, accuracy: 0.000001)
        XCTAssertEqual(inference.totalCount, 0)
        XCTAssertEqual(inference.invalidSamples, 2)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
        XCTAssertEqual(snapshot.metadata["commit"], "unmeasured")
        XCTAssertEqual(snapshot.metadata["observed_warmth"], "unmeasured")
        XCTAssertFalse(snapshot.epochs.flatMap(\.series).contains { $0.name == "Postprocess command buffer GPU" })
    }

    func testConcurrentWritersKeepExactTotalsAndBoundedStorage() throws {
        let clock = Clock()
        var limits = ARBaselineMetrics.Limits()
        limits.samplesPerSeries = 16
        let metrics = recorder(clock, limits: limits)
        metrics.beginEpoch(kind: "cold_start", generation: 1)
        DispatchQueue.concurrentPerform(iterations: 2000) { _ in
            metrics.sample("sample_age", milliseconds: 12)
        }
        let series = try XCTUnwrap(metrics.snapshot().epochs.first?.series.first)
        XCTAssertEqual(series.totalCount, 2000)
        XCTAssertEqual(series.meanMilliseconds, 12)
        XCTAssertEqual(series.recentSamples.count, 16)
        XCTAssertEqual(series.startupFirstTenSeconds.count, 16)
    }

    func testSystemHistoryRetainsTimestampAndGenerationWithinBound() {
        let clock = Clock()
        var limits = ARBaselineMetrics.Limits()
        limits.systemSamples = 2
        let metrics = recorder(clock, limits: limits)
        metrics.beginEpoch(kind: "cold_start", generation: 1)
        metrics.sampleSystemResources()
        clock.advance(30)
        metrics.sampleSystemResources()
        clock.advance(30)
        metrics.beginEpoch(kind: "warm_resume", generation: 2)
        metrics.sampleSystemResources()
        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.recentSystemSamples.map(\.uptime), [130, 160])
        XCTAssertEqual(snapshot.recentSystemSamples.map(\.generation), [1, 2])
        XCTAssertEqual(snapshot.droppedSystemSamples, 1)
        XCTAssertTrue(snapshot.recentSystemSamples.allSatisfy { !$0.processThermalState.isEmpty })
    }
    func testWholeEpochHistogramRetainsEarlyStallsAfterRecentSamplesEvict() throws {
        let clock = Clock()
        var limits = ARBaselineMetrics.Limits()
        limits.samplesPerSeries = 3
        let metrics = recorder(clock, limits: limits)
        metrics.beginEpoch(kind: "coldStart", generation: 1)
        for _ in 0..<10 { metrics.sample("frame", milliseconds: 81.2) }
        for _ in 0..<90 { metrics.sample("frame", milliseconds: 33.3) }
        let series = try XCTUnwrap(metrics.snapshot().epochs.first?.series.first)
        XCTAssertEqual(series.recentSamples.p95Milliseconds, 33.3)
        XCTAssertEqual(series.wholeEpochHistogram.count, 100)
        XCTAssertEqual(series.wholeEpochHistogram.p95UpperBoundMilliseconds, 82)
        XCTAssertEqual(series.wholeEpochHistogram.p99UpperBoundMilliseconds, 82)
    }

    func testHistogramOverflowCannotLookLikeA1000msCap() throws {
        let clock = Clock()
        let metrics = recorder(clock)
        metrics.sample("stall", milliseconds: 5000)
        let full = try XCTUnwrap(metrics.snapshot().epochs.first?.series.first?.wholeEpochHistogram)
        XCTAssertNil(full.p95UpperBoundMilliseconds)
        XCTAssertEqual(full.overflowCount, 1)
    }

    func testWorkloadActiveTimeRemainsPerEpochAfterEventEviction() throws {
        let clock = Clock()
        var limits = ARBaselineMetrics.Limits()
        limits.eventsPerEpoch = 1
        let metrics = recorder(clock, limits: limits)
        metrics.beginEpoch(kind: "coldStart", generation: 1)
        metrics.setWorkload("pass", enabled: true)
        clock.advance(10)
        metrics.beginEpoch(kind: "warmResume", generation: 2)
        clock.advance(5)
        metrics.setWorkload("pass", enabled: false)
        clock.advance(10)
        let epochs = metrics.snapshot().epochs
        XCTAssertEqual(epochs[0].workloadActivity["pass"]?.observedActiveSeconds, 10)
        XCTAssertEqual(epochs[1].workloadActivity["pass"]?.observedActiveSeconds, 5)
        XCTAssertEqual(epochs[1].workloadActivity["pass"]?.enabled, false)
    }

    func testGPUCompletionUsesOriginatingEpochAndSharedIntentTimestamp() throws {
        let clock = Clock()
        let metrics = recorder(clock)
        metrics.beginEpoch(kind: "coldStart", generation: 1, at: 99)
        let token = metrics.measure("encode")
        clock.advance(1)
        metrics.beginEpoch(kind: "recovery", generation: 2)
        metrics.sample("GPU", milliseconds: 4, originating: token)
        let epochs = metrics.snapshot().epochs
        XCTAssertEqual(epochs[0].intentUptime, 99)
        XCTAssertEqual(epochs[0].series.first { $0.name == "GPU" }?.meanMilliseconds, 4)
        XCTAssertFalse(epochs[1].series.contains { $0.name == "GPU" })
    }

    func testHiddenTimeDoesNotExtendCameraEpochOrCadence() throws {
        let clock = Clock()
        let metrics = recorder(clock)
        metrics.beginEpoch(kind: "coldStart", generation: 1)
        metrics.observe("capture", at: 100)
        clock.advance(1)
        metrics.endEpoch(reason: "cameraHidden")
        clock.advance(20)
        metrics.observe("capture", at: 121)
        metrics.beginEpoch(kind: "warmResume", generation: 2)
        let epochs = metrics.snapshot().epochs
        XCTAssertEqual(epochs.map(\.kind), ["coldStart", "cameraInactive", "warmResume"])
        XCTAssertEqual(epochs[0].endedUptime, 101)
        XCTAssertEqual(epochs[1].series.first?.totalCount, 0)
    }

}
