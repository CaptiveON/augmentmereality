import CoreLocation
import XCTest
@testable import AugmentMeReality

final class LocalDropStoreTests: XCTestCase {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("drops-\(UUID().uuidString).json")
    }

    private func siblings(of url: URL, prefix: String) -> [String] {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return all.filter { $0.hasPrefix("\(name).\(prefix)") }
    }

    func testSaveLoadDelete() async throws {
        let url = temporaryFile()
        let store = LocalDropStore(fileURL: url)

        var drop = GeoDrop()
        drop.message = "field test"
        try await store.save(drop)

        var loaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(loaded.map(\.id), [drop.id])

        drop.message = "edited"
        try await store.save(drop)
        loaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(loaded.count, 1, "same id must upsert, not duplicate")
        XCTAssertEqual(loaded.first?.message, "edited")

        try await store.delete(drop)
        loaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testCorruptCacheIsQuarantinedNotFatal() async throws {
        // Failure audit (v0.8): a corrupt cache must never dead-end a field session.
        let url = temporaryFile()
        try Data("this is not json {{{".utf8).write(to: url)

        let store = LocalDropStore(fileURL: url)
        let loaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertTrue(loaded.isEmpty, "corrupt file must yield empty, not throw forever")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "corrupt file must be moved aside"
        )
        XCTAssertEqual(
            siblings(of: url, prefix: "corrupt-").count, 1,
            "corrupt file must be preserved for diagnosis"
        )
        let warning = await store.lastLoadReadWarning()
        XCTAssertNotNil(warning, "whole-file corruption must not be silent")

        // And the store must be fully usable afterwards.
        try await store.save(GeoDrop())
        let after = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(after.count, 1)
    }

    /// Round 4 (counsel sync-2/flows-2): the destructive verdict is journaled —
    /// the very next load (which sees no file, because the quarantine moved it)
    /// must NOT report "clean". The launch sequence loads twice within a second.
    func testWholeFileQuarantineWarningSurvivesSubsequentLoads() async throws {
        let url = temporaryFile()
        try Data("not json at all".utf8).write(to: url)
        let store = LocalDropStore(fileURL: url)

        _ = try await store.loadDrops(near: nil, radius: 0) // quarantines
        let first = await store.lastLoadReadWarning()
        XCTAssertNotNil(first)

        _ = try await store.loadDrops(near: nil, radius: 0) // file now absent
        let second = await store.lastLoadReadWarning()
        XCTAssertNotNil(second, "the incident must survive the next (empty) load")

        // Round 10 (counsel own-1): a clean — even non-empty — library does
        // NOT resolve the incident: the destroyed rows don't come back when
        // the file reads clean again. Only the user's acknowledgement does.
        try await store.save(GeoDrop())
        _ = try await store.loadDrops(near: nil, radius: 0)
        let afterCleanLoad = await store.lastLoadReadWarning()
        XCTAssertNotNil(afterCleanLoad, "a clean load must never auto-expire the incident")

        await store.acknowledgeIncident()
        let afterAck = await store.lastLoadReadWarning()
        XCTAssertNil(afterAck, "acknowledgement retires the incident")
    }

    func testOneBadRowDoesNotWipeLibrary() async throws {
        // Wave C (counsel SWE-9): rows decode individually; a type mismatch in
        // one row must never empty the library.
        let url = temporaryFile()
        var good = GeoDrop()
        good.message = "survivor"
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let bad = "{\"id\":\"\(UUID().uuidString)\",\"heightAboveGround\":\"3\"}"
        try Data("[\(goodJSON),\(bad)]".utf8).write(to: url)

        let store = LocalDropStore(fileURL: url)
        let loaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(loaded.map(\.id), [good.id], "the good row must survive")

        XCTAssertEqual(
            siblings(of: url, prefix: "unreadable-").count, 1,
            "original file must be kept before a save rewrites it"
        )
        let warning = await store.lastLoadReadWarning()
        XCTAssertTrue(warning?.contains("1 saved drop") == true)

        // Round 2 (C6/C14): reloading the SAME bad content must not accumulate
        // sidecars (content-digest naming dedupes).
        _ = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(siblings(of: url, prefix: "unreadable-").count, 1)

        // Round 10 (counsel own-1): the journaled incident outlives a clean
        // rewrite — the skipped row's data is still gone; the user resolves it.
        try await store.save(good)
        _ = try await store.loadDrops(near: nil, radius: 0)
        let afterCleanLoad = await store.lastLoadReadWarning()
        XCTAssertNotNil(afterCleanLoad, "a clean rewrite must not auto-expire the incident")
        await store.acknowledgeIncident()
        let afterHeal = await store.lastLoadReadWarning()
        XCTAssertNil(afterHeal, "acknowledgement retires the incident")
    }

    /// Round 12 (counsel SURF-lens-5): acknowledging a skipped-rows incident
    /// ACCEPTS the loss — the store rewrites itself clean (originals stay in
    /// the sidecar) so the next load cannot re-journal the same incident and
    /// Dismiss is never a no-op.
    func testAcknowledgingSkippedRowsAcceptsTheLossAndStopsRejournaling() async throws {
        let url = temporaryFile()
        var good = GeoDrop()
        good.message = "survivor"
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let bad = "{\"id\":\"\(UUID().uuidString)\",\"heightAboveGround\":\"3\"}"
        try Data("[\(goodJSON),\(bad)]".utf8).write(to: url)

        let store = LocalDropStore(fileURL: url)
        _ = try await store.loadDrops(near: nil, radius: 0) // journals the incident
        let beforeAck = await store.lastLoadReadWarning()
        XCTAssertNotNil(beforeAck)

        await store.acknowledgeIncident()
        let afterAck = await store.lastLoadReadWarning()
        XCTAssertNil(afterAck)

        let reloaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(reloaded.map(\.id), [good.id])
        let afterReload = await store.lastLoadReadWarning()
        XCTAssertNil(afterReload, "the accepted loss must not re-journal on the next load")
        XCTAssertEqual(
            siblings(of: url, prefix: "unreadable-").count, 1,
            "the original bytes stay preserved in the sidecar"
        )
    }

    func testFailedWarningAcknowledgementKeepsWarningAndOriginalBytes() async throws {
        let url = temporaryFile()
        let bad = Data("[{\"id\":\"\(UUID().uuidString)\",\"heightAboveGround\":\"bad\"}]".utf8)
        try bad.write(to: url)
        let store = LocalDropStore(fileURL: url)
        _ = try await store.loadDrops(near: nil, radius: 0)
        try FileManager.default.createDirectory(
            at: url.appendingPathExtension("ackdigest"), withIntermediateDirectories: false
        )

        await store.acknowledgeIncident()

        let warning = await store.lastLoadReadWarning()
        XCTAssertTrue(warning?.contains("Couldn't save") == true)
        XCTAssertEqual(try Data(contentsOf: url), bad)
        XCTAssertEqual(siblings(of: url, prefix: "unreadable-").count, 1)
    }

    func testSaveCannotDiscardUnreadableRowsWhenRecoveryCopyIsUnavailable() async throws {
        let url = temporaryFile()
        let bad = Data("[{\"id\":\"\(UUID().uuidString)\",\"heightAboveGround\":\"bad\"}]".utf8)
        try bad.write(to: url)
        let store = LocalDropStore(fileURL: url)
        _ = try await store.loadDrops(near: nil, radius: 0)
        let sidecar = try XCTUnwrap(siblings(of: url, prefix: "unreadable-").first)
        let sidecarURL = url.deletingLastPathComponent().appendingPathComponent(sidecar)
        try FileManager.default.removeItem(at: sidecarURL)
        try FileManager.default.createDirectory(at: sidecarURL, withIntermediateDirectories: false)

        do {
            try await store.save(GeoDrop())
            XCTFail("the original has no recovery copy, so rewriting must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testDeleteCannotDiscardUnreadableRowsWhenRecoveryCopyIsUnavailable() async throws {
        let url = temporaryFile()
        var good = GeoDrop()
        good.message = "survivor"
        let encodedGood = try JSONEncoder().encode(good)
        let goodJSON = try XCTUnwrap(String(data: encodedGood, encoding: .utf8))
        let damaged = Data(
            "[\(goodJSON),{\"id\":\"\(UUID().uuidString)\",\"heightAboveGround\":\"bad\"}]".utf8
        )
        try damaged.write(to: url)
        let store = LocalDropStore(fileURL: url)
        let loaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(loaded.map(\.id), [good.id])
        let sidecar = try XCTUnwrap(siblings(of: url, prefix: "unreadable-").first)
        let sidecarURL = url.deletingLastPathComponent().appendingPathComponent(sidecar)
        try FileManager.default.removeItem(at: sidecarURL)
        try FileManager.default.createDirectory(at: sidecarURL, withIntermediateDirectories: false)

        do {
            try await store.delete(good)
            XCTFail("deleting the readable row must not discard an unreadable row without a recovery copy")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testConcurrentSavesAllSurvive() async throws {
        // Wave C (counsel SWE-8): the store is an actor — N overlapping saves
        // from independent tasks must all land.
        let url = temporaryFile()
        let store = LocalDropStore(fileURL: url)
        let drops = (0..<8).map { index -> GeoDrop in
            var drop = GeoDrop()
            drop.message = "drop \(index)"
            return drop
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for drop in drops {
                group.addTask { try await store.save(drop) }
            }
            try await group.waitForAll()
        }
        let loaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(
            Set(loaded.map(\.id)), Set(drops.map(\.id)),
            "every concurrent save must survive — no lost writes"
        )
    }

    func testConcurrentSavesAndDeletesDoNotResurrectRemovedRows() async throws {
        let store = LocalDropStore(fileURL: temporaryFile())
        let removed = (0..<8).map { index -> GeoDrop in
            var drop = GeoDrop()
            drop.message = "removed \(index)"
            return drop
        }
        let added = (0..<8).map { index -> GeoDrop in
            var drop = GeoDrop()
            drop.message = "added \(index)"
            return drop
        }
        for drop in removed { try await store.save(drop) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for drop in removed {
                group.addTask { try await store.delete(drop) }
            }
            for drop in added {
                group.addTask { try await store.save(drop) }
            }
            try await group.waitForAll()
        }

        let loaded = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(Set(loaded.map(\.id)), Set(added.map(\.id)))
    }
}

@MainActor
final class DropLibraryTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        // Round 4 (counsel concurrency-5): tests own their persistence domains
        // outright — never the shipping app's UserDefaults.standard.
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "DropLibraryTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeLibrary(
        local: DropStore? = nil, cloud: DropStore? = nil, defaults: UserDefaults? = nil,
        absenceProbeTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> DropLibrary {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString).json")
        return DropLibrary(
            localStore: local ?? LocalDropStore(fileURL: url),
            cloudStore: cloud,
            defaults: defaults ?? makeDefaults(),
            absenceProbeTime: absenceProbeTime
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testAddRemoveAndGeoRadiusFilter() async throws {
        let library = makeLibrary()

        var near = GeoDrop()
        near.latitude = 37.0
        near.longitude = -122.0
        var far = GeoDrop()
        far.latitude = 37.1 // ~11 km north
        far.longitude = -122.0

        try await library.add(near)
        try await library.add(far)
        XCTAssertEqual(library.drops.count, 2)

        let viewer = CLLocation(latitude: 37.0, longitude: -122.0)
        let visible = library.drops(near: viewer, within: 2_000)
        XCTAssertEqual(visible.map(\.id), [near.id], "11 km drop must not render at 2 km radius")

        try await library.remove(near)
        XCTAssertEqual(library.drops.count, 1)

        await library.refresh(near: nil)
        XCTAssertEqual(library.drops.map(\.id), [far.id])
    }

    /// Round 4 (counsel concurrency-5): the library's persisted bookkeeping is
    /// scoped to the injected defaults suite — the shipping domain stays clean.
    func testLibraryPersistenceIsScopedToAnInjectedDefaultsSuite() async throws {
        let defaults = makeDefaults()
        let cloud = GatedCloudStore()
        await cloud.setFailAllSaves(with: DropStoreError.notSignedIn)
        let library = makeLibrary(cloud: cloud, defaults: defaults)

        let drop = GeoDrop()
        try await library.add(drop)
        try await waitUntil { await cloud.saveAttempts > 0 }

        let inSuite = defaults.stringArray(forKey: "pendingSyncDropIDs") ?? []
        XCTAssertTrue(inSuite.contains(drop.id.uuidString))
        let inStandard = UserDefaults.standard.stringArray(forKey: "pendingSyncDropIDs") ?? []
        XCTAssertFalse(
            inStandard.contains(drop.id.uuidString),
            "tests must never write into the shipping app's outbox"
        )
    }

    func testPendingSyncClearsOnlyOnAcknowledgedWrite() async throws {
        let cloud = GatedCloudStore()
        await cloud.setFailAllSaves(with: DropStoreError.notSignedIn)
        let library = makeLibrary(cloud: cloud)

        let drop = GeoDrop()
        try await library.add(drop)
        try await waitUntil { await cloud.saveAttempts > 0 }
        XCTAssertTrue(library.pendingSyncIDs.contains(drop.id))
        XCTAssertNil(library.lastSyncError)

        await cloud.setFailAllSaves(with: nil)
        library.reconcileCloud()
        try await waitUntil { !library.pendingSyncIDs.contains(drop.id) }
        let saved = await cloud.saved
        XCTAssertEqual(saved, [drop.id])
    }

    /// A retryable cloud failure is visible per-drop AND stays pending.
    func testCloudFailureIsVisibleAndStaysPending() async throws {
        let cloud = GatedCloudStore()
        await cloud.setFailAllSaves(with: NSError(
            domain: "test", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        ))
        let library = makeLibrary(cloud: cloud)

        let drop = GeoDrop()
        try await library.add(drop)
        try await waitUntil { library.syncFailureReasons[drop.id] != nil }
        XCTAssertTrue(library.pendingSyncIDs.contains(drop.id))
        XCTAssertTrue(library.syncFailureReasons[drop.id]?.contains("permission denied") == true)
    }

    /// Round 4 (counsel sync-1): a TERMINAL failure outranks "Synced" — it
    /// survives a sibling's success and a successful refresh, in durable
    /// per-drop state, never a clobberable shared string.
    func testTerminalOwnerMismatchStaysVisibleAfterAnotherDropSyncs() async throws {
        let cloud = GatedCloudStore()
        let terminal = GeoDrop()
        let healthy = GeoDrop()
        await cloud.setFailSave(DropStoreError.ownedByAnotherAccount, for: terminal.id)
        let library = makeLibrary(cloud: cloud)

        try await library.add(terminal)
        try await library.add(healthy)
        try await waitUntil {
            library.terminalSyncFailureIDs.contains(terminal.id)
                && !library.pendingSyncIDs.contains(healthy.id)
        }

        await library.refresh(near: nil) // successful (empty) cloud read
        XCTAssertTrue(
            library.terminalSyncFailureIDs.contains(terminal.id),
            "a drop that can never sync must stay visibly failed after ANY success"
        )
        XCTAssertFalse(
            library.pendingSyncIDs.isEmpty && library.terminalSyncFailureIDs.isEmpty,
            "the library must never present as fully synced while a terminal failure exists"
        )
    }

    /// Round 2 C2/C22, pinned in round 4 (counsel concurrency-6): a superseded
    /// task — parked mid-flight exactly like production parks offline — must
    /// not clear the pending flag its successor owns when it finally resumes.
    func testSupersededSyncTaskCannotClearPendingWhenItFinallyResumes() async throws {
        let cloud = GatedCloudStore()
        await cloud.setGateSaves(true)
        let library = makeLibrary(cloud: cloud)

        var drop = GeoDrop()
        drop.message = "v1"
        try await library.add(drop) // task 1 parks inside save
        try await waitUntil { await cloud.parkedSaveCount == 1 }

        drop.message = "v2"
        try await library.update(drop) // supersedes: task 2 parks
        try await waitUntil { await cloud.parkedSaveCount == 2 }

        await cloud.releaseOneSave() // task 1 (stale generation) completes
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(
            library.pendingSyncIDs.contains(drop.id),
            "a stale generation's ack must not clear pending for the newer write"
        )

        await cloud.releaseAllSaves() // task 2 (current) completes
        try await waitUntil { !library.pendingSyncIDs.contains(drop.id) }
    }

    /// Round 4 (counsel sync-4/flows-1): a mutation during an in-flight refresh
    /// supersedes it — the stale snapshot must never be published.
    func testDeleteDuringRefreshIsNotResurrectedByThePublish() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)

        let drop = GeoDrop()
        try await library.add(drop)
        await cloud.setLoadResult([drop])
        await cloud.setGateLoads(true)

        let refreshTask = Task { await library.refresh(near: nil) }
        try await waitUntil { await cloud.parkedLoadCount == 1 }

        try await library.remove(drop) // bumps the refresh generation
        await cloud.releaseAllLoads()
        await refreshTask.value

        XCTAssertFalse(
            library.drops.contains { $0.id == drop.id },
            "a superseded refresh must not resurrect a deleted drop"
        )
    }

    /// Round 4 (counsel sync-3): a refresh that cannot read local truth aborts
    /// — it neither hides the failure nor merges/publishes anything.
    func testFailingLocalReadNeitherHidesTheFailureNorClearsState() async throws {
        let local = FlakyLocalStore()
        let cloud = GatedCloudStore()
        await cloud.setFailAllSaves(with: DropStoreError.notSignedIn)
        let library = makeLibrary(local: local, cloud: cloud)

        let drop = GeoDrop()
        try await library.add(drop)
        try await waitUntil { await cloud.saveAttempts > 0 }

        await local.setThrowOnLoad(true)
        await library.refresh(near: nil)

        XCTAssertNotNil(library.localReadWarning, "an unreadable store must be reported")
        XCTAssertTrue(library.drops.contains { $0.id == drop.id }, "in-memory state survives")
        XCTAssertTrue(library.pendingSyncIDs.contains(drop.id), "pending survives an aborted pass")
    }

    /// Round 4 (counsel flows-4): a REFUSED cloud delete keeps its tombstone —
    /// the deleted drop must never resurrect from a cloud read.
    func testFailedCloudDeleteNeverResurrectsTheDropOnRefresh() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)

        let drop = GeoDrop()
        try await library.add(drop)
        await cloud.setFailDelete(NSError(
            domain: "test", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "delete refused"]
        ), for: drop.id)
        await cloud.setLoadResult([drop]) // the cloud still has the row

        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }
        XCTAssertTrue(library.pendingDeleteIDs.contains(drop.id), "refused delete keeps the tombstone")

        await library.refresh(near: nil)
        XCTAssertFalse(
            library.drops.contains { $0.id == drop.id },
            "the tombstone must suppress resurrection from the cloud copy"
        )
    }

    /// Round 6 (counsel arui-4 + flows-5): the reap keys on the machine-checkable
    /// outcome. An ABSENT file proves nothing and must never reap (that was the
    /// round-2 outbox wipe through a side door); a CLEAN load — even of zero
    /// rows — proves absence and reaps.
    func testOrphanedPendingIDReapedOnlyAfterProvablyCleanLoad() async throws {
        let defaults = makeDefaults()
        let ghost = UUID()
        defaults.set([ghost.uuidString], forKey: "pendingSyncDropIDs")

        // Case 1: absent store file — outbox must SURVIVE.
        let absentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        let library1 = DropLibrary(
            localStore: LocalDropStore(fileURL: absentURL), cloudStore: nil,
            defaults: defaults
        )
        await library1.refresh(near: nil)
        XCTAssertTrue(
            library1.pendingSyncIDs.contains(ghost),
            "an absent file is not proof — the outbox must survive it"
        )

        // Case 2: a clean (empty-array) load — provably gone, reaped.
        let cleanURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clean-\(UUID().uuidString).json")
        try Data("[]".utf8).write(to: cleanURL)
        let library2 = DropLibrary(
            localStore: LocalDropStore(fileURL: cleanURL), cloudStore: nil,
            defaults: defaults
        )
        XCTAssertTrue(library2.pendingSyncIDs.contains(ghost))
        await library2.refresh(near: nil)
        XCTAssertFalse(
            library2.pendingSyncIDs.contains(ghost),
            "a clean load proves absence — the orphan is reaped"
        )
    }

    /// Round 6 (counsel root cause): an unanswered ack ENDS the task, keeps
    /// the drop pending with no error, and leaves the registry free so the
    /// next reconcile genuinely retries.
    func testAckTimeoutKeepsPendingSilentlyAndAllowsRetry() async throws {
        let cloud = GatedCloudStore()
        await cloud.setFailAllSaves(with: DropStoreError.ackTimedOut)
        let library = makeLibrary(cloud: cloud)

        let drop = GeoDrop()
        try await library.add(drop)
        try await waitUntil { await cloud.saveAttempts == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(library.pendingSyncIDs.contains(drop.id))
        XCTAssertNil(library.syncFailureReasons[drop.id], "queued is not an error")

        await cloud.setFailAllSaves(with: nil)
        library.reconcileCloud()
        try await waitUntil { !library.pendingSyncIDs.contains(drop.id) }
        let attempts = await cloud.saveAttempts
        XCTAssertEqual(attempts, 2, "the retry actually ran — no stuck registry entry")
    }

    /// Round 6 (counsel critical 2), predicate corrected in round 8 (counsel
    /// B3/state-1): a tombstone retires ONLY on a per-document, SERVER-sourced
    /// absence — verdicts end with their condition, but the condition's
    /// disappearance must be proven by the server, never inferred from a
    /// query the SDK could have served from cache.
    func testTombstoneRetiredOnlyByServerConfirmedAbsence() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        let drop = GeoDrop()
        try await library.add(drop)
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: drop.id)

        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }
        XCTAssertTrue(library.pendingDeleteIDs.contains(drop.id), "unanswered delete keeps the tombstone")

        // The uid-scoped query no longer contains the row — exactly what an
        // OFFLINE refresh sees via latency compensation after its own delete,
        // and what any refresh sees after a uid change. NOT retirement-grade.
        await cloud.setLoadResult([])
        await library.refresh(near: nil)
        XCTAssertTrue(
            library.pendingDeleteIDs.contains(drop.id),
            "absence from a narrowed query must never retire a tombstone (round-7 state-1/state-2)"
        )

        // The SERVER answers per-document: the row is gone. Now it retires.
        await cloud.setServerAbsent([drop.id])
        await library.refresh(near: nil)
        XCTAssertFalse(
            library.pendingDeleteIDs.contains(drop.id),
            "server-confirmed absence retires the tombstone"
        )
    }

    /// Round 6 (counsel critical 2): repeated REFUSALS move the tombstone to
    /// the unresolved set — no more retries, no more "in progress", but still
    /// no resurrection; and confirmed absence retires that too.
    func testRefusedDeleteMovesToUnresolvedAndStillSuppresses() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        let drop = GeoDrop()
        try await library.add(drop)
        let refusal = NSError(
            domain: DropStoreError.firestoreErrorDomain, code: 7, // permissionDenied
            userInfo: [NSLocalizedDescriptionKey: "delete refused"]
        )
        await cloud.setFailDelete(refusal, for: drop.id)
        await cloud.setLoadResult([drop]) // the cloud still holds the row

        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }
        library.reconcileCloud()
        try await waitUntil { await cloud.deleteAttempts >= 2 }
        library.reconcileCloud()
        try await waitUntil { library.unresolvedDeleteIDs.contains(drop.id) }
        XCTAssertFalse(library.pendingDeleteIDs.contains(drop.id), "no longer counted as in-progress")

        await library.refresh(near: nil)
        XCTAssertFalse(
            library.drops.contains { $0.id == drop.id },
            "an unresolved delete still suppresses resurrection"
        )

        // Round 8 (counsel B3): retirement needs the SERVER's per-document
        // answer, not an emptied query result.
        await cloud.setLoadResult([])
        await cloud.setServerAbsent([drop.id])
        await library.refresh(near: nil)
        XCTAssertFalse(
            library.unresolvedDeleteIDs.contains(drop.id),
            "server-confirmed absence retires the unresolved delete"
        )
    }

    /// Round 6 (counsel flows-2): editing a terminal drop must NOT clear the
    /// verdict — only a subsequent server ACK may.
    func testEditingTerminalDropKeepsVerdictUntilAck() async throws {
        let cloud = GatedCloudStore()
        var drop = GeoDrop()
        await cloud.setFailSave(DropStoreError.ownedByAnotherAccount, for: drop.id)
        let library = makeLibrary(cloud: cloud)

        try await library.add(drop)
        try await waitUntil { library.terminalSyncFailureIDs.contains(drop.id) }

        drop.message = "edited while terminal"
        try await library.update(drop)
        XCTAssertTrue(
            library.terminalSyncFailureIDs.contains(drop.id),
            "the client's intent to retry must not revoke the server's verdict"
        )
        try await waitUntil { await cloud.saveAttempts >= 2 }
        XCTAssertTrue(library.terminalSyncFailureIDs.contains(drop.id))

        // The mismatch is gone (e.g. account relinked) — the ACK clears it.
        await cloud.setFailSave(nil, for: drop.id)
        library.retrySync(id: drop.id)
        try await waitUntil { !library.terminalSyncFailureIDs.contains(drop.id) }
    }

    /// Round 6 (counsel critical 2), entry point corrected in round 10
    /// (counsel lens-1/flows-1): re-receiving via the LINK is the legitimate
    /// user-driven retirement of the delete blacklist — driven through
    /// `redeem`, the value the receive flow actually produces.
    func testReceivedDropRedemptionClearsDeleteBlacklist() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        var drop = GeoDrop()
        try await library.add(drop)
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: drop.id)
        try await library.remove(drop)
        try await waitUntil { library.pendingDeleteIDs.contains(drop.id) }

        drop.receivedViaLink = true
        try await library.redeem(drop)
        XCTAssertFalse(library.pendingDeleteIDs.contains(drop.id))
        XCTAssertFalse(library.unresolvedDeleteIDs.contains(drop.id))
        XCTAssertTrue(library.drops.contains { $0.id == drop.id })
    }

    /// Round 4 (counsel sync-5): batch outcomes are per-item — one success
    /// never erases another's failure.
    func testFailedDeleteInABatchStaysReported() async throws {
        let local = FlakyLocalStore()
        let library = makeLibrary(local: local)

        let a = GeoDrop()
        let b = GeoDrop()
        try await library.add(a)
        try await library.add(b)
        await local.setFailDelete([a.id])

        await library.remove(contentsOf: [a, b])

        XCTAssertTrue(
            library.lastPersistError?.contains("1 of 2") == true,
            "the aggregate failure must be reported, not clobbered by the success"
        )
        XCTAssertTrue(library.drops.contains { $0.id == a.id }, "the failed delete's row survives")
        XCTAssertFalse(library.drops.contains { $0.id == b.id })
    }

    // MARK: - Round 8 (counsel B1–B4 + delete-pipeline generations)

    /// Round 8 (counsel B1/state-3): a server refusal with a non-retryable
    /// code is a TERMINAL verdict — pending clears, the durable terminal set
    /// takes over, the reason is per-drop — and a later server ack (the
    /// verdict's issuing authority) revokes it.
    func testServerRefusalBecomesTerminalVerdict() async throws {
        let cloud = GatedCloudStore()
        let drop = GeoDrop()
        let reason = "The server refused this drop from this account connection"
        await cloud.setFailSave(DropStoreError.refusedByServer(reason: reason), for: drop.id)
        let library = makeLibrary(cloud: cloud)

        try await library.add(drop)
        try await waitUntil { library.terminalSyncFailureIDs.contains(drop.id) }
        XCTAssertFalse(library.pendingSyncIDs.contains(drop.id), "refused is not pending")
        XCTAssertEqual(library.syncFailureReasons[drop.id], reason)

        await cloud.setFailSave(nil, for: drop.id)
        library.retrySync(id: drop.id)
        try await waitUntil { !library.terminalSyncFailureIDs.contains(drop.id) }
    }

    /// Round 8 (counsel B1): after a server ack the stamped ownerUid is
    /// persisted through the local store — the field the terminal pre-check
    /// reads was usually nil on disk, which is why a genuine refusal could
    /// never be classified in the field.
    func testServerAckPersistsStampedOwnerUid() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stamp-\(UUID().uuidString).json")
        let local = LocalDropStore(fileURL: url)
        let cloud = GatedCloudStore()
        await cloud.setStampUid("uid-stamped")
        let library = DropLibrary(
            localStore: local, cloudStore: cloud, defaults: makeDefaults()
        )

        let drop = GeoDrop() // ownerUid nil, like every locally created drop
        try await library.add(drop)
        try await waitUntil {
            (try? await local.loadDrops(near: nil, radius: 0))?
                .first(where: { $0.id == drop.id })?.ownerUid == "uid-stamped"
        }
        XCTAssertEqual(
            library.drops.first(where: { $0.id == drop.id })?.ownerUid,
            "uid-stamped",
            "the in-memory row carries the server-stamped owner as well"
        )
    }

    /// Round 8 (counsel B4): "Synced" needs POSITIVE evidence — a completed
    /// refresh with provably clean local truth and an answered cloud read.
    /// Cold start is UNKNOWN, never a fallthrough to the good state. A
    /// brand-new install (absent store file, NO journaled incident) is a
    /// legitimately empty library and earns the evidence.
    func testSyncedRequiresPositiveEvidence() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        XCTAssertFalse(
            library.hasCompletedCleanRefresh,
            "cold start must present as checking, not Synced"
        )
        await library.refresh(near: nil)
        XCTAssertTrue(
            library.hasCompletedCleanRefresh,
            "clean local load + answered cloud read earn the positive state"
        )
    }

    /// Round 8 (counsel B4 + flows-6): the absent file a QUARANTINE leaves
    /// behind carries its incident journal — unlike a brand-new store, it
    /// earns nothing until the user resolves it.
    func testQuarantineAbsenceEarnsNoPositiveEvidence() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarantined-\(UUID().uuidString).json")
        try Data("not json at all".utf8).write(to: url)
        let library = DropLibrary(
            localStore: LocalDropStore(fileURL: url),
            cloudStore: GatedCloudStore(), defaults: makeDefaults()
        )

        await library.refresh(near: nil) // quarantines the file, journals
        XCTAssertFalse(
            library.hasCompletedCleanRefresh,
            "a quarantining load must not earn the positive state"
        )
        await library.refresh(near: nil) // file now absent — journal remains
        XCTAssertFalse(
            library.hasCompletedCleanRefresh,
            "quarantine-absence with a journaled incident must not earn it either"
        )
    }

    /// Round 8 (counsel B4): a refresh that cannot read local truth — or whose
    /// cloud read goes unanswered — earns nothing.
    func testFailedRefreshEarnsNoPositiveEvidence() async throws {
        let local = FlakyLocalStore()
        await local.setThrowOnLoad(true)
        let library = makeLibrary(local: local, cloud: GatedCloudStore())
        await library.refresh(near: nil)
        XCTAssertFalse(
            library.hasCompletedCleanRefresh,
            "unreadable local truth must not earn the positive state"
        )

        let failingCloud = GatedCloudStore()
        await failingCloud.setFailLoads(NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        ))
        let library2 = makeLibrary(cloud: failingCloud)
        await library2.refresh(near: nil)
        XCTAssertFalse(
            library2.hasCompletedCleanRefresh,
            "an unanswered cloud read must not earn the positive state"
        )
    }

    /// Round 8 (counsel ux-4): a pending write whose row can't be loaded left
    /// the progress count in round 6 — it must land in a PROBLEM count, not
    /// vanish into a false all-clear.
    func testUnpushablePendingIsAProblemCountNotSilence() async throws {
        let defaults = makeDefaults()
        let ghost = UUID()
        defaults.set([ghost.uuidString], forKey: "pendingSyncDropIDs")

        let absentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        let library = DropLibrary(
            localStore: LocalDropStore(fileURL: absentURL), cloudStore: nil,
            defaults: defaults
        )
        await library.refresh(near: nil)
        XCTAssertEqual(library.uploadingCount, 0, "not progress")
        XCTAssertEqual(
            library.unpushablePendingCount, 1,
            "an un-pushable pending write must surface as a problem"
        )
    }

    /// Round 8 (counsel process item): the delete pipeline carries the save
    /// pipeline's generation discipline — a refusal resumed AFTER the drop was
    /// redeemed (stale generation) must not issue the unresolved verdict and
    /// suppress the redeemed drop.
    func testRedemptionSupersedesInFlightDeleteVerdict() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        var drop = GeoDrop()
        try await library.add(drop)
        let refusal = NSError(
            domain: DropStoreError.firestoreErrorDomain, code: 7, // permissionDenied
            userInfo: [NSLocalizedDescriptionKey: "delete refused"]
        )
        await cloud.setFailDelete(refusal, for: drop.id)

        // Two refusals land normally — one more would go unresolved.
        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }
        library.reconcileCloud()
        try await waitUntil { await cloud.deleteAttempts >= 2 }

        // The third attempt parks mid-flight…
        await cloud.setGateDeletes(true)
        library.reconcileCloud()
        try await waitUntil { await cloud.parkedDeleteCount == 1 }

        // …the user re-receives the drop (redemption supersedes the delete)…
        drop.receivedViaLink = true
        try await library.redeem(drop)

        // …and the stale task's refusal finally resumes.
        await cloud.releaseAllDeletes()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(
            library.unresolvedDeleteIDs.contains(drop.id),
            "a stale delete generation must not suppress a redeemed drop"
        )
        XCTAssertFalse(library.pendingDeleteIDs.contains(drop.id))
        XCTAssertTrue(library.drops.contains { $0.id == drop.id }, "the redeemed drop stays")
    }

    // MARK: - Round 10 (counsel ux-1, lens-1, seams-1, lens-3, lens-4)

    /// Round 10 (counsel ux-1 CRITICAL): a CACHE-served cloud read must never
    /// earn "Synced" — Firestore answers getDocuments from the local cache
    /// offline, and the charter's own words forbid a server-confirmation
    /// claim no server made.
    func testCacheServedCloudReadEarnsNoPositiveEvidence() async throws {
        let cloud = GatedCloudStore()
        await cloud.setServedFromCache(true)
        let library = makeLibrary(cloud: cloud)
        await library.refresh(near: nil)
        XCTAssertFalse(
            library.hasCompletedCleanRefresh,
            "a cache-served read is not server confirmation"
        )
        await cloud.setServedFromCache(false)
        await library.refresh(near: nil)
        XCTAssertTrue(library.hasCompletedCleanRefresh, "a server-served read earns it")
    }

    // (round 14: accountDidChange() was deleted — its reset behavior lives in
    // authDidBecomeReady and is covered by testAuthReadyResetsOnlyOnARealUidChange)

    /// Round 10 (counsel lens-1 CRITICAL): a fetched link copy must NEVER
    /// overwrite a row carrying an unacked local edit — in memory or on disk.
    func testRedeemNeverOverwritesAPendingLocalEdit() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("redeem-\(UUID().uuidString).json")
        let local = LocalDropStore(fileURL: url)
        let cloud = GatedCloudStore()
        await cloud.setFailAllSaves(with: DropStoreError.notSignedIn)
        let library = DropLibrary(
            localStore: local, cloudStore: cloud, defaults: makeDefaults()
        )
        var drop = GeoDrop()
        drop.message = "local edit — newer"
        try await library.add(drop)
        try await waitUntil { await cloud.saveAttempts > 0 }
        XCTAssertTrue(library.pendingSyncIDs.contains(drop.id))

        var stale = drop
        stale.message = "stale server copy"
        stale.receivedViaLink = true
        try await library.redeem(stale)

        XCTAssertEqual(
            library.drops.first(where: { $0.id == drop.id })?.message,
            "local edit — newer", "memory keeps the pending edit"
        )
        let onDisk = try await local.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(
            onDisk.first(where: { $0.id == drop.id })?.message,
            "local edit — newer", "disk keeps the pending edit"
        )
    }

    /// Round 10 (counsel lens-3): deleting a drop the server never ACKED must
    /// resolve as DONE after bounded refusals — no "cloud copy may still
    /// exist" alarm for a copy that never existed.
    func testNeverAckedDeleteResolvesWithoutCloudCopyAlarm() async throws {
        let cloud = GatedCloudStore()
        await cloud.setFailAllSaves(with: DropStoreError.notSignedIn) // never acked
        let library = makeLibrary(cloud: cloud)
        let drop = GeoDrop()
        try await library.add(drop)
        try await waitUntil { await cloud.saveAttempts > 0 }
        let refusal = NSError(
            domain: DropStoreError.firestoreErrorDomain, code: 7, // permissionDenied
            userInfo: [NSLocalizedDescriptionKey: "delete refused"]
        )
        await cloud.setFailDelete(refusal, for: drop.id)

        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }
        library.reconcileCloud()
        try await waitUntil { await cloud.deleteAttempts >= 2 }
        library.reconcileCloud()
        try await waitUntil { !library.pendingDeleteIDs.contains(drop.id) }
        XCTAssertFalse(
            library.unresolvedDeleteIDs.contains(drop.id),
            "a drop the server never saw must not raise a cloud-copy alarm"
        )
    }

    /// Round 10 (counsel seams-1c): when the deployed rules cannot answer
    /// absence, retirement probes are skipped entirely — a tombstone must not
    /// retire (and round-trips must not be paid) on a question the backend
    /// cannot answer.
    func testDeniedAbsenceCapabilitySkipsRetirementProbes() async throws {
        let cloud = GatedCloudStore()
        await cloud.setAbsenceCapability(.denied)
        let library = makeLibrary(cloud: cloud)
        let drop = GeoDrop()
        try await library.add(drop)
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: drop.id)
        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }

        await cloud.setServerAbsent([drop.id]) // would retire IF probed
        await library.refresh(near: nil)
        XCTAssertTrue(
            library.pendingDeleteIDs.contains(drop.id),
            "no probe may run — or retire — under rules that cannot answer absence"
        )
    }

    func testDeniedCapabilityRetriesAfterBackoffAndStillRequiresPerDocumentAbsence() async {
        let id = UUID()
        let defaults = makeDefaults()
        defaults.set([id.uuidString], forKey: "pendingDeleteDropIDs")
        let cloud = GatedCloudStore()
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: id)
        await cloud.setAbsenceCapability(.denied)
        var uptime: TimeInterval = 0
        let library = makeLibrary(cloud: cloud, defaults: defaults, absenceProbeTime: { uptime })

        await library.refresh(near: nil)
        XCTAssertTrue(library.pendingDeleteIDs.contains(id))
        await cloud.setAbsenceCapability(.answers) // A rules rollout changes the capability.
        uptime = 59
        await library.refresh(near: nil)
        let beforeBackoff = await cloud.absenceProbeCalls
        XCTAssertEqual(beforeBackoff, 1, "Denials back off instead of probing every refresh")

        uptime = 61
        await library.refresh(near: nil)
        let afterBackoff = await cloud.absenceProbeCalls
        XCTAssertEqual(afterBackoff, 2, "The same session must recover after a rules rollout")
        XCTAssertTrue(library.pendingDeleteIDs.contains(id), "Capability is not proof this drop is gone")

        await cloud.setServerAbsent([id])
        await library.refresh(near: nil)
        XCTAssertFalse(library.pendingDeleteIDs.contains(id), "Per-document proof retires the tombstone")
        let afterRetirement = await cloud.absenceProbeCalls
        XCTAssertEqual(afterRetirement, 2, "Positive capability can be reused")
    }

    func testChangedIdentityRechecksDeniedCapabilityWithoutWaitingForBackoff() async {
        let id = UUID()
        let defaults = makeDefaults()
        defaults.set([id.uuidString], forKey: "pendingDeleteDropIDs")
        let cloud = GatedCloudStore()
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: id)
        await cloud.setAbsenceCapability(.denied)
        let library = makeLibrary(cloud: cloud, defaults: defaults, absenceProbeTime: { 0 })

        await library.authDidBecomeReady(uid: "first-user")
        await cloud.setAbsenceCapability(.answers)
        await cloud.setServerAbsent([id])
        await library.authDidBecomeReady(uid: "first-user")
        XCTAssertTrue(library.pendingDeleteIDs.contains(id), "An unchanged identity keeps the backoff")
        let sameIdentityCalls = await cloud.absenceProbeCalls
        XCTAssertEqual(sameIdentityCalls, 1)

        await library.authDidBecomeReady(uid: "second-user")
        XCTAssertFalse(library.pendingDeleteIDs.contains(id), "A different identity needs a fresh verdict")
        let changedIdentityCalls = await cloud.absenceProbeCalls
        XCTAssertEqual(changedIdentityCalls, 2)
    }

    func testFirstAuthReadyRechecksCapabilityLearnedBeforeIdentityWasAttached() async {
        let id = UUID()
        let defaults = makeDefaults()
        defaults.set([id.uuidString], forKey: "pendingDeleteDropIDs")
        let cloud = GatedCloudStore()
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: id)
        await cloud.setAbsenceCapability(.denied)
        let library = makeLibrary(cloud: cloud, defaults: defaults, absenceProbeTime: { 0 })

        await library.refresh(near: nil)
        await cloud.setAbsenceCapability(.answers)
        await cloud.setServerAbsent([id])
        await library.authDidBecomeReady(uid: "first-user")
        XCTAssertFalse(library.pendingDeleteIDs.contains(id))
        let calls = await cloud.absenceProbeCalls
        XCTAssertEqual(calls, 2, "Bootstrap must not reuse a verdict learned before auth-ready")
    }

    // MARK: - Round 12 (counsel round-11 blockers + same-pass items)

    /// Round 12 (counsel SURF-lens-1/STATE-lens-3/FLOWS-lens-3): the composed
    /// auth-ready pass must END with the evidence it earned — the old
    /// refresh-then-reset sequence pinned the ladder at "Checking…" forever.
    func testAuthReadyPassKeepsTheEvidenceItEarns() async throws {
        let library = makeLibrary(cloud: GatedCloudStore())
        await library.authDidBecomeReady(uid: "uid-1")
        XCTAssertTrue(
            library.hasCompletedCleanRefresh,
            "the composed pass must not destroy the evidence its own refresh earned"
        )
        await library.authDidBecomeReady(uid: "uid-1")
        XCTAssertTrue(library.hasCompletedCleanRefresh, "an unchanged uid never resets")
    }

    /// Round 12 (counsel lens-4 discipline): only a REAL uid change resets —
    /// and a failing read after it cannot re-earn.
    func testAuthReadyResetsOnlyOnARealUidChange() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        await library.authDidBecomeReady(uid: "uid-1")
        XCTAssertTrue(library.hasCompletedCleanRefresh)

        await cloud.setFailLoads(NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        ))
        await library.authDidBecomeReady(uid: "uid-2")
        XCTAssertFalse(
            library.hasCompletedCleanRefresh,
            "a real uid change resets, and an unanswered read cannot re-earn"
        )
    }

    /// Round 12 (counsel own-A CRITICAL): redeeming the user's OWN deleted
    /// drop must re-enqueue an upload — the delete may already be STAGED in
    /// the cloud store's durable queue, and only a later serialized save can
    /// recreate the document behind it.
    func testRedeemingOwnDropReenqueuesUploadOverStagedDelete() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        let drop = GeoDrop() // own drop: receivedViaLink nil
        try await library.add(drop)
        try await waitUntil { !library.pendingSyncIDs.contains(drop.id) } // acked

        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: drop.id) // staged, unanswered
        try await library.remove(drop)
        try await waitUntil { library.pendingDeleteIDs.contains(drop.id) }

        try await library.redeem(drop) // the user re-opens their own link
        XCTAssertFalse(library.pendingDeleteIDs.contains(drop.id))
        try await waitUntil {
            await cloud.saved.filter { $0 == drop.id }.count >= 2
        }
    }

    /// Round 12 (counsel STATE-lens-2/FLOWS-lens-2): when no local row exists
    /// the fetched copy is the LAST copy — redeem restores it to memory and
    /// disk instead of reporting success over nothing.
    func testRedeemRestoresTheRowWhenNoLocalRowExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).json")
        let local = LocalDropStore(fileURL: url)
        let cloud = GatedCloudStore()
        let library = DropLibrary(
            localStore: local, cloudStore: cloud, defaults: makeDefaults()
        )
        var drop = GeoDrop()
        drop.message = "the last copy"
        try await library.add(drop)
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: drop.id)
        try await library.remove(drop)
        try await waitUntil { library.pendingDeleteIDs.contains(drop.id) }

        var fetched = drop
        fetched.receivedViaLink = true
        try await library.redeem(fetched)
        XCTAssertTrue(library.drops.contains { $0.id == drop.id })
        let onDisk = try await local.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(
            onDisk.first(where: { $0.id == drop.id })?.message, "the last copy",
            "the fetched copy is restored to disk — it is the only copy left"
        )
    }

    /// Round 12 (counsel STATE-lens-4/FLOWS-lens-4): a failed cloud read must
    /// not blink out rows a completed pass contributed — phase 1 is additive
    /// and phase 2 runs only on a completed read.
    func testFailedCloudReadDoesNotBlinkOutCloudRows() async throws {
        let cloud = GatedCloudStore()
        var cloudDrop = GeoDrop()
        cloudDrop.message = "cloud only"
        await cloud.setLoadResult([cloudDrop])
        let library = makeLibrary(cloud: cloud)
        await library.refresh(near: nil)
        XCTAssertTrue(library.drops.contains { $0.id == cloudDrop.id })

        await cloud.setFailLoads(NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        ))
        await library.refresh(near: nil)
        XCTAssertTrue(
            library.drops.contains { $0.id == cloudDrop.id },
            "a failed pass must not un-publish rows a completed pass contributed"
        )
        XCTAssertNotNil(library.lastSyncError)
    }

    /// Round 12 (counsel SEAMS-lens-1, emulator-reproduced): rows a
    /// server-served snapshot carries via LATENCY COMPENSATION are not
    /// acknowledgments — only pending-write-free rows earn the acked fact.
    func testLatencyCompensatedRowsDoNotEarnTheAckedFact() async throws {
        let defaults = makeDefaults()
        let cloud = GatedCloudStore()
        let staged = GeoDrop()
        await cloud.setLoadResult([staged])
        await cloud.setUnackedRows([staged.id])
        let library = makeLibrary(cloud: cloud, defaults: defaults)
        await library.refresh(near: nil)
        let acked = defaults.stringArray(forKey: "ackedCloudDropIDs") ?? []
        XCTAssertFalse(
            acked.contains(staged.id.uuidString),
            "a pending-writes row is the device's own echo, not a server ack"
        )

        await cloud.setUnackedRows([])
        await library.refresh(near: nil)
        let ackedAfter = defaults.stringArray(forKey: "ackedCloudDropIDs") ?? []
        XCTAssertTrue(ackedAfter.contains(staged.id.uuidString))
    }

    /// Round 12 (counsel FLOWS-lens-1): provenance captured at tombstone time
    /// — a drop whose disk row carries a stamped ownerUid was on the server
    /// under SOME connection, so its refused delete raises the visible alarm
    /// even though this session never acked it.
    func testProvenButUnackedDeleteStillRaisesTheAlarm() async throws {
        let cloud = GatedCloudStore()
        await cloud.setFailAllSaves(with: DropStoreError.notSignedIn) // never acked here
        let library = makeLibrary(cloud: cloud)
        var drop = GeoDrop()
        drop.ownerUid = "stamped-by-a-previous-session"
        try await library.add(drop)
        try await waitUntil { await cloud.saveAttempts > 0 }

        let refusal = NSError(
            domain: DropStoreError.firestoreErrorDomain, code: 7,
            userInfo: [NSLocalizedDescriptionKey: "delete refused"]
        )
        await cloud.setFailDelete(refusal, for: drop.id)
        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }
        library.reconcileCloud()
        try await waitUntil { await cloud.deleteAttempts >= 2 }
        library.reconcileCloud()
        try await waitUntil { library.unresolvedDeleteIDs.contains(drop.id) }
    }

    /// Round 12 (counsel SEAMS-lens-2): transient delete failures spend no
    /// attempt budget — the tombstone stays pending and keeps retrying,
    /// exactly like the save pipeline.
    func testTransientDeleteFailureSpendsNoAttemptBudget() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        let drop = GeoDrop()
        try await library.add(drop)
        let transient = NSError(
            domain: DropStoreError.firestoreErrorDomain, code: 14, // unavailable
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        )
        await cloud.setFailDelete(transient, for: drop.id)
        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }
        library.reconcileCloud()
        try await waitUntil { await cloud.deleteAttempts >= 2 }
        library.reconcileCloud()
        try await waitUntil { await cloud.deleteAttempts >= 3 }
        library.reconcileCloud()
        try await waitUntil { await cloud.deleteAttempts >= 4 }
        XCTAssertTrue(
            library.pendingDeleteIDs.contains(drop.id),
            "transient failures never exhaust the budget — the tombstone keeps retrying"
        )
        XCTAssertFalse(library.unresolvedDeleteIDs.contains(drop.id))
    }

    /// Round 12 (counsel own-B): dismissing the corruption banner must not
    /// launder a destroyed library into a brand-new install — the incident is
    /// remembered independently of the journal, and only a CLEAN load retires
    /// the memory.
    func testDismissedQuarantineDoesNotEarnSyncedViaAbsentFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dismissed-\(UUID().uuidString).json")
        try Data("not json at all".utf8).write(to: url)
        let local = LocalDropStore(fileURL: url)
        let library = DropLibrary(
            localStore: local, cloudStore: GatedCloudStore(), defaults: makeDefaults()
        )
        await library.refresh(near: nil) // quarantines + remembers
        XCTAssertFalse(library.hasCompletedCleanRefresh)

        await local.acknowledgeIncident() // the user taps Dismiss
        await library.refresh(near: nil) // absent file, journal gone — memory remains
        XCTAssertFalse(
            library.hasCompletedCleanRefresh,
            "Dismiss retires the banner, never the evidence bar"
        )

        try await local.save(GeoDrop()) // a genuinely clean library returns
        await library.refresh(near: nil)
        XCTAssertTrue(library.hasCompletedCleanRefresh, "a clean LOAD retires the memory")
    }

    /// Round 12 (counsel SEAMS-lens-3): a cache-served read must not revoke a
    /// server-issued sync-failure verdict.
    func testCacheServedReadDoesNotClearAServerIssuedSyncError() async throws {
        let cloud = GatedCloudStore()
        let library = makeLibrary(cloud: cloud)
        await cloud.setFailLoads(NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "server unavailable"]
        ))
        await library.refresh(near: nil)
        XCTAssertNotNil(library.lastSyncError)

        await cloud.setFailLoads(nil)
        await cloud.setServedFromCache(true)
        await library.refresh(near: nil)
        XCTAssertNotNil(
            library.lastSyncError,
            "a cache-served read may not revoke a verdict only the server issued"
        )
        await cloud.setServedFromCache(false)
        await library.refresh(near: nil)
        XCTAssertNil(library.lastSyncError)
    }

    // MARK: - Round 14 (the wave-exit round: counsel round-13 blockers)

    /// Round 14 (counsel state-1/flows-lens-1 — CRITICAL): a concurrent
    /// refresh must NEVER abandon a delete whose disk row is already
    /// destroyed — the round-12 guard keyed on the global publish counter and
    /// did exactly that.
    func testRefreshDuringRemoveDoesNotAbandonTheDelete() async throws {
        let local = FlakyLocalStore()
        let cloud = GatedCloudStore()
        let library = makeLibrary(local: local, cloud: cloud)
        let drop = GeoDrop()
        try await library.add(drop)
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: drop.id)

        await local.setGateDeletes(true)
        let removeTask = Task { try await library.remove(drop) }
        try await waitUntil { await local.parkedDeleteCount == 1 }

        await library.refresh(near: nil) // must NOT supersede the remove
        await local.releaseAllDeletes()
        try? await removeTask.value

        try await waitUntil { library.pendingDeleteIDs.contains(drop.id) }
        XCTAssertFalse(
            library.drops.contains { $0.id == drop.id },
            "the delete completed: row gone, tombstone standing"
        )
    }

    /// Round 14 (counsel state-1, the abort branch ENTERED): only another
    /// MUTATOR of the same row — here a redeem — supersedes an in-flight
    /// remove; the aborted remove must not tombstone the redeemed drop.
    func testRedeemDuringRemoveSupersedesTheDelete() async throws {
        let local = FlakyLocalStore()
        let cloud = GatedCloudStore()
        let library = makeLibrary(local: local, cloud: cloud)
        var drop = GeoDrop()
        try await library.add(drop)

        await local.setGateDeletes(true)
        let removeTask = Task { try await library.remove(drop) }
        try await waitUntil { await local.parkedDeleteCount == 1 }

        drop.receivedViaLink = true
        try await library.redeem(drop) // bumps the row epoch
        await local.releaseAllDeletes()
        try? await removeTask.value

        XCTAssertFalse(
            library.pendingDeleteIDs.contains(drop.id),
            "the superseded remove must not tombstone the redeemed drop"
        )
        XCTAssertTrue(library.drops.contains { $0.id == drop.id })
    }

    /// Round 14 (counsel seams-2 + state-3, both branches ENTERED): a failed
    /// persist leaves NO memory-only row (so a retry genuinely retries), and
    /// the staged-delete recall runs even on the failure path.
    func testRedeemPersistFailureLeavesNoGhostAndStillRecallsTheDelete() async throws {
        let local = FlakyLocalStore()
        let cloud = GatedCloudStore()
        let library = makeLibrary(local: local, cloud: cloud)
        let drop = GeoDrop() // own drop
        try await library.add(drop)
        try await waitUntil { !library.pendingSyncIDs.contains(drop.id) }
        await cloud.setFailDelete(DropStoreError.ackTimedOut, for: drop.id)
        try await library.remove(drop)
        try await waitUntil { library.pendingDeleteIDs.contains(drop.id) }

        await local.setFailSave(true)
        do {
            try await library.redeem(drop)
            XCTFail("a failed persist must throw")
        } catch {}
        XCTAssertFalse(
            library.drops.contains { $0.id == drop.id },
            "no memory-only row over a failed persist — the retry must retry"
        )
        try await waitUntil {
            await cloud.saved.filter { $0 == drop.id }.count >= 2
        } // the staged-delete recall ran regardless

        await local.setFailSave(false)
        try await library.redeem(drop)
        XCTAssertTrue(library.drops.contains { $0.id == drop.id }, "the retry restores for real")
    }

    /// Round 14 (counsel flows-lens-3): a REFUSED write is proof the server
    /// does NOT hold the document — a terminal drop that was never acked must
    /// resolve its delete as done, never raise the permanent cloud-copy alarm.
    func testTerminalRefusalIsNotProofTheServerHoldsTheDocument() async throws {
        let cloud = GatedCloudStore()
        let drop = GeoDrop() // ownerUid nil, never acked
        await cloud.setFailSave(
            DropStoreError.refusedByServer(reason: "refused"), for: drop.id
        )
        let library = makeLibrary(cloud: cloud)
        try await library.add(drop)
        try await waitUntil { library.terminalSyncFailureIDs.contains(drop.id) }

        let refusal = NSError(
            domain: DropStoreError.firestoreErrorDomain, code: 7,
            userInfo: [NSLocalizedDescriptionKey: "delete refused"]
        )
        await cloud.setFailDelete(refusal, for: drop.id)
        try await library.remove(drop)
        try await waitUntil { await cloud.deleteAttempts >= 1 }
        library.reconcileCloud()
        try await waitUntil { await cloud.deleteAttempts >= 2 }
        library.reconcileCloud()
        try await waitUntil { !library.pendingDeleteIDs.contains(drop.id) }
        XCTAssertFalse(
            library.unresolvedDeleteIDs.contains(drop.id),
            "a refusal proves absence of a server copy, not its existence"
        )
    }

    /// Round 14 (counsel surf-lens-1/2 + own-1): the loss LEDGER — recorded
    /// by id at the moment of destruction, immune to Dismiss (which is now
    /// non-destructive) and to the reap, cleared only by the user or a
    /// genuine restore.
    func testLostRowsAreRecordedDurablyAndDismissDestroysNothing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).json")
        var good = GeoDrop()
        good.message = "survivor"
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let lostID = UUID()
        let bad = "{\"id\":\"\(lostID.uuidString)\",\"heightAboveGround\":\"3\"}"
        try Data("[\(goodJSON),\(bad)]".utf8).write(to: url)

        let local = LocalDropStore(fileURL: url)
        let library = DropLibrary(
            localStore: local, cloudStore: GatedCloudStore(), defaults: makeDefaults()
        )
        await library.refresh(near: nil)
        XCTAssertTrue(library.lostRowIDs.contains(lostID), "the loss is recorded BY ID")
        XCTAssertFalse(
            library.hasCompletedCleanRefresh,
            "a destructive outcome revokes the all-clear (round 14, state-2)"
        )

        await local.acknowledgeIncident() // the user taps Dismiss
        await library.refresh(near: nil)
        XCTAssertNil(library.localReadWarning, "the banner stays down for these bytes")
        XCTAssertTrue(
            library.lostRowIDs.contains(lostID),
            "Dismiss silences the banner, never the ledger"
        )
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            raw.contains(lostID.uuidString),
            "Dismiss must not destroy the unreadable rows"
        )

        library.acknowledgeLosses() // the user's explicit clear
        XCTAssertTrue(library.lostRowIDs.isEmpty)
    }

    func testClearSurvivesRefreshAndRelaunchButChangedBytesResurface() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-\(UUID().uuidString).json")
        let id = UUID()
        let original = Data("[{\"id\":\"\(id.uuidString)\",\"heightAboveGround\":\"bad\"}]".utf8)
        try original.write(to: url)
        let defaults = makeDefaults()
        let store = LocalDropStore(fileURL: url)
        let first = DropLibrary(localStore: store, cloudStore: nil, defaults: defaults)
        await first.refresh(near: nil)
        XCTAssertEqual(first.lostRowIDs, [id])
        XCTAssertNotNil(first.storageProblemText)

        first.acknowledgeLosses()
        XCTAssertNil(first.storageLedgerError)
        XCTAssertNil(first.storageProblemText)
        XCTAssertEqual(try Data(contentsOf: url), original, "Clear must not rewrite bad rows")
        await first.refresh(near: nil)
        XCTAssertNil(first.storageProblemText)

        let relaunched = DropLibrary(
            localStore: LocalDropStore(fileURL: url), cloudStore: nil, defaults: defaults
        )
        await relaunched.refresh(near: nil)
        XCTAssertNil(relaunched.storageProblemText)
        XCTAssertTrue(relaunched.lostRowIDs.isEmpty)

        let changed = Data("[{\"id\":\"\(id.uuidString)\",\"heightAboveGround\":\"different bad bytes\"}]".utf8)
        try changed.write(to: url)
        await relaunched.refresh(near: nil)
        XCTAssertEqual(relaunched.lostRowIDs, [id], "reused id with changed corruption is new")
        XCTAssertNotNil(relaunched.storageProblemText)
        XCTAssertEqual(try Data(contentsOf: url), changed)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path
            ))?.filter { $0.hasPrefix(url.lastPathComponent + ".unreadable-") }.count,
            2, "each distinct original is preserved"
        )
    }

    func testIdlessSkippedRowHasVisibleCountWithoutInventedID() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idless-\(UUID().uuidString).json")
        let original = Data("[{\"heightAboveGround\":\"bad\"}]".utf8)
        try original.write(to: url)
        let library = DropLibrary(
            localStore: LocalDropStore(fileURL: url), cloudStore: nil, defaults: makeDefaults()
        )

        await library.refresh(near: nil)

        XCTAssertTrue(library.lostRowIDs.isEmpty)
        XCTAssertEqual(library.storageProblemText, "1 saved drop couldn't be read")
        library.acknowledgeLosses()
        XCTAssertNil(library.storageProblemText)
        await library.refresh(near: nil)
        XCTAssertNil(library.storageProblemText)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testReceivedOnlyWholeFileQuarantineHasUnknownExtentAndPreservesBackup() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("received-quarantine-\(UUID().uuidString).json")
        let defaults = makeDefaults()
        let library = DropLibrary(
            localStore: LocalDropStore(fileURL: url), cloudStore: nil, defaults: defaults
        )
        var received = GeoDrop()
        received.receivedViaLink = true
        try await library.redeem(received)
        XCTAssertTrue(library.pendingSyncIDs.isEmpty)

        let bad = Data("not a JSON array".utf8)
        try bad.write(to: url)
        let relaunched = DropLibrary(
            localStore: LocalDropStore(fileURL: url), cloudStore: nil, defaults: defaults
        )
        await relaunched.refresh(near: nil)

        XCTAssertEqual(relaunched.lostRowIDs, [received.id])
        XCTAssertEqual(
            relaunched.storageProblemText,
            "Saved drops couldn't be read — the affected count is unknown"
        )
        let backups = (try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )).filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), bad)
    }

    func testRepairingOneRowKeepsOtherIncidentAndAcknowledgementHistory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-repair-\(UUID().uuidString).json")
        let first = GeoDrop()
        let second = GeoDrop()
        let badA = "{\"id\":\"\(first.id.uuidString)\",\"heightAboveGround\":\"bad\"}"
        let badB = "{\"id\":\"\(second.id.uuidString)\",\"heightAboveGround\":\"bad\"}"
        try Data("[\(badA),\(badB)]".utf8).write(to: url)
        let local = LocalDropStore(fileURL: url)
        let library = DropLibrary(localStore: local, cloudStore: nil, defaults: makeDefaults())
        await library.refresh(near: nil)
        XCTAssertEqual(library.lostRowIDs, [first.id, second.id])

        try await local.save(first)
        await library.refresh(near: nil)

        XCTAssertEqual(library.lostRowIDs, [second.id])
        XCTAssertNotNil(library.storageProblemText)
        let cleanVerdictBeforeAcknowledgement = library.hasCompletedCleanRefresh
        library.acknowledgeLosses()
        XCTAssertNil(library.storageProblemText)
        XCTAssertEqual(library.lostRowIDs, [])
        XCTAssertEqual(
            library.hasCompletedCleanRefresh, cleanVerdictBeforeAcknowledgement,
            "acknowledgement cannot mint a new sync verdict"
        )
    }

    func testFailedClearDoesNotClaimDurableAcknowledgement() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-failure-\(UUID().uuidString).json")
        let id = UUID()
        let bad = Data("[{\"id\":\"\(id.uuidString)\",\"heightAboveGround\":\"bad\"}]".utf8)
        try bad.write(to: url)
        let ledgerURL = url.appendingPathExtension("lossledger")
        let library = DropLibrary(
            localStore: LocalDropStore(fileURL: url), cloudStore: nil,
            defaults: makeDefaults(), incidentLedgerURL: ledgerURL
        )
        await library.refresh(near: nil)
        XCTAssertEqual(library.lostRowIDs, [id])
        try FileManager.default.removeItem(at: ledgerURL)
        try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: false)

        library.acknowledgeLosses()

        XCTAssertEqual(library.lostRowIDs, [id])
        XCTAssertNotNil(library.storageProblemText)
        XCTAssertTrue(library.storageLedgerError?.contains("Couldn't save") == true)
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testLegacyIDLedgerMigratesAndAcknowledgementRemainsDurable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-loss-\(UUID().uuidString).json")
        let defaults = makeDefaults()
        let id = UUID()
        defaults.set([id.uuidString], forKey: "lostRowIDs")
        let library = DropLibrary(
            localStore: LocalDropStore(fileURL: url), cloudStore: nil, defaults: defaults
        )
        XCTAssertEqual(library.lostRowIDs, [id])
        XCTAssertNil(defaults.stringArray(forKey: "lostRowIDs"))

        library.acknowledgeLosses()
        let relaunched = DropLibrary(
            localStore: LocalDropStore(fileURL: url), cloudStore: nil, defaults: defaults
        )
        XCTAssertTrue(relaunched.lostRowIDs.isEmpty)
        XCTAssertNil(relaunched.storageProblemText)
    }
}

/// Round 8 (counsel B1): the refusal taxonomy — driven through the exposed
/// domain/code seam because this bundle must not link Firebase (gRPC
/// double-links). The numeric codes are gRPC's frozen public contract.
final class RefusalTaxonomyTests: XCTestCase {
    private let domain = DropStoreError.firestoreErrorDomain

    func testNonRetryableCodesAreTerminal() {
        // 3 invalidArgument · 5 notFound · 7 permissionDenied
        // 9 failedPrecondition · 16 unauthenticated
        for code in [3, 5, 7, 9, 16] {
            XCTAssertNotNil(
                DropStoreError.terminalRefusalReason(domain: domain, code: code),
                "gRPC \(code) is non-retryable — must produce a terminal refusal"
            )
        }
    }

    func testTransientCodesStayRetryable() {
        // 4 deadlineExceeded · 8 resourceExhausted · 10 aborted
        // 13 internal · 14 unavailable
        for code in [4, 8, 10, 13, 14] {
            XCTAssertNil(
                DropStoreError.terminalRefusalReason(domain: domain, code: code),
                "gRPC \(code) is transient — the drop must stay pending"
            )
        }
    }

    func testForeignDomainsNeverProduceTerminalVerdicts() {
        XCTAssertNil(
            DropStoreError.terminalRefusalReason(domain: NSURLErrorDomain, code: 7),
            "only Firestore's own refusal codes may go terminal"
        )
    }
}

// MARK: - Test doubles (round 4, counsel concurrency-6)

/// A cloud stand-in that reproduces production's ISOLATION and SUSPENSION
/// POINTS: an actor whose operations can be parked mid-flight on a gate the
/// test resumes explicitly — so interleavings (superseded generations, deletes
/// racing refreshes) are deterministically drivable. A @MainActor double with a
/// non-suspending save tests a program that does not exist.
actor GatedCloudStore: DropStore, DropAbsenceVerifying, ProvenancedDropStore {
    private var failAllSaves: Error?
    private var failSaveFor: [UUID: Error] = [:]
    private var failDeleteFor: [UUID: Error] = [:]
    private var failLoads: Error?
    private var loadResult: [GeoDrop] = []
    /// Round 10 (counsel ux-1): reads report provenance — tests drive the
    /// cache-served case the production SDK produces offline.
    private var servedFromCache = false
    /// Round 12 (counsel SEAMS-lens-1): rows the "server" returns via latency
    /// compensation WITHOUT having acknowledged them — excluded from
    /// serverConfirmedIDs exactly like production's hasPendingWrites rows.
    private var unackedRowIDs: Set<UUID> = []
    /// Round 10 (counsel seams-1c): configurable deployed-rules capability.
    private var absenceCapabilityAnswer: AbsenceCapability = .answers
    private(set) var absenceProbeCalls = 0
    private var gateSaves = false
    private var gateLoads = false
    private var gateDeletes = false
    private var parkedSaves: [CheckedContinuation<Void, Never>] = []
    private var parkedLoads: [CheckedContinuation<Void, Never>] = []
    private var parkedDeletes: [CheckedContinuation<Void, Never>] = []
    /// Round 8 (counsel B1): the uid the "server" stamps onto acked saves —
    /// production's FirebaseDropStore returns the stored form with ownerUid.
    private var stampUid: String?
    /// Round 8 (counsel B3): ids the SERVER has positively confirmed absent.
    /// Distinct from `loadResult` on purpose — a query that no longer contains
    /// a row is NOT the same fact, and the library must never treat it as one.
    private var serverAbsentIDs: Set<UUID> = []
    private(set) var saved: [UUID] = []
    private(set) var saveAttempts = 0
    private(set) var deleteAttempts = 0

    func setFailAllSaves(with error: Error?) { failAllSaves = error }
    func setFailSave(_ error: Error?, for id: UUID) { failSaveFor[id] = error }
    func setFailDelete(_ error: Error?, for id: UUID) { failDeleteFor[id] = error }
    func setFailLoads(_ error: Error?) { failLoads = error }
    func setLoadResult(_ drops: [GeoDrop]) { loadResult = drops }
    func setGateSaves(_ on: Bool) { gateSaves = on }
    func setGateLoads(_ on: Bool) { gateLoads = on }
    func setGateDeletes(_ on: Bool) { gateDeletes = on }
    func setStampUid(_ uid: String?) { stampUid = uid }
    func setServerAbsent(_ ids: Set<UUID>) { serverAbsentIDs = ids }
    func setServedFromCache(_ on: Bool) { servedFromCache = on }
    func setUnackedRows(_ ids: Set<UUID>) { unackedRowIDs = ids }
    func setAbsenceCapability(_ capability: AbsenceCapability) {
        absenceCapabilityAnswer = capability
    }
    var parkedSaveCount: Int { parkedSaves.count }
    var parkedLoadCount: Int { parkedLoads.count }
    var parkedDeleteCount: Int { parkedDeletes.count }

    func releaseOneSave() {
        guard !parkedSaves.isEmpty else { return }
        parkedSaves.removeFirst().resume()
    }

    func releaseAllSaves() {
        let parked = parkedSaves
        parkedSaves = []
        parked.forEach { $0.resume() }
    }

    func releaseAllLoads() {
        let parked = parkedLoads
        parkedLoads = []
        parked.forEach { $0.resume() }
    }

    func releaseAllDeletes() {
        let parked = parkedDeletes
        parkedDeletes = []
        parked.forEach { $0.resume() }
    }

    func serverConfirmsAbsent(_ id: UUID) async -> Bool {
        serverAbsentIDs.contains(id)
    }

    func probeAbsenceCapability() async -> AbsenceCapability {
        absenceProbeCalls += 1
        return absenceCapabilityAnswer
    }

    func loadDrops(near location: CLLocation?, radius: CLLocationDistance) async throws -> [GeoDrop] {
        if gateLoads {
            await withCheckedContinuation { parkedLoads.append($0) }
        }
        if let failLoads { throw failLoads }
        return loadResult
    }

    func loadDropsWithProvenance(
        near location: CLLocation?, radius: CLLocationDistance
    ) async throws -> CloudRead {
        let rows = try await loadDrops(near: location, radius: radius)
        return CloudRead(
            drops: rows,
            servedFromCache: servedFromCache,
            serverConfirmedIDs: Set(rows.map(\.id)).subtracting(unackedRowIDs)
        )
    }

    @discardableResult
    func save(_ drop: GeoDrop) async throws -> GeoDrop {
        saveAttempts += 1
        if gateSaves {
            await withCheckedContinuation { parkedSaves.append($0) }
        }
        if let failAllSaves { throw failAllSaves }
        if let error = failSaveFor[drop.id] { throw error }
        saved.append(drop.id)
        var stored = drop
        if let stampUid { stored.ownerUid = stampUid }
        return stored
    }

    func delete(_ drop: GeoDrop) async throws {
        deleteAttempts += 1
        if gateDeletes {
            await withCheckedContinuation { parkedDeletes.append($0) }
        }
        if let error = failDeleteFor[drop.id] { throw error }
    }
}

/// A local-store stand-in (also an actor — same isolation as production) whose
/// reads and deletes can be made to fail on demand. Round 6: conforms to the
/// diagnostics PROTOCOL, so the library branches it gates are genuinely
/// reachable from tests (the round-4 concrete downcast made them vacuous).
actor FlakyLocalStore: DropStore, LocalStoreDiagnostics {
    private var rows: [GeoDrop] = []
    private var throwOnLoad = false
    private var failDeleteIDs: Set<UUID> = []
    private var outcome: LocalLoadOutcome?
    private var warning: String?
    /// Round 14 (counsel own-3): the doubles reproduce production's FAILURE
    /// MODES, not only its isolation — every abort/rollback branch must be
    /// enterable by a test.
    private var failSave = false
    private var gateDeletes = false
    private var parkedDeletes: [CheckedContinuation<Void, Never>] = []

    func setThrowOnLoad(_ on: Bool) { throwOnLoad = on }
    func setFailDelete(_ ids: Set<UUID>) { failDeleteIDs = ids }
    func setFailSave(_ on: Bool) { failSave = on }
    func setGateDeletes(_ on: Bool) { gateDeletes = on }
    var parkedDeleteCount: Int { parkedDeletes.count }

    func releaseAllDeletes() {
        let parked = parkedDeletes
        parkedDeletes = []
        parked.forEach { $0.resume() }
    }

    func lastLoadOutcome() async -> LocalLoadOutcome? { outcome }
    func lastLoadReadWarning() async -> String? { warning }
    func acknowledgeIncident() async { warning = nil }

    func loadDrops(near location: CLLocation?, radius: CLLocationDistance) async throws -> [GeoDrop] {
        if throwOnLoad {
            outcome = .readFailed
            warning = "disk unreadable — test double"
            throw NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "disk unreadable"]
            )
        }
        outcome = .clean(rowCount: rows.count)
        warning = nil
        return rows
    }

    @discardableResult
    func save(_ drop: GeoDrop) async throws -> GeoDrop {
        if failSave {
            throw NSError(
                domain: "test", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "save failed"]
            )
        }
        rows.removeAll { $0.id == drop.id }
        rows.append(drop)
        return drop
    }

    func delete(_ drop: GeoDrop) async throws {
        if gateDeletes {
            await withCheckedContinuation { parkedDeletes.append($0) }
        }
        if failDeleteIDs.contains(drop.id) {
            throw NSError(
                domain: "test", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "delete failed"]
            )
        }
        rows.removeAll { $0.id == drop.id }
    }
}
