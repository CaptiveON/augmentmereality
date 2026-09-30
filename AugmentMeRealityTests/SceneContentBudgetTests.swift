import XCTest
@testable import AugmentMeReality

@MainActor
final class SceneContentBudgetTests: XCTestCase {
    private func candidate(
        _ number: Int, distance: Double, cost: Int = 2,
        sourceBytes: Int = 0, selected: Bool = false, editing: Bool = false
    ) -> SceneContentBudget.Candidate {
        SceneContentBudget.Candidate(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
            distance: distance, cost: cost, sourceBytes: sourceBytes,
            selected: selected, editing: editing
        )
    }

    func testDenseRoomAndGeoCatalogSharesOneHardSceneBudget() {
        // IDs stand for one room catalog and one geo catalog. A selected room
        // item and an edited geo item compete in the same scene allocation.
        let candidates = (1...500).map { number in
            candidate(number, distance: Double(number),
                      selected: number == 450, editing: number == 499)
        }
        let result = SceneContentBudget.select(candidates)
        XCTAssertEqual(result.full.count, 8)
        XCTAssertEqual(result.cues.count, 24)
        XCTAssertEqual(result.visible.count, 32)
        XCTAssertEqual(result.unloadedCount, 468)
        XCTAssertTrue(result.full.contains(candidates[449].id))
        XCTAssertTrue(result.full.contains(candidates[498].id))
        XCTAssertTrue(result.full.isDisjoint(with: result.cues))
    }

    func testIncumbentHysteresisAvoidsNearbyChurnButAllowsClearerApproach() {
        let fixed = (1...7).map { candidate($0, distance: Double($0)) }
        let incumbent = candidate(8, distance: 9.8)
        let challenger = candidate(9, distance: 9.6)
        let old = SceneContentBudget.Selection(full: Set((fixed + [incumbent]).map(\.id)),
                                               cues: [], totalCandidates: 9)
        let stable = SceneContentBudget.select(fixed + [incumbent, challenger], previous: old)
        XCTAssertTrue(stable.full.contains(incumbent.id))
        XCTAssertFalse(stable.full.contains(challenger.id))

        let approached = candidate(9, distance: 7.0)
        let moved = SceneContentBudget.select(fixed + [incumbent, approached], previous: stable)
        XCTAssertTrue(moved.full.contains(approached.id))
        XCTAssertFalse(moved.full.contains(incumbent.id))
    }

    func testUnknownAndOversizedAnimatedSourcesCannotBypassFullBudget() {
        let mib = 1_024 * 1_024
        let selectedUnknown = candidate(1, distance: 1, cost: 4, sourceBytes: .max, selected: true)
        let tooLarge = candidate(2, distance: 2, cost: 4, sourceBytes: 33 * mib)
        let heavy = (3...5).map { candidate($0, distance: Double($0), cost: 4, sourceBytes: 31 * mib) }
        let result = SceneContentBudget.select([selectedUnknown, tooLarge] + heavy)
        XCTAssertFalse(result.full.contains(selectedUnknown.id))
        XCTAssertFalse(result.full.contains(tooLarge.id))
        XCTAssertTrue(result.cues.contains(selectedUnknown.id))
        XCTAssertEqual(result.full.count, 2, "64 MiB aggregate admits only two 31 MiB clones")
    }

    func testPressureShrinksAdmissionAndHiddenCameraDoesNotStartNewContent() {
        let catalog = (1...40).map { candidate($0, distance: Double($0), selected: $0 == 30) }
        let normal = SceneContentBudget.select(catalog)
        let hidden = SceneContentBudget.select(catalog + [candidate(41, distance: 0, selected: true)],
                                               previous: normal, pressure: .hidden)
        XCTAssertEqual(hidden.visible, normal.visible)
        let hiddenPressure = SceneContentBudget.select(
            catalog + [candidate(41, distance: 0, selected: true)],
            previous: normal, pressure: .hiddenPressure
        )
        XCTAssertEqual(hiddenPressure.full.count, 1)
        XCTAssertEqual(hiddenPressure.cues.count, 6)
        XCTAssertTrue(hiddenPressure.visible.isSubset(of: normal.visible))
        XCTAssertTrue(hiddenPressure.full.isSubset(of: normal.full))
        XCTAssertEqual(hiddenPressure.unloadedCount, 34)
        let serious = SceneContentBudget.select(catalog, previous: normal, pressure: .serious)
        XCTAssertEqual(serious.full.count, 4)
        XCTAssertEqual(serious.cues.count, 12)
        XCTAssertTrue(serious.full.contains(catalog[29].id))
        let critical = SceneContentBudget.select(catalog, previous: serious, pressure: .critical)
        XCTAssertEqual(critical.full.count, 1)
        XCTAssertEqual(critical.cues.count, 6)
        XCTAssertTrue(critical.full.contains(catalog[29].id))
    }

    func testLateSharedAssetCallbackCannotPromoteDemotedCue() {
        var first = GeoDrop(content: .animated, message: "first", latitude: 0,
                            longitude: 0, heightAboveGround: 0, scale: 1,
                            colorHex: "#FFFFFF", createdBy: "test")
        first.assetName = "shared"
        var second = first
        second.id = UUID()

        // Both models requested one shared decode. Thermal pressure demotes
        // one to a cue before that in-flight decoder finishes.
        let candidates = [
            SceneContentBudget.Candidate(id: first.id, distance: 2, cost: 4,
                                         sourceBytes: 1, selected: true, editing: false),
            SceneContentBudget.Candidate(id: second.id, distance: 3, cost: 4,
                                         sourceBytes: 1, selected: false, editing: false)
        ]
        let original = SceneContentBudget.select(candidates)
        XCTAssertEqual(original.full, [first.id, second.id])
        let demoted = SceneContentBudget.select(candidates, previous: original,
                                                pressure: .critical)
        XCTAssertEqual(demoted.full, [first.id])
        XCTAssertEqual(demoted.cues, [second.id])
        let replacements = GeoARSessionManager.pendingAssetReplacementIDs(
            name: "shared", drops: [first.id: first, second.id: second],
            fullContentIDs: demoted.full, readyContentIDs: []
        )
        XCTAssertEqual(replacements, [first.id])
    }

    func testRapidSelectionChangesDoNotLaunchObsoleteQueuedAssets() async {
        final class Loader {
            var starts: [String] = []
            var pending: [String: CheckedContinuation<String?, Never>] = [:]
            func load(_ name: String) async -> String? {
                await withCheckedContinuation { continuation in
                    starts.append(name)
                    pending[name] = continuation
                }
            }
            func finish(_ name: String) { pending.removeValue(forKey: name)?.resume(returning: name) }
        }
        let loader = Loader()
        let queue = AssetPreparationQueue<String>(limits: .init(queued: 2, cached: 1, cacheCost: 1),
                                                  cost: { _ in 1 }, load: loader.load)
        let ids = (1...80).map { candidate($0, distance: Double($0), cost: 4) }
        var selection = SceneContentBudget.select(ids)
        queue.setDemand([ids[0].id.uuidString], active: true)
        let initialDeadline = Date().addingTimeInterval(2)
        while loader.starts.isEmpty && Date() < initialDeadline { await Task.yield() }
        guard let first = loader.starts.first else {
            XCTFail("initial asset never entered the in-flight slot")
            return
        }
        for chosen in 50...80 {
            let changed = (1...80).map { number in
                candidate(number, distance: Double(number), cost: 4,
                          selected: number == chosen)
            }
            selection = SceneContentBudget.select(changed, previous: selection)
            XCTAssertTrue(selection.full.contains(ids[chosen - 1].id))
            queue.setDemand([ids[chosen - 1].id.uuidString], active: true,
                            priority: ids[chosen - 1].id.uuidString)
            XCTAssertLessThanOrEqual(queue.queued.count, 2)
        }
        loader.finish(first)
        let deadline = Date().addingTimeInterval(2)
        while loader.starts.count < 2 && Date() < deadline { await Task.yield() }
        guard loader.starts.count == 2 else {
            XCTFail("latest selected asset did not start after the old in-flight job")
            return
        }
        XCTAssertEqual(loader.starts[1], ids[79].id.uuidString)
        XCTAssertFalse(queue.contains(first))
        loader.finish(loader.starts[1])
        queue.setDemand([], active: false)
    }
}
