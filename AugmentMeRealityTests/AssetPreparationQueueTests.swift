import XCTest
@testable import AugmentMeReality

@MainActor
final class AssetPreparationQueueTests: XCTestCase {
    private final class Loader {
        var starts: [String] = []
        var pending: [String: CheckedContinuation<String?, Never>] = [:]
        var expectations: [String: XCTestExpectation] = [:]

        func expect(_ name: String) -> XCTestExpectation {
            let result = XCTestExpectation(description: "decode \(name)")
            expectations[name] = result
            return result
        }
        func load(_ name: String) async -> String? {
            await withCheckedContinuation {
                starts.append(name)
                pending[name] = $0
                expectations.removeValue(forKey: name)?.fulfill()
            }
        }
        func finish(_ name: String, success: Bool = true) {
            pending.removeValue(forKey: name)?.resume(returning: success ? name : nil)
        }
    }

    private func waitUntilIdle(_ queue: AssetPreparationQueue<String>) async {
        let deadline = Date().addingTimeInterval(2)
        while queue.inFlight != nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(queue.inFlight)
    }

    func testGlobalQueueBoundAndOneDecoderAcrossDemandChanges() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(limits: .init(queued: 2, cached: 1, cacheCost: 10),
                                                  cost: { _ in 1 }, load: loader.load)
        let first = loader.expect("a")
        queue.setDemand(["a", "b", "c", "d", "e"], active: true)
        await fulfillment(of: [first], timeout: 2)
        queue.setDemand(["a", "b", "c", "d", "e"], active: true)
        XCTAssertLessThanOrEqual(queue.queued.count, 2)
        XCTAssertEqual(loader.starts, ["a"])
        let replacement = loader.expect("z")
        queue.setDemand(["z"], active: true)
        XCTAssertEqual(queue.queued, ["z"])
        loader.finish("a")
        await fulfillment(of: [replacement], timeout: 2)
        XCTAssertFalse(queue.contains("a"), "obsolete result must not be retained")
        loader.finish("z")
        await waitUntilIdle(queue)
        XCTAssertEqual(loader.starts, ["a", "z"])
        XCTAssertEqual(queue.cachedNames, ["z"])
    }

    func testHiddenCameraCancelsQueuedWorkAndRejectsLatePublicationThenResumes() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(cost: { _ in 1 }, load: loader.load)
        var completions: [String] = []
        queue.onCompletion = { name, _ in completions.append(name) }
        let first = loader.expect("a")
        queue.setDemand(["a", "b"], active: true)
        await fulfillment(of: [first], timeout: 2)
        queue.setDemand(["a", "b"], active: false)
        XCTAssertTrue(queue.queued.isEmpty)
        loader.finish("a")
        await waitUntilIdle(queue)
        XCTAssertEqual(loader.starts, ["a"])
        XCTAssertTrue(completions.isEmpty)
        XCTAssertTrue(queue.cachedNames.isEmpty)
        let resumed = loader.expect("b")
        queue.setDemand(["b"], active: true)
        await fulfillment(of: [resumed], timeout: 2)
        loader.finish("b")
        await waitUntilIdle(queue)
        XCTAssertEqual(completions, ["b"])
    }

    func testCacheEvictionAndMemoryPressureDoNotRepeatedlyDecodeLiveContent() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(limits: .init(queued: 2, cached: 2, cacheCost: 3),
                                                  cost: { _ in 2 }, load: loader.load)
        let first = loader.expect("a")
        let second = loader.expect("b")
        queue.setDemand(["a", "b"], active: true)
        await fulfillment(of: [first], timeout: 2)
        loader.finish("a")
        await fulfillment(of: [second], timeout: 2)
        loader.finish("b")
        await waitUntilIdle(queue)
        XCTAssertEqual(queue.cachedNames, ["b"])
        XCTAssertLessThanOrEqual(queue.cachedCost, 3)
        queue.releaseCachedTemplates()
        queue.setDemand(["a", "b"], active: true)
        XCTAssertNil(queue.inFlight)
        XCTAssertTrue(queue.cachedNames.isEmpty)
        let neededAgain = loader.expect("a")
        queue.request("a")
        queue.request("a")
        await fulfillment(of: [neededAgain], timeout: 2)
        loader.finish("a")
        await waitUntilIdle(queue)
        XCTAssertEqual(loader.starts, ["a", "b", "a"])
    }

    func testOversizedTemplateOnlyLivesDuringSynchronousDelivery() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(limits: .init(queued: 1, cached: 1, cacheCost: 5),
                                                  cost: { _ in 100 }, load: loader.load)
        var clone: String?
        queue.onCompletion = { name, success in
            XCTAssertTrue(success)
            clone = queue.value(for: name)
            XCTAssertTrue(queue.contains(name))
            XCTAssertEqual(queue.cachedCost, 0)
            queue.request(name) // a reentrant consumer must not schedule twice
        }
        let started = loader.expect("large")
        queue.request("large")
        await fulfillment(of: [started], timeout: 2)
        loader.finish("large")
        await waitUntilIdle(queue)
        XCTAssertEqual(clone, "large")
        XCTAssertFalse(queue.contains("large"))
        queue.setDemand(["large"], active: true)
        XCTAssertNil(queue.inFlight)
        XCTAssertEqual(loader.starts, ["large"])
        queue.onCompletion = nil
    }

    func testFailedAssetRemainsNegativelyCachedAcrossHideAndRetry() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(cost: { _ in 1 }, load: loader.load)
        var failures = 0
        queue.onCompletion = { _, success in if !success { failures += 1 } }
        let first = loader.expect("bad")
        queue.request("bad")
        await fulfillment(of: [first], timeout: 2)
        loader.finish("bad", success: false)
        await waitUntilIdle(queue)
        queue.setDemand([], active: false)
        queue.setDemand(["bad"], active: true)
        queue.request("bad")
        XCTAssertNil(queue.inFlight)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(loader.starts, ["bad"])
    }

    func testManualRetryWhileHiddenWaitsForActiveDemand() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(cost: { _ in 1 }, load: loader.load)
        var completions: [(String, Bool)] = []
        queue.onCompletion = { completions.append(($0, $1)) }
        let first = loader.expect("bad")
        queue.setDemand(["bad"], active: true)
        await fulfillment(of: [first], timeout: 2)
        loader.finish("bad", success: false)
        await waitUntilIdle(queue)
        XCTAssertTrue(queue.failed.contains("bad"))

        queue.setDemand([], active: false)
        XCTAssertFalse(queue.retryFailed("unrelated"))
        XCTAssertTrue(queue.retryFailed("bad"))
        XCTAssertFalse(queue.retryFailed("bad"), "one button press arms one retry")
        XCTAssertEqual(loader.starts, ["bad"])
        XCTAssertNil(queue.inFlight)

        let retried = loader.expect("bad")
        queue.setDemand(["bad"], active: true)
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertFalse(queue.retryFailed("bad"), "an active decoder cannot be duplicated")
        loader.finish("bad")
        await waitUntilIdle(queue)
        XCTAssertEqual(loader.starts, ["bad", "bad"])
        XCTAssertEqual(completions.map { $0.1 }, [false, true])
        XCTAssertFalse(queue.failed.contains("bad"))
    }

    func testSecondFailureRestoresNegativeCacheWithoutAutomaticLoop() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(cost: { _ in 1 }, load: loader.load)
        let first = loader.expect("bad")
        queue.setDemand(["bad"], active: true)
        await fulfillment(of: [first], timeout: 2)
        loader.finish("bad", success: false)
        await waitUntilIdle(queue)

        let retried = loader.expect("bad")
        XCTAssertTrue(queue.retryFailed("bad"))
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertFalse(queue.retryFailed("bad"))
        loader.finish("bad", success: false)
        await waitUntilIdle(queue)
        XCTAssertTrue(queue.failed.contains("bad"))
        queue.setDemand(["bad"], active: true)
        queue.request("bad")
        XCTAssertNil(queue.inFlight)
        XCTAssertTrue(queue.queued.isEmpty)
        XCTAssertEqual(loader.starts, ["bad", "bad"])
    }

    func testRetryQueuesBehindAnotherDecoder() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(limits: .init(queued: 1, cached: 1,
                                                                 cacheCost: 10),
                                                  cost: { _ in 1 }, load: loader.load)
        let first = loader.expect("bad")
        queue.setDemand(["bad"], active: true)
        await fulfillment(of: [first], timeout: 2)
        loader.finish("bad", success: false)
        await waitUntilIdle(queue)

        let other = loader.expect("other")
        queue.setDemand(["bad", "other"], active: true)
        await fulfillment(of: [other], timeout: 2)
        XCTAssertTrue(queue.retryFailed("bad"))
        XCTAssertEqual(queue.inFlight, "other")
        XCTAssertEqual(queue.queued, ["bad"])
        XCTAssertEqual(loader.starts, ["bad", "other"])

        let retry = loader.expect("bad")
        loader.finish("other")
        await fulfillment(of: [retry], timeout: 2)
        XCTAssertEqual(loader.starts, ["bad", "other", "bad"])
        loader.finish("bad")
        await waitUntilIdle(queue)
    }

    func testSelectedHeroMovesAheadOfFullQueueWithoutStartingSecondDecoder() async {
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(limits: .init(queued: 2, cached: 2, cacheCost: 20),
                                                  cost: { _ in 1 }, load: loader.load)
        let first = loader.expect("a")
        queue.setDemand(["a", "b", "c", "hero"], active: true)
        await fulfillment(of: [first], timeout: 2)
        queue.setDemand(["a", "b", "c", "hero"], active: true, priority: "hero")
        XCTAssertEqual(queue.queued.first, "hero")
        XCTAssertLessThanOrEqual(queue.queued.count, 2)
        XCTAssertEqual(loader.starts, ["a"])
        let hero = loader.expect("hero")
        loader.finish("a")
        await fulfillment(of: [hero], timeout: 2)
        queue.setDemand(["hero"], active: true, priority: "hero")
        loader.finish("hero")
        await waitUntilIdle(queue)
        XCTAssertEqual(loader.starts, ["a", "hero"])
    }
}
