import CoreLocation
import CryptoKit
import FirebaseAuth
import Foundation
import os

/// Storage backend for drops. Local JSON is always active (offline cache / no-account
/// mode); CloudKit joins in Wave 3 when `AppConfig.cloudKitEnabled` is true.
/// Calls cross the main-actor library boundary, so implementations must own
/// mutable state in an actor or be immutable and safe to share between tasks.
protocol DropStore: Sendable {
    /// Returns the CANONICAL stored form — a backend that stamps fields during
    /// the write (Firebase stamps `ownerUid`, round 8 counsel B1) reports them
    /// back so the caller can persist server truth instead of guessing it.
    @discardableResult
    func save(_ drop: GeoDrop) async throws -> GeoDrop
    func delete(_ drop: GeoDrop) async throws
}

/// Complete unpaged reads for local storage and legacy cloud backends. A
/// location is deliberately absent: this is a library sync, not discovery.
protocol LibraryDropLoading: DropStore {
    func loadLibraryDrops() async throws -> [GeoDrop]
}

/// Round 8 (counsel B3/state-1/state-2): a NEGATIVE fact ("the server no
/// longer holds this document") requires a positive per-document check that
/// only the server may answer. Query set-differences and cache-satisfiable
/// reads are structurally forbidden as evidence — an offline delete would
/// count its own unflushed write as proof and retire its own tombstone.
protocol DropAbsenceVerifying: Sendable {
    /// True ONLY when the SERVER answered and the document does not exist.
    /// Cache-served reads, network failures, permission denials → false.
    func serverConfirmsAbsent(_ id: UUID) async -> Bool
    /// Round 10 (counsel seams-1c/own-3): whether the DEPLOYED backend can
    /// answer an absent-document read at all. A denied capability is retried
    /// after a bounded interval so a rules rollout can recover this session.
    /// Offline failure is never treated as a permanent policy verdict.
    func probeAbsenceCapability() async -> AbsenceCapability
}

/// The three honest answers to "can the server tell us a document is gone?".
enum AbsenceCapability: Sendable {
    /// The server answered an absent-doc read — retirement probes work.
    case answers
    /// The current request was denied. This does not identify the rules release
    /// and must be rechecked after a policy change or a different auth session.
    case denied
    /// Offline or transient failure — unknown, try again next refresh.
    case inconclusive
}

/// Round 10 (counsel ux-1): a cloud read that carries its PROVENANCE.
/// Firestore serves `getDocuments()` from the local cache when offline, so
/// "the call returned" is not evidence a server was consulted — and no
/// positive user-facing claim may be earned by a cache-served read.
/// Round 12 (counsel SEAMS-lens-1): provenance is PER ROW as well — a
/// server-served query snapshot still merges the local mutation queue into
/// its results (latency compensation), so rows with pending writes appear in
/// it without the server ever having acknowledged them. Only rows in
/// `serverConfirmedIDs` (no pending writes) may produce the acked fact.
/// This is a value snapshot; the SDK's mutable query objects never cross the
/// library boundary.
struct CloudRead: Sendable {
    var drops: [GeoDrop]
    var servedFromCache: Bool
    var serverConfirmedIDs: Set<UUID>
}

/// Adopted by unpaged cloud stores that can report read provenance. The plain
/// library read stays for display merging; THIS is what evidence keys on.
protocol ProvenancedDropStore: LibraryDropLoading {
    func loadLibraryDropsWithProvenance() async throws -> CloudRead
}

/// A bounded owner collection read. The IDs describe every query document,
/// including a row whose payload could not decode; they form the cursor and
/// are not absence evidence for any other document.
struct OwnerLibraryPage: Sendable {
    let read: CloudRead
    let documentIDs: [String]
    let reachedEnd: Bool
    /// A local pending create/delete can change page membership or length;
    /// no cursor or completion fact is earned from that overlaid result.
    let containsPendingWrites: Bool
    let unreadableDocumentCount: Int
}

protocol OwnerLibraryPaging: DropStore {
    func loadOwnerPage(after documentID: String?, limit: Int) async throws -> OwnerLibraryPage
}

struct OwnerSyncProgress: Equatable, Sendable {
    let loadedRows: Int
    let pagesRead: Int
    let documentsRead: Int
    let lastPageLatencyMilliseconds: Double
    let isComplete: Bool
}

/// Firestore reads at most this many owner documents in one refresh. Document
/// IDs are immutable, so a cursor survives edits that change drop content or
/// geographic position. A completed sweep starts again at the first ID on
/// the next refresh, eventually picking up inserts behind the old cursor.
enum OwnerLibraryPagingPolicy {
    static let pageSize = 64

    static func mayAdvance(_ page: OwnerLibraryPage, pendingLocalOperations: Bool) -> Bool {
        !page.read.servedFromCache && !page.containsPendingWrites && !pendingLocalOperations
    }

    enum PageError: LocalizedError {
        case invalidOrder
        case tooManyDocuments
        case noForwardProgress

        var errorDescription: String? {
            switch self {
            case .invalidOrder: return "The owner library page was out of order — retry sync"
            case .tooManyDocuments: return "The owner library page exceeded its limit — retry sync"
            case .noForwardProgress: return "The owner library page could not advance — retry sync"
            }
        }
    }

    static func nextCursor(after cursor: String?, page: OwnerLibraryPage) throws -> String? {
        guard page.documentIDs.count <= pageSize else { throw PageError.tooManyDocuments }
        guard page.documentIDs == page.documentIDs.sorted() else {
            throw PageError.invalidOrder
        }
        let forward = page.documentIDs.last { id in cursor.map { id > $0 } ?? true }
        if forward == nil && (!page.reachedEnd || !page.documentIDs.isEmpty) {
            throw PageError.noForwardProgress
        }
        return page.reachedEnd ? nil : forward
    }
}

/// Errors the sync layer must distinguish (Wave C, counsel SWE-3): "no account
/// yet" keeps a write pending for the auth-ready reconcile; an owner mismatch
/// is terminal-but-visible (counsel round 2, C4/C15); anything else is a real
/// failure the user must see.
enum DropStoreError: LocalizedError {
    case notSignedIn
    case ownedByAnotherAccount
    /// Round 6: the server did not answer within the ack deadline. The write
    /// IS durably staged in Firestore's local queue — the item stays pending
    /// and the next reconcile re-checks; this is not a failure to show.
    case ackTimedOut
    /// Round 8 (counsel B1/state-3): the server ANSWERED and refused with a
    /// non-retryable code. Terminal — retrying the same write can only produce
    /// the same refusal; the drop must leave "pending" and become visibly
    /// failed, exactly like `ownedByAnotherAccount`.
    case refusedByServer(reason: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Waiting for the account connection"
        case .ownedByAnotherAccount:
            return "A drop from a previous account connection can't sync from this one"
        case .ackTimedOut:
            return "Waiting for the connection"
        case .refusedByServer(let reason):
            return reason
        }
    }
}

/// Round 6 (counsel arui-3/arui-4, round-5 cross-cutting): the machine-checkable
/// verdict of a local load. Destructive decisions (the orphan reap) and user
/// banners key on THIS, never on a user-facing string — a string is
/// simultaneously too permissive (nil after an absent file, or after a failed
/// journal write) and too restrictive (sticky incident) for a data-destroying
/// gate.
enum LocalLoadOutcome: Equatable, Sendable {
    /// File present, every row decoded. `rowCount` may legitimately be 0.
    case clean(rowCount: Int)
    /// File present; some rows skipped (preserved in a sidecar). IDs are
    /// reported only where their field still decoded; `skipped` includes
    /// entries with no recoverable identifier.
    case skippedRows(loaded: Int, skipped: Int, lostIDs: [UUID])
    /// Whole file unreadable; quarantined.
    case quarantinedWholeFile
    /// No store file exists. NOT proof that data is gone — never reap on it.
    case absentFile
    /// The read itself threw before decoding.
    case readFailed
}

/// Round 6 (counsel round-5 tests finding): the diagnostics seam is a
/// PROTOCOL, so test doubles can adopt it and the branches it gates are
/// reachable from tests — the old `as? LocalDropStore` concrete downcast made
/// two round-4 tests silently vacuous.
protocol LocalStoreDiagnostics: AnyObject, Sendable {
    func lastLoadOutcome() async -> LocalLoadOutcome?
    func lastLoadReadWarning() async -> String?
    func lastStorageIncident() async -> StorageIncidentObservation?
    /// User acknowledged the incident banner — resolve the journal.
    func acknowledgeIncident() async
}

extension LocalStoreDiagnostics {
    func lastStorageIncident() async -> StorageIncidentObservation? { nil }
}

/// An observation describes what the local reader actually established. A
/// whole-file failure has unknown extent; a skipped row can have no decodable
/// id. Neither state proves that the original bytes were irreversibly lost.
struct StorageIncidentObservation: Sendable {
    enum Kind: String, Codable, Sendable { case skippedRows, wholeFile, readFailure }
    let identity: String
    let kind: Kind
    let unreadableIDs: Set<UUID>
    let unidentifiedRowCount: Int?
}

/// JSON-file persistence in Application Support.
///
/// Wave C (counsel SWE-8): an `actor`, so every load-modify-write is serialized
/// by construction. The old non-isolated class ran read-modify-write on the
/// cooperative pool from independent Tasks — two slider releases within ~ms
/// could clobber each other's write (an edit that "didn't stick", or a freshly
/// created drop vanishing from disk).
actor LocalDropStore: LibraryDropLoading, LocalStoreDiagnostics {
    private let fileURL: URL
    nonisolated let lossLedgerURL: URL
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "store")
    /// Transient verdict of the LAST load (skipped-rows message; nil when clean).
    private var pendingReadWarning: String?
    private var acknowledgementError: String?
    /// Round 6: the machine-checkable outcome of the last load.
    private var lastOutcome: LocalLoadOutcome?
    private var lastObservation: StorageIncidentObservation?
    /// A save/delete must never replace unreadable bytes unless an exact
    /// recovery copy is already on disk, or the whole file moved to quarantine.
    private var canRewriteAfterLoad = true

    /// Round 4 (counsel sync-2/flows-2): destructive outcomes are INCIDENTS,
    /// journaled durably at the moment of destruction — never a level
    /// recomputed from the most recent read, because the recovery action
    /// itself (quarantining the file) erases the evidence. The incident note
    /// lives on disk next to the store and survives relaunches. Round 10
    /// (counsel own-1): it is retired ONLY by the user's acknowledgement —
    /// never auto-expired by a later clean load, because "the file reads
    /// clean now" says nothing about the rows that were already destroyed.
    private var incidentNoteURL: URL { fileURL.appendingPathExtension("incident") }

    /// `fileURL` override exists for tests; default is Application Support.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            self.lossLedgerURL = fileURL.appendingPathExtension("lossledger")
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("AugmentMeReality", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("drops.json")
        self.lossLedgerURL = self.fileURL.appendingPathExtension("lossledger")
    }

    /// Wave C (counsel SWE-9): one bad row must never wipe the library.
    /// Rows decode individually; bad ones are skipped, counted, preserved.
    private struct FailableDrop: Decodable {
        let drop: GeoDrop?
        /// The row's identity even when its body failed to decode — the loss
        /// ledger records WHICH drops were lost, not only how many.
        let id: UUID?
        private enum IDKey: String, CodingKey { case id }
        init(from decoder: Decoder) {
            // Counsel round 2 (C9): a row without a stable identity cannot be
            // safely updated or deleted — route id-less rows through the same
            // visible quarantine as type-mismatched ones.
            guard let container = try? decoder.container(keyedBy: IDKey.self),
                  let rowID = try? container.decode(UUID.self, forKey: .id) else {
                drop = nil
                id = nil
                return
            }
            id = rowID
            drop = try? GeoDrop(from: decoder)
        }
    }

    func loadLibraryDrops() async throws -> [GeoDrop] {
        try readDropsFromDisk()
    }

    /// Keep the read-modify-write path inside one actor turn. An `await` in
    /// save/delete would let another operation enter after the read and before
    /// the write, even though the file operations themselves are synchronous.
    private func readDropsFromDisk() throws -> [GeoDrop] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Round 4 (sync-2): an absent file clears only the TRANSIENT
            // warning — a journaled incident survives ("the file vanished" is
            // not evidence of health; the quarantine is what made it vanish).
            pendingReadWarning = nil
            lastOutcome = .absentFile
            lastObservation = nil
            canRewriteAfterLoad = true
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Round 4 (sync-3): a read failure is itself a visible incident,
            // recorded BEFORE the rethrow so no caller can lose it.
            lastOutcome = .readFailed
            canRewriteAfterLoad = false
            let failure = error as NSError
            lastObservation = StorageIncidentObservation(
                identity: "read:\(contentDigest(Data("\(fileURL.path):\(failure.domain):\(failure.code)".utf8)))",
                kind: .readFailure, unreadableIDs: [], unidentifiedRowCount: nil
            )
            let message = "Your saved drops couldn't be read — check free space and relaunch"
            pendingReadWarning = message
            writeIncident(message)
            throw error
        }
        do {
            let rows = try JSONDecoder().decode([FailableDrop].self, from: data)
            let drops = rows.compactMap(\.drop)
            let dropped = rows.count - drops.count
            if dropped > 0 {
                let lostIDs = rows.filter { $0.drop == nil }.compactMap(\.id)
                lastOutcome = .skippedRows(
                    loaded: drops.count, skipped: dropped, lostIDs: lostIDs
                )
                let identity = "rows:\(contentDigest(data))"
                lastObservation = StorageIncidentObservation(
                    identity: identity, kind: .skippedRows,
                    unreadableIDs: Set(lostIDs),
                    unidentifiedRowCount: dropped - lostIDs.count
                )
                let preserved = preserveUnreadable(data)
                canRewriteAfterLoad = preserved
                // Round 14 (counsel surf-lens-1): an ACKNOWLEDGED incident is
                // suppressed by content digest — the banner stays down for
                // exactly these bytes, and NOTHING is deleted. New or changed
                // bad content re-raises the incident.
                if acknowledgedDigest() == identity
                    || acknowledgedDigest() == shortContentDigest(data) {
                    pendingReadWarning = preserved ? nil
                        : "Unreadable saved drops couldn't be backed up — editing is paused"
                } else {
                    // Round 10 (counsel lens-6): the "kept on disk" claim is
                    // made only when the sidecar write actually succeeded.
                    let noun = dropped == 1 ? "1 saved drop" : "\(dropped) saved drops"
                    let message = preserved
                        ? "\(noun) couldn't be read (original kept on disk)"
                        : "\(noun) couldn't be read"
                    pendingReadWarning = message
                    writeIncident(message)
                }
            } else {
                pendingReadWarning = nil
                lastOutcome = .clean(rowCount: drops.count)
                lastObservation = nil
                canRewriteAfterLoad = true
                // Round 10 (counsel own-1): NO auto-clear of the journaled
                // incident here — a clean load after a quarantine is the
                // library minus the destroyed rows reading cleanly; only the
                // user's acknowledgement retires the incident.
            }
            return drops
        } catch {
            // Whole-file JSON failure. Quarantine (timestamped — a second
            // failure can't overwrite the first backup, SWE-9) and journal the
            // incident durably (round 4, C7/sync-2: an emptied library must
            // never be silent, not even after the next load).
            let quarantine = fileURL.appendingPathExtension(
                "corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
            )
            // Round 10 (counsel lens-6): the backup claim is checked, never
            // asserted over a swallowed failure.
            let backedUp = (try? FileManager.default.moveItem(at: fileURL, to: quarantine)) != nil
            canRewriteAfterLoad = backedUp
            log.error("drops.json unreadable — quarantine \(backedUp ? "kept" : "FAILED"): \(quarantine.lastPathComponent)")
            lastOutcome = .quarantinedWholeFile
            let identity = "whole:\(contentDigest(data))"
            lastObservation = StorageIncidentObservation(
                identity: identity, kind: .wholeFile,
                unreadableIDs: [], unidentifiedRowCount: nil
            )
            // Round 6 (counsel flows-5 composition): no raw filename in user
            // copy — the log carries the diagnostics, the user gets meaning.
            if acknowledgedDigest() != identity {
                let message = backedUp
                    ? "Your saved drops couldn't be read — a backup was kept on this device"
                    : "Your saved drops couldn't be read"
                pendingReadWarning = message
                writeIncident(message)
            } else {
                pendingReadWarning = nil
            }
            return []
        }
    }

    /// Round 6: the machine-checkable verdict of the last load.
    func lastLoadOutcome() async -> LocalLoadOutcome? { lastOutcome }
    func lastStorageIncident() async -> StorageIncidentObservation? { lastObservation }

    /// Round 6 (counsel concurrency-5): the user may resolve the incident from
    /// the banner — a legitimately empty library must not carry the corruption
    /// banner forever with nothing to tap.
    /// Round 14 (counsel surf-lens-1 — Dismiss must NEVER destroy data): the
    /// round-12 rewrite-on-acknowledge deleted the unreadable rows on a tap
    /// with no consent. Acknowledgement now suppresses the banner by CONTENT
    /// DIGEST: the incident stays down for exactly these bytes (no re-journal
    /// loop, counsel SURF-lens-5), the rows stay on disk untouched, and any
    /// NEW bad content re-raises the incident. The loss itself is recorded
    /// durably in the library's ledger regardless.
    func acknowledgeIncident() async {
        do {
            if let identity = lastObservation?.identity {
                try Data(identity.utf8).write(to: acknowledgedDigestURL, options: .atomic)
            }
            if FileManager.default.fileExists(atPath: incidentNoteURL.path) {
                try FileManager.default.removeItem(at: incidentNoteURL)
            }
            pendingReadWarning = nil
            acknowledgementError = nil
        } catch {
            acknowledgementError = "Couldn't save the storage warning acknowledgement — please try again"
            log.error("Storage warning acknowledgement failed: \(error.localizedDescription)")
        }
    }

    private var acknowledgedDigestURL: URL {
        fileURL.appendingPathExtension("ackdigest")
    }

    private func acknowledgedDigest() -> String? {
        guard let data = try? Data(contentsOf: acknowledgedDigestURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func contentDigest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }

    private func shortContentDigest(_ data: Data) -> String {
        String(contentDigest(data).prefix(16))
    }

    /// Counsel round 2 (C6/C14/C24): exactly one sidecar per DISTINCT
    /// unreadable content — named by content digest, so repeated loads (and
    /// relaunches) of the same bad bytes never accumulate copies.
    /// Returns whether the original bytes are actually preserved on disk —
    /// the caller's user-facing claim depends on it (round 10, counsel lens-6).
    private func preserveUnreadable(_ data: Data) -> Bool {
        let sidecar = fileURL.appendingPathExtension("unreadable-\(shortContentDigest(data))")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            return (try? Data(contentsOf: sidecar)) == data
        }
        do {
            try data.write(to: sidecar, options: .atomic)
            guard try Data(contentsOf: sidecar) == data else { return false }
            log.error("Unreadable rows in drops.json — original kept at \(sidecar.lastPathComponent)")
            return true
        } catch {
            log.error("Unreadable rows in drops.json — sidecar write FAILED: \(error.localizedDescription)")
            return false
        }
    }

    private func writeIncident(_ message: String) {
        try? Data(message.utf8).write(to: incidentNoteURL, options: .atomic)
    }

    /// The user-facing warning: a journaled incident outranks the transient
    /// last-load result; nil only when there is neither.
    func lastLoadReadWarning() -> String? {
        if let acknowledgementError { return acknowledgementError }
        if let data = try? Data(contentsOf: incidentNoteURL),
           let incident = String(data: data, encoding: .utf8), !incident.isEmpty {
            return incident
        }
        return pendingReadWarning
    }

    @discardableResult
    func save(_ drop: GeoDrop) async throws -> GeoDrop {
        // Counsel round 2 (C5): a throwing read must RETHROW — collapsing it to
        // [] and persisting would atomically erase the whole library.
        var drops = try readDropsFromDisk()
        guard canRewriteAfterLoad else { throw UnsafeLocalRewrite.unpreservedOriginal }
        drops.removeAll { $0.id == drop.id }
        drops.append(drop)
        try persist(drops)
        return drop
    }

    func delete(_ drop: GeoDrop) async throws {
        var drops = try readDropsFromDisk()
        guard canRewriteAfterLoad else { throw UnsafeLocalRewrite.unpreservedOriginal }
        drops.removeAll { $0.id == drop.id }
        try persist(drops)
    }

    private func persist(_ drops: [GeoDrop]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(drops)
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum UnsafeLocalRewrite: LocalizedError {
    case unpreservedOriginal

    var errorDescription: String? {
        "The unreadable original couldn't be backed up, so this change wasn't saved"
    }
}

/// The evidence and the user's acknowledgement live in different fields.
/// Keeping old records lets a restored row retire without erasing another
/// row's incident or making identical corrupt bytes new again after Clear.
private struct StorageIncidentRecord: Codable, Equatable {
    let identity: String
    let kind: StorageIncidentObservation.Kind
    var unreadableIDs: Set<UUID>
    var possiblyAffectedIDs: Set<UUID>
    /// nil means the affected row count cannot be established from the file.
    var unidentifiedRowCount: Int?

    var isUnresolved: Bool {
        !unreadableIDs.isEmpty || !possiblyAffectedIDs.isEmpty
            || unidentifiedRowCount == nil || unidentifiedRowCount! > 0
    }
}

private struct StorageIncidentLedgerState: Codable, Equatable {
    var version = 1
    var records: [StorageIncidentRecord] = []
    var acknowledgedIdentities: Set<String> = []
    /// Inventory of rows actually saved/read locally, including received
    /// drops. It is evidence for a later whole-file quarantine, not a claim
    /// that every such row was destroyed.
    var knownLocalIDs: Set<UUID> = []
}

/// Tiny atomic JSON journal kept beside the local store. A failed write does
/// not mutate the in-memory ledger, so Clear can never claim to have stuck
/// when the next process would show the same incident again.
private final class StorageIncidentLedger {
    private let url: URL
    private(set) var state: StorageIncidentLedgerState

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(
                StorageIncidentLedgerState.self, from: Data(contentsOf: url)
            )
        } else {
            state = StorageIncidentLedgerState()
        }
    }

    var visibleRecords: [StorageIncidentRecord] {
        state.records.filter {
            $0.isUnresolved && !state.acknowledgedIdentities.contains($0.identity)
        }
    }

    var visibleIDs: Set<UUID> {
        visibleRecords.reduce(into: Set<UUID>()) {
            $0.formUnion($1.unreadableIDs)
            $0.formUnion($1.possiblyAffectedIDs)
        }
    }

    func migrateLegacyIDs(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try change { state in
            for id in ids {
                let identity = "legacy:\(id.uuidString)"
                guard !state.records.contains(where: { $0.identity == identity }) else { continue }
                state.records.append(StorageIncidentRecord(
                    identity: identity, kind: .skippedRows,
                    unreadableIDs: [id], possiblyAffectedIDs: [], unidentifiedRowCount: 0
                ))
            }
        }
    }

    func observe(_ observation: StorageIncidentObservation?, localIDs: Set<UUID>?,
                 quarantine: Bool) throws {
        try change { state in
            if let localIDs {
                let stillUnreadable = observation?.unreadableIDs ?? []
                let restored = localIDs.subtracting(stillUnreadable)
                for index in state.records.indices {
                    state.records[index].unreadableIDs.subtract(restored)
                    state.records[index].possiblyAffectedIDs.subtract(restored)
                }
                state.knownLocalIDs = localIDs
            }
            guard let observation else { return }
            if let index = state.records.firstIndex(where: { $0.identity == observation.identity }) {
                // An old observation retains its recovery history. A second
                // sighting of identical bytes does not re-add a restored row.
                if state.records[index].kind == .readFailure {
                    state.records[index].possiblyAffectedIDs.formUnion(state.knownLocalIDs)
                }
                return
            }
            state.records.append(StorageIncidentRecord(
                identity: observation.identity, kind: observation.kind,
                unreadableIDs: observation.unreadableIDs,
                possiblyAffectedIDs: quarantine ? state.knownLocalIDs : [],
                unidentifiedRowCount: observation.unidentifiedRowCount
            ))
        }
    }

    func localSaveRestored(_ id: UUID) throws {
        try change { state in
            state.knownLocalIDs.insert(id)
            for index in state.records.indices {
                state.records[index].unreadableIDs.remove(id)
                state.records[index].possiblyAffectedIDs.remove(id)
            }
        }
    }

    func localDelete(_ id: UUID) throws {
        try change { _ = $0.knownLocalIDs.remove(id) }
    }

    func acknowledgeVisible() throws {
        let identities = Set(visibleRecords.map(\.identity))
        guard !identities.isEmpty else { return }
        try change { $0.acknowledgedIdentities.formUnion(identities) }
    }

    private func change(_ edit: (inout StorageIncidentLedgerState) -> Void) throws {
        var next = state
        edit(&next)
        guard next != state else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(next).write(to: url, options: .atomic)
        state = next
    }
}

/// App-facing façade: merges local + cloud stores and publishes the combined set.
///
/// Wave C sync honesty, round 4 shape (counsel sync-1..5, flows-1..5):
/// - Per-drop truth lives in per-drop state, never in shared last-writer-wins
///   slots: `pendingSyncIDs` (awaiting ack), `terminalSyncFailureIDs` (can
///   never sync — durable), `syncFailureReasons` (latest per-drop reason).
///   "Synced" is a COMPUTATION over those sets.
/// - The publish path carries the same generation discipline as the write
///   pipeline: every mutator bumps `refreshGeneration`, and an in-flight
///   refresh re-checks it after every await before touching published state.
/// - A refresh that cannot read local truth ABORTS (a replica that cannot
///   read its own log does not apply remote writes).
@MainActor
final class DropLibrary: ObservableObject {
    @Published private(set) var drops: [GeoDrop] = []
    /// Cloud READ failure from the most recent refresh (nil when reads are
    /// healthy). Round 4: this slot no longer carries write outcomes.
    @Published private(set) var lastSyncError: String?
    /// LOCAL persistence failure — set right before the throwing call rethrows.
    @Published private(set) var lastPersistError: String?
    /// Unreadable-rows / quarantine warning from the local store (journaled;
    /// survives relaunch until the library is clean and non-empty again).
    @Published private(set) var localReadWarning: String?
    /// Drops whose latest write the server has NOT yet acknowledged.
    @Published private(set) var pendingSyncIDs: Set<UUID> = []
    /// Round 4 (sync-1/flows-3): drops that can NEVER sync from this account
    /// connection. Durable; outranks "Synced" in every surface.
    @Published private(set) var terminalSyncFailureIDs: Set<UUID> = []
    /// Latest per-drop write-failure reason (session-scoped detail text).
    @Published private(set) var syncFailureReasons: [UUID: String] = [:]
    /// Cloud deletes not yet confirmed (durable tombstones; suppress
    /// resurrection in refresh merges). Round 6: retired when a successful
    /// cloud read confirms the row is GONE — "the disappearance of the
    /// condition that produced the verdict" is a legitimate retirement.
    @Published private(set) var pendingDeleteIDs: Set<UUID> = []
    /// Round 6 (counsel critical 2): deletes the server REFUSED repeatedly.
    /// No longer retried, no longer counted as in-progress — but they still
    /// suppress resurrection, and a server-confirmed absence (or an explicit
    /// re-receive) retires them.
    @Published private(set) var unresolvedDeleteIDs: Set<UUID> = []
    /// Round 8 (counsel B4/ux-4/flows-6): POSITIVE evidence that at least one
    /// full refresh completed with local truth provably clean and the cloud
    /// read answered. Until this is true every surface reports "checking",
    /// never "Synced" — the good state is earned, not a fallthrough.
    @Published private(set) var hasCompletedCleanRefresh = false
    /// A Firebase owner sweep advances by one bounded document-ID page per
    /// refresh. The count is unique decoded rows seen in this sweep, not a
    /// server total; the UI can offer an explicit continuation while incomplete.
    @Published private(set) var ownerSyncProgress: OwnerSyncProgress?
    /// Compatibility projection of IDs named by unresolved storage incidents.
    /// A whole-file incident may include previously saved candidates; these
    /// IDs do not assert irreversible loss. The file-backed ledger also keeps
    /// id-less and unknown-extent incidents that cannot appear in this set.
    @Published private(set) var lostRowIDs: Set<UUID> = []
    /// A journal write failure remains visible until a later successful
    /// operation; it cannot turn a failed Clear into a successful one.
    @Published private(set) var storageLedgerError: String?

    /// The profile uses this structured summary, so count-only and unknown-
    /// extent incidents never get described as a known number of lost drops.
    var storageProblemText: String? {
        guard let records = incidentLedger?.visibleRecords, !records.isEmpty else { return nil }
        if records.count == 1, let record = records.first {
            switch record.kind {
            case .wholeFile:
                return "Saved drops couldn't be read — the affected count is unknown"
            case .readFailure:
                return "Saved drops couldn't be read — check device storage and retry"
            case .skippedRows:
                let count = record.unreadableIDs.count + (record.unidentifiedRowCount ?? 0)
                if count > 0 {
                    return "\(count) saved drop\(count == 1 ? "" : "s") couldn't be read"
                }
            }
        }
        return "\(records.count) unresolved saved-data incident\(records.count == 1 ? "" : "s")"
    }

    private let local: LibraryDropLoading
    private let cloud: DropStore?
    private let defaults: UserDefaults
    /// Read on every command, including when a sheet has been open through an
    /// account change. Tests inject an identity without touching Firebase Auth.
    private let currentUID: @MainActor () -> String?
    private let incidentLedger: StorageIncidentLedger?
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "library")
    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    /// Counsel round 2 (C2/C18/C22): per-drop write generation — only the
    /// CURRENT generation may clear bookkeeping or report outcomes.
    private var syncGenerations: [UUID: UInt64] = [:]
    private var deleteTasks: [UUID: Task<Void, Never>] = [:]
    /// Round 8 (counsel process item): the delete pipeline carries the SAME
    /// generation discipline as the save pipeline — a superseded delete task
    /// (redeemed drop, newer delete) must not mutate state its successor owns.
    private var deleteGenerations: [UUID: UInt64] = [:]
    /// Round 4 (flows-4): refused deletes stop retrying after a few attempts
    /// per session — the tombstone stays (suppression is the load-bearing
    /// part), the retry noise stops.
    private var deleteAttempts: [UUID: Int] = [:]
    /// Round 4 (sync-4/concurrency-4/flows-1): publish-path generation.
    private var refreshGeneration: UInt64 = 0
    private var ownerPageCursor: String?
    private var ownerPageUID: String?
    private var ownerSweepSeenIDs: Set<UUID> = []
    private var ownerSweepPages = 0
    private var ownerSweepDocumentsRead = 0
    private var ownerSweepHadUnreadableRows = false
    private var ownerHasUnresolvedUnreadableRows = false
    /// Cloud-only rows fetched under an earlier UID must leave the in-memory
    /// view on account change; rows also on disk remain visible with their
    /// existing ownership markers.
    private var ownerCloudPublishedIDs: Set<UUID> = []
    private var staleOwnerCloudIDs: Set<UUID> = []
    private var lastSuccessfulLocalIDs: Set<UUID> = []
    /// Round 14 (counsel state-1/flows-lens-1 — CRITICAL): PER-ROW mutation
    /// epochs. remove()'s round-12 post-await guard keyed on the GLOBAL
    /// publish counter, so any concurrent refresh (including the round-12
    /// scene-active refresh) silently abandoned the delete AFTER the disk row
    /// was destroyed — no tombstone, no cloud delete, recipients' links left
    /// live. A mutator aborts only when ITS OWN row was touched by another
    /// mutator, never because the library published.
    private var rowGenerations: [UUID: UInt64] = [:]
    /// Round 14 (counsel seams-3): terminal verdicts are revalidated on the
    /// FIRST auth-ready pass of every session as well as on a uid change —
    /// the round-12 `changed` gate was structurally false on a fresh process.
    private var authReadyRan = false
    /// Round 10 (counsel seams-1b/lens-3): "the server has seen this id" as a
    /// FIRST-CLASS durable fact — set on every save ack and every server-served
    /// read that returns the row, cleared when a delete confirms. Deletes of
    /// ids the server never acked resolve to DONE instead of raising a
    /// cloud-copy alarm the deployed rules may never be able to clear.
    private var ackedCloudIDs: Set<UUID> = []
    /// Positive capability stays cached; denial expires so a rules rollout
    /// can recover without restarting. Inconclusive results never latch.
    private var knownAbsenceCapability: AbsenceCapability?
    private var deniedAbsenceRetryAt: TimeInterval?
    private let absenceProbeTime: () -> TimeInterval
    /// Round 12 (counsel FLOWS-lens-1): positive cloud provenance captured AT
    /// TOMBSTONE TIME, while the evidence still exists — a stamped ownerUid,
    /// a session ack, or a standing terminal verdict all prove the server has
    /// (or had) this document. The delete pipeline's give-up verdict keys on
    /// it: proven → visible unresolved alarm; unproven → resolved done.
    /// Priced explicitly (researcher): under the live v2 rules a proven-but-
    /// out-of-band-removed copy raises an alarm that cannot retire until the
    /// v3 deploy — an honest UNKNOWN, preferred over a silent false all-clear.
    private var cloudProvenIDs: Set<UUID> = []
    /// Round 12 (counsel own-B/FLOWS-lens-5 + SURF-lens-1 family): the uid
    /// sync evidence was earned under — the auth-ready pass resets evidence
    /// only when this actually changes, never on every launch.
    private var evidenceUid: String?
    private static let pendingDefaultsKey = "pendingSyncDropIDs"
    private static let pendingSyncOwnerDefaultsKey = "pendingSyncOwnerUIDs"
    private static let pendingDeleteDefaultsKey = "pendingDeleteDropIDs"
    private static let pendingDeleteOwnerDefaultsKey = "pendingDeleteOwnerUIDs"
    private static let terminalDefaultsKey = "terminalSyncDropIDs"
    private static let unresolvedDeleteDefaultsKey = "unresolvedDeleteDropIDs"
    private static let ackedDefaultsKey = "ackedCloudDropIDs"
    private static let cloudProvenDefaultsKey = "cloudProvenDropIDs"
    private static let provisionalOwnerDefaultsKey = "provisionalOwnerDropIDs"
    private static let lostRowsDefaultsKey = "lostRowIDs"
    /// Round 12 (counsel own-B): a destructive local-read outcome, remembered
    /// durably and INDEPENDENTLY of the journal file — a failed journal write
    /// (or an acknowledged one) must not let an absent store file present as
    /// a brand-new install and earn "Synced" over a destroyed library.
    private static let incidentMemoryKey = "hadLocalReadIncident"
    /// A remote delete is replayable only under the identity which requested
    /// it. The old ID-only tombstones cannot prove that identity after a
    /// relaunch and remain unresolved until server absence can be verified.
    private var pendingDeleteOwners: [UUID: String] = [:]
    /// Ownerless legacy edits are bound to the UID under which the edit began.
    /// A later account cannot silently claim their pending cloud write.
    private var pendingSyncOwners: [UUID: String] = [:]
    /// A locally stamped owner on a brand-new row is an authorship claim, not
    /// evidence that the server has ever accepted the document.
    private var provisionalOwnerIDs: Set<UUID> = []
    private var localDiagnostics: LocalStoreDiagnostics? {
        local as? LocalStoreDiagnostics
    }

    /// Store + defaults injection exists for tests (counsel concurrency-5: a
    /// test suite must NEVER touch the shipping app's persisted state);
    /// production picks the cloud store by configuration.
    init(
        localStore: LibraryDropLoading = LocalDropStore(),
        cloudStore: DropStore? = AppConfig.firebaseConfigured
            ? FirebaseDropStore()
            : (AppConfig.cloudKitEnabled ? CloudKitDropStore() : nil),
        defaults: UserDefaults = .standard,
        incidentLedgerURL: URL? = nil,
        absenceProbeTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        currentUID: @escaping @MainActor () -> String? = {
            AppConfig.firebaseConfigured ? Auth.auth().currentUser?.uid : nil
        }
    ) {
        self.local = localStore
        self.cloud = cloudStore
        self.defaults = defaults
        self.currentUID = currentUID
        self.absenceProbeTime = absenceProbeTime
        let ledgerURL = incidentLedgerURL ?? (localStore as? LocalDropStore)?.lossLedgerURL
        if let ledgerURL {
            do {
                incidentLedger = try StorageIncidentLedger(url: ledgerURL)
            } catch {
                incidentLedger = nil
                storageLedgerError = "Saved-data incident history couldn't be read — check device storage"
            }
        } else {
            incidentLedger = nil
        }
        let pending = defaults.stringArray(forKey: Self.pendingDefaultsKey) ?? []
        pendingSyncIDs = Set(pending.compactMap(UUID.init(uuidString:)))
        let syncOwners = defaults.dictionary(forKey: Self.pendingSyncOwnerDefaultsKey) as? [String: String] ?? [:]
        pendingSyncOwners = Dictionary(uniqueKeysWithValues: syncOwners.compactMap { key, uid in
            guard let id = UUID(uuidString: key), !uid.isEmpty else { return nil }
            return (id, uid)
        })
        let deletes = defaults.stringArray(forKey: Self.pendingDeleteDefaultsKey) ?? []
        pendingDeleteIDs = Set(deletes.compactMap(UUID.init(uuidString:)))
        let owners = defaults.dictionary(forKey: Self.pendingDeleteOwnerDefaultsKey) as? [String: String] ?? [:]
        pendingDeleteOwners = Dictionary(uniqueKeysWithValues: owners.compactMap { key, uid in
            guard let id = UUID(uuidString: key), !uid.isEmpty else { return nil }
            return (id, uid)
        })
        let terminal = defaults.stringArray(forKey: Self.terminalDefaultsKey) ?? []
        terminalSyncFailureIDs = Set(terminal.compactMap(UUID.init(uuidString:)))
        let unresolved = defaults.stringArray(forKey: Self.unresolvedDeleteDefaultsKey) ?? []
        unresolvedDeleteIDs = Set(unresolved.compactMap(UUID.init(uuidString:)))
        let acked = defaults.stringArray(forKey: Self.ackedDefaultsKey) ?? []
        ackedCloudIDs = Set(acked.compactMap(UUID.init(uuidString:)))
        let proven = defaults.stringArray(forKey: Self.cloudProvenDefaultsKey) ?? []
        cloudProvenIDs = Set(proven.compactMap(UUID.init(uuidString:)))
        let provisional = defaults.stringArray(forKey: Self.provisionalOwnerDefaultsKey) ?? []
        provisionalOwnerIDs = Set(provisional.compactMap(UUID.init(uuidString:)))
        let lost = defaults.stringArray(forKey: Self.lostRowsDefaultsKey) ?? []
        let legacyIDs = Set(lost.compactMap(UUID.init(uuidString:)))
        if let incidentLedger {
            do {
                try incidentLedger.migrateLegacyIDs(legacyIDs)
                if !legacyIDs.isEmpty { defaults.removeObject(forKey: Self.lostRowsDefaultsKey) }
                lostRowIDs = incidentLedger.visibleIDs
            } catch {
                lostRowIDs = legacyIDs.union(incidentLedger.visibleIDs)
                storageLedgerError = "Saved-data incident history couldn't be updated — check device storage"
            }
        } else {
            lostRowIDs = legacyIDs
        }
    }

    /// Round 6: the "Uploading N…" count includes only drops that can actually
    /// be pushed — a pending id with no loadable row is a problem, never
    /// progress (counsel flows-5).
    var uploadingCount: Int {
        pendingSyncIDs.filter { id in
            guard let drop = drops.first(where: { $0.id == id }) else { return false }
            let role = DropOwnershipRole(drop: drop, currentUID: activeUID)
            return (role == .owned || role == .legacyLocal)
                && !terminalSyncFailureIDs.contains(id)
        }.count
    }

    /// Round 8 (counsel ux-4): pending writes whose row cannot be loaded.
    /// Round 6 removed these from the progress count; removing them from every
    /// surface turned "we can't read our own outbox" into a false all-clear.
    /// They are a PROBLEM count — never progress, never silence.
    var unpushablePendingCount: Int {
        pendingSyncIDs.count - uploadingCount
    }

    func refreshLibrary() async {
        // Round 4 (sync-4): every mutator bumps the generation; this refresh
        // re-checks after EVERY await and aborts if it was superseded — a
        // stale snapshot must never be published over newer state.
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let requestUID = activeUID
        if cloud is OwnerLibraryPaging {
            if ownerPageUID != requestUID {
                staleOwnerCloudIDs.formUnion(ownerCloudPublishedIDs)
                // Hide known cloud-only rows BEFORE the local read awaits. If
                // that read fails, the previous account's rows must still
                // leave this account's in-memory view. Keep known local rows
                // and pending local edits until disk can be read again.
                let cloudOnly = ownerCloudPublishedIDs
                    .subtracting(lastSuccessfulLocalIDs)
                    .subtracting(pendingSyncIDs)
                drops.removeAll { cloudOnly.contains($0.id) }
                ownerCloudPublishedIDs = []
                ownerPageUID = requestUID
                hasCompletedCleanRefresh = false
                ownerHasUnresolvedUnreadableRows = false
                resetOwnerSweep()
            } else if ownerSyncProgress?.isComplete == true {
                // The next refresh starts another pass. New IDs inserted
                // behind the previous cursor are then reachable.
                resetOwnerSweep()
                hasCompletedCleanRefresh = false
            }
        }

        var merged: [UUID: GeoDrop] = [:]
        var localOutcome: LocalLoadOutcome?
        var localLoadedIDs: Set<UUID> = []
        do {
            let localDrops = try await local.loadLibraryDrops()
            guard refreshGeneration == generation else { return }
            for drop in localDrops { merged[drop.id] = drop }
            localLoadedIDs = Set(localDrops.map(\.id))
            lastSuccessfulLocalIDs = localLoadedIDs
        } catch {
            // Round 4 (sync-3): a sync pass that cannot read local truth must
            // ABORT, not proceed. Round 6 (counsel :281 ×3): the failure
            // branch honors the same generation contract as every other await.
            let warning = await localDiagnostics?.lastLoadReadWarning()
            guard refreshGeneration == generation else { return }
            // Round 14 (counsel flows-lens-4 + state-2): this early return
            // never reached the memory switch below, so a read failure —
            // the one case whose JOURNAL write also tends to fail — was
            // never remembered. Record it here, and revoke the all-clear.
            defaults.set(true, forKey: Self.incidentMemoryKey)
            hasCompletedCleanRefresh = false
            localReadWarning = warning
                ?? "Your saved drops couldn't be read — pull to retry"
            let observation = await localDiagnostics?.lastStorageIncident()
            guard refreshGeneration == generation else { return }
            recordStorageObservation(observation, localIDs: nil, quarantine: true)
            return
        }
        if let localDiagnostics {
            let warning = await localDiagnostics.lastLoadReadWarning()
            guard refreshGeneration == generation else { return }
            localReadWarning = warning
            let outcome = await localDiagnostics.lastLoadOutcome()
            guard refreshGeneration == generation else { return }
            localOutcome = outcome
            let observation = await localDiagnostics.lastStorageIncident()
            guard refreshGeneration == generation else { return }
            let readIDs: Set<UUID>? = {
                switch outcome {
                case .clean(_)?, .skippedRows(_, _, _)?: return localLoadedIDs
                default: return nil
                }
            }()
            recordStorageObservation(
                observation, localIDs: readIDs,
                quarantine: outcome == .quarantinedWholeFile
            )
        }
        guard refreshGeneration == generation, activeUID == requestUID else { return }
        // Round 10 (counsel own-2) + round 12 (counsel STATE-lens-4/FLOWS-
        // lens-4): TWO-PHASE PUBLISH, and phase 1 is ADDITIVE — it seeds from
        // what is already published (keeping cloud-contributed rows) and
        // overlays the fresh local load. A partial or superseded pass can
        // therefore never blink cloud rows out, tear down their AR entities,
        // or strand the library on "No drops yet". An owner page also preserves
        // values learned on earlier pages when local disk has an older copy.
        var phase1 = Dictionary(uniqueKeysWithValues: drops.map { ($0.id, $0) })
        for id in staleOwnerCloudIDs where !localLoadedIDs.contains(id) { phase1[id] = nil }
        staleOwnerCloudIDs = []
        for (id, drop) in merged {
            // A server edit learned on an earlier owner page remains newer
            // than its stale local disk copy until that ID is revisited.
            // An unacknowledged local edit always wins instead.
            if cloud is OwnerLibraryPaging,
               ownerCloudPublishedIDs.contains(id),
               !pendingSyncIDs.contains(id), phase1[id] != nil { continue }
            phase1[id] = drop
        }
        for id in pendingDeleteIDs { phase1[id] = nil }
        for id in unresolvedDeleteIDs { phase1[id] = nil }
        drops = phase1.values.sorted { $0.createdAt > $1.createdAt }

        // Round 10 (counsel ux-1): the read carries PROVENANCE. Merging
        // cache-served rows is fine (display value); EVIDENCE requires the
        // server to have actually answered.
        var cloudReadCompleted = false
        var cloudReadServerServed = false
        var currentPageIDs: Set<UUID> = []
        if let cloud {
            do {
                let read: CloudRead
                if let owner = cloud as? OwnerLibraryPaging {
                    guard let requestUID else { throw DropStoreError.notSignedIn }
                    let pendingAtStart = hasPendingOwnerMutation(
                        for: requestUID, localRows: merged
                    )
                    let pageStartedAt = ProcessInfo.processInfo.systemUptime
                    let page = try await owner.loadOwnerPage(
                        after: ownerPageCursor, limit: OwnerLibraryPagingPolicy.pageSize
                    )
                    let pageLatencyMilliseconds = max(0,
                        (ProcessInfo.processInfo.systemUptime - pageStartedAt) * 1_000)
                    guard refreshGeneration == generation, activeUID == requestUID else { return }
                    let pendingAtEnd = hasPendingOwnerMutation(
                        for: requestUID, localRows: merged
                    )
                    let mayAdvance = OwnerLibraryPagingPolicy.mayAdvance(
                        page, pendingLocalOperations: pendingAtStart || pendingAtEnd
                    )
                    let nextCursor = mayAdvance
                        ? try OwnerLibraryPagingPolicy.nextCursor(after: ownerPageCursor, page: page)
                        : ownerPageCursor
                    read = page.read
                    currentPageIDs = Set(read.drops.map(\.id))
                    if mayAdvance {
                        ownerPageCursor = nextCursor
                        ownerSweepPages += 1
                        ownerSweepDocumentsRead += page.documentIDs.count
                        ownerSweepSeenIDs.formUnion(read.drops.map(\.id))
                        ownerSweepHadUnreadableRows = ownerSweepHadUnreadableRows
                            || page.unreadableDocumentCount > 0
                        if page.reachedEnd && !ownerSweepHadUnreadableRows {
                            ownerHasUnresolvedUnreadableRows = false
                        }
                        ownerSyncProgress = OwnerSyncProgress(
                            loadedRows: ownerSweepSeenIDs.count,
                            pagesRead: ownerSweepPages,
                            documentsRead: ownerSweepDocumentsRead,
                            lastPageLatencyMilliseconds: pageLatencyMilliseconds,
                            isComplete: page.reachedEnd
                        )
                        log.log("Owner page read \(page.documentIDs.count) documents in \(pageLatencyMilliseconds) ms; sweep pages \(self.ownerSweepPages)")
                    }
                    ownerCloudPublishedIDs.formUnion(read.drops.map(\.id))
                    if page.unreadableDocumentCount > 0 {
                        ownerHasUnresolvedUnreadableRows = true
                        lastSyncError = "Some cloud drops couldn't be read — sync needs attention"
                    }
                } else if let provenanced = cloud as? ProvenancedDropStore {
                    read = try await provenanced.loadLibraryDropsWithProvenance()
                } else {
                    // A store without provenance (legacy CloudKit) performs
                    // real network reads — there is no cache to serve from
                    // and no latency compensation to fabricate rows.
                    guard let unpaged = cloud as? LibraryDropLoading else { return }
                    let rows = try await unpaged.loadLibraryDrops()
                    read = CloudRead(
                        drops: rows, servedFromCache: false,
                        serverConfirmedIDs: Set(rows.map(\.id))
                    )
                }
                guard refreshGeneration == generation else { return }
                cloudReadCompleted = true
                cloudReadServerServed = !read.servedFromCache
                for drop in read.drops {
                    // Round 12 (counsel SEAMS-lens-1): the acked fact requires
                    // per-row provenance — a server-served snapshot still
                    // carries latency-compensated rows the server has never
                    // acknowledged; only pending-write-free rows testify.
                    if cloudReadServerServed, read.serverConfirmedIDs.contains(drop.id) {
                        markAcked(drop.id)
                        clearProvisionalOwner(drop.id)
                    }
                    // A pending local edit is newer than the server copy —
                    // never let a stale cloud read roll it back.
                    if pendingSyncIDs.contains(drop.id), merged[drop.id] != nil { continue }
                    merged[drop.id] = drop
                }
                // Round 12 (counsel SEAMS-lens-3): a verdict is revoked only
                // by its issuing authority — a cache-served read must not
                // clear a server-issued sync failure.
                if cloudReadServerServed,
                   !(cloud is OwnerLibraryPaging && ownerHasUnresolvedUnreadableRows) {
                    lastSyncError = nil
                }
            } catch DropStoreError.notSignedIn {
                guard refreshGeneration == generation else { return }
            } catch {
                guard refreshGeneration == generation else { return }
                lastSyncError = error.localizedDescription
            }
        }
        // Phase 2 merges a completed cloud read with local truth. A paged
        // owner read adds rows already published by earlier pages: an omitted
        // page is never a server-confirmed deletion. A failed read leaves the
        // additive phase-1 publish standing (round 12, FLOWS-lens-4).
        // Tombstones (pending AND unresolved) suppress the WHOLE merged set:
        // a locally deleted drop must not resurrect from either source while
        // its delete is unconfirmed or refused.
        if cloud == nil || cloudReadCompleted {
            if cloud is OwnerLibraryPaging {
                for (id, drop) in phase1 where merged[id] == nil
                    || (ownerCloudPublishedIDs.contains(id)
                        && !currentPageIDs.contains(id)
                        && !pendingSyncIDs.contains(id)) {
                    merged[id] = drop
                }
            }
            for id in pendingDeleteIDs { merged[id] = nil }
            for id in unresolvedDeleteIDs { merged[id] = nil }
            drops = merged.values.sorted { $0.createdAt > $1.createdAt }
        }

        // Round 6 (counsel arui-3/arui-4): the reap keys on the machine-checkable
        // outcome — ONLY a `.clean` load proves absence. An absent file proves
        // nothing (never reap on it — that was the round-2 outbox wipe through
        // a side door). Terminal ids get the same referential-integrity sweep
        // pending ids got in round 4 (counsel flows-5). Round 10: the reap
        // SKIPS tombstone-suppressed ids — suppression hides the row from
        // `drops`, it does not prove the row is gone from disk.
        if case .clean = localOutcome {
            for id in pendingSyncIDs
            where syncTasks[id] == nil
                && !drops.contains(where: { $0.id == id })
                && !pendingDeleteIDs.contains(id)
                && !unresolvedDeleteIDs.contains(id) {
                clearPending(id)
                log.log("Reaped orphaned pending sync id \(id)")
            }
            for id in terminalSyncFailureIDs
            where !drops.contains(where: { $0.id == id })
                && !pendingDeleteIDs.contains(id)
                && !unresolvedDeleteIDs.contains(id) {
                clearTerminal(id)
                log.log("Reaped orphaned terminal id \(id)")
            }
        }
        // Round 12 (counsel own-B/FLOWS-lens-5): destructive outcomes are
        // remembered DURABLY and independently of the journal file — the
        // library observes the machine-checkable outcome directly, so neither
        // a failed journal write nor an acknowledged banner can launder a
        // destroyed library into a brand-new one. A `.clean` load (file
        // present, every row read) retires the memory; an absent file never
        // does.
        switch localOutcome {
        case .skippedRows(_, _, let lostIDs)?:
            defaults.set(true, forKey: Self.incidentMemoryKey)
            // Round 14 (counsel state-2): a destructive outcome REVOKES the
            // earned all-clear — "Synced" may not outlive the library it
            // described.
            hasCompletedCleanRefresh = false
            if incidentLedger == nil {
                for id in lostIDs { markLost(id) }
            }
        case .quarantinedWholeFile?, .readFailed?:
            defaults.set(true, forKey: Self.incidentMemoryKey)
            hasCompletedCleanRefresh = false
            // The ledger's last local inventory includes received and other
            // nonpending rows. Its whole-file record marks extent unknown.
            if incidentLedger == nil, case .quarantinedWholeFile? = localOutcome {
                for id in pendingSyncIDs { markLost(id) }
            }
        case .clean?:
            defaults.set(false, forKey: Self.incidentMemoryKey)
        default:
            break
        }
        // Round 8 (counsel B4) + round 10 (counsel ux-1): the "Synced"
        // precondition is EARNED here and only here — local truth provably
        // clean AND the cloud read answered BY THE SERVER (cache-served reads
        // earn nothing; no cloud store configured counts — there is nothing
        // to sync with). An ABSENT file counts only when no incident is
        // journaled AND none is remembered: a brand-new, legitimately empty
        // store — the absent file a quarantine leaves behind earns nothing,
        // even after the banner is dismissed (round 12, counsel own-B).
        // Sticky for the session (reset on a REAL account change, lens-4).
        let localProvablyClean: Bool = {
            guard localDiagnostics != nil else { return true }
            switch localOutcome {
            case .clean?:
                return true
            case .absentFile?:
                return localReadWarning == nil
                    && !defaults.bool(forKey: Self.incidentMemoryKey)
            default:
                return false
            }
        }()
        let ownerSweepComplete = cloud is OwnerLibraryPaging
            ? ownerSyncProgress?.isComplete == true && !ownerSweepHadUnreadableRows
            : cloudReadServerServed
        if localProvablyClean, storageLedgerError == nil,
           cloud == nil || (cloudReadServerServed && ownerSweepComplete) {
            hasCompletedCleanRefresh = true
        }

        // Round 10 (counsel own-3): the user's OWN pending work flushes first;
        // tombstone cleanup never queues ahead of it.
        reconcileCloud()

        // Round 8 (counsel B3 — state-1/state-2/flows-1/flows-2): tombstone
        // RETIREMENT requires a positive, PER-DOCUMENT, SERVER-SOURCED answer
        // — never a set-difference over a cache-satisfiable, uid-scoped query.
        // Round 10 (counsel seams-1c/own-3): capability-gated (the deployed
        // rules may be unable to answer absence at all — cache answers,
        // back off denied probes, retry inconclusive) and capped per pass.
        if let absence = cloud as? DropAbsenceVerifying {
            let tombstones = pendingDeleteIDs.union(unresolvedDeleteIDs)
            if !tombstones.isEmpty {
                if knownAbsenceCapability == .denied,
                   let retryAt = deniedAbsenceRetryAt,
                   absenceProbeTime() >= retryAt {
                    knownAbsenceCapability = nil
                    deniedAbsenceRetryAt = nil
                }
                if knownAbsenceCapability == nil {
                    let capability = await absence.probeAbsenceCapability()
                    guard refreshGeneration == generation else { return }
                    if capability != .inconclusive {
                        knownAbsenceCapability = capability
                        deniedAbsenceRetryAt = capability == .denied ? absenceProbeTime() + 60 : nil
                    }
                }
                guard knownAbsenceCapability == .answers else { return }
                for id in tombstones.prefix(5) {
                    let gone = await absence.serverConfirmsAbsent(id)
                    guard refreshGeneration == generation else { return }
                    guard gone else { continue }
                    if pendingDeleteIDs.contains(id) {
                        clearPendingDelete(id)
                        deleteAttempts[id] = nil
                        log.log("Server confirmed absence — retired tombstone \(id)")
                    }
                    if unresolvedDeleteIDs.contains(id) {
                        clearUnresolvedDelete(id)
                        log.log("Server confirmed absence — retired unresolved delete \(id)")
                    }
                    clearAcked(id)
                    clearCloudProven(id)
                }
            }
        }
    }

    private func resetOwnerSweep() {
        ownerPageCursor = nil
        ownerSweepSeenIDs = []
        ownerSweepPages = 0
        ownerSweepDocumentsRead = 0
        ownerSweepHadUnreadableRows = false
        ownerSyncProgress = nil
    }

    /// Firestore can omit a locally deleted row from a server-served query
    /// without setting pending-write metadata. Only writes for this owner can
    /// change this owner's query boundary. Pending work bound to another UID
    /// survives an account switch, but must not hold the new UID's sweep.
    private func hasPendingOwnerMutation(
        for uid: String, localRows: [UUID: GeoDrop]
    ) -> Bool {
        if pendingDeleteIDs.contains(where: { id in
            pendingDeleteOwners[id].map { $0 == uid } ?? true
        }) { return true }
        return pendingSyncIDs.contains { id in
            let owner = pendingSyncOwners[id] ?? localRows[id]?.ownerUid
            return owner.map { $0 == uid } ?? true
        }
    }

    /// Round 6 (counsel concurrency-5): the incident banner is resolvable by
    /// the user — a legitimately empty library must not carry it forever.
    /// Round 8 (counsel ux-6): the dismissal is a MUTATOR that owns its own
    /// generation — bumping it aborts any in-flight refresh that read the old
    /// warning before the journal cleared and would have re-posted it; and the
    /// banner clears immediately because the user's dismissal is authoritative,
    /// never contingent on a generation this method used to not own.
    func acknowledgeReadIncident() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        Task { [weak self] in
            await self?.localDiagnostics?.acknowledgeIncident()
            guard let self else { return }
            let warning = await self.localDiagnostics?.lastLoadReadWarning()
            await MainActor.run {
                guard self.refreshGeneration == generation else { return }
                self.localReadWarning = warning
            }
            // Round 10 (counsel ux-3): the generation bump above may have
            // aborted an in-flight refresh — the dismissal must not strand
            // the library unpublished for the rest of the session.
            await self.refreshLibrary()
        }
    }

    private var activeUID: String? {
        guard let uid = currentUID(), !uid.isEmpty,
              uid == uid.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return uid
    }

    /// Resolve the current row, never a value captured when a sheet or menu
    /// opened. A changed account is reflected on the next view update and on
    /// every command invocation.
    func ownershipRole(id: UUID) -> DropOwnershipRole? {
        guard let drop = drops.first(where: { $0.id == id }) else { return nil }
        let role = DropOwnershipRole(drop: drop, currentUID: activeUID)
        if role == .legacyLocal, let originUID = pendingSyncOwners[id],
           originUID != activeUID { return .unresolved }
        return role
    }

    func canEditLocally(id: UUID) -> Bool {
        ownershipRole(id: id)?.canEditLocally == true
    }

    func canShare(id: UUID) -> Bool {
        activeUID != nil && ownershipRole(id: id)?.canShareAsOwner == true
    }

    func canRemoveLocalCopy(id: UUID) -> Bool {
        switch ownershipRole(id: id) {
        case .received: return true
        case .legacyLocal: return cloud == nil
        default: return false
        }
    }

    /// Ownerless local rows may be edited, but they need an acknowledged cloud
    /// save to establish ownerUid before an authored link can be sent.
    func requestLegacyOwnershipClaim(id: UUID) throws {
        guard let uid = activeUID, cloud != nil,
              ownershipRole(id: id) == .legacyLocal,
              let drop = drops.first(where: { $0.id == id }) else {
            throw DropPermissionError.cannotShare
        }
        bindPendingSyncOwner(id, uid: uid)
        enqueueCloudSync(drop)
    }

    /// The share command takes an identifier so a caller cannot replace
    /// ownership markers in a copied GeoDrop. The live row and current identity
    /// are checked again after local persistence before the link is returned.
    func share(id: UUID, recipientName: String?) async throws -> GeoDrop {
        guard canShare(id: id), let live = drops.first(where: { $0.id == id }) else {
            throw DropPermissionError.cannotShare
        }
        var updated = live
        updated.visibility = "link"
        let recipient = recipientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updated.recipientName = recipient.isEmpty ? nil : recipient
        try await update(updated)
        guard canShare(id: id), let saved = drops.first(where: { $0.id == id }) else {
            throw DropPermissionError.ownershipChanged
        }
        return saved
    }

    /// Round 6 (counsel sync-4): the account connection changed — every
    /// terminal verdict was issued against the OLD uid and must be revalidated
    /// against the new one. Re-attempt each; the outcomes decide (an ack
    /// clears the verdict, a fresh mismatch re-confirms it).
    /// Round 12 (counsel SURF-lens-1/STATE-lens-3/FLOWS-lens-3 — three
    /// reviewers converged): THE composed auth-ready entry point. The old
    /// RootView sequence ran `refresh()` and then reset the evidence latch
    /// the refresh had just earned — pinning the ladder at "Checking sync
    /// status…" for the whole session. Here the reset happens only when the
    /// uid ACTUALLY changed, the refresh runs after it, and terminal
    /// revalidation runs last against the fresh state. Round 14 (counsel
    /// seams-3): revalidation also runs on the FIRST pass of every session —
    /// the round-12 `changed`-only gate was structurally false on a fresh
    /// process, so terminal verdicts were never re-examined again.
    /// (accountDidChange(), by then caller-less, was deleted with this.)
    func authDidBecomeReady(uid: String) async {
        let changed = evidenceUid != nil && evidenceUid != uid
        let firstPassThisSession = !authReadyRan
        authReadyRan = true
        evidenceUid = uid
        if changed {
            hasCompletedCleanRefresh = false
        }
        if changed || firstPassThisSession {
            knownAbsenceCapability = nil
            deniedAbsenceRetryAt = nil
        }
        await refreshLibrary()
        if changed || firstPassThisSession {
            // Terminal verdicts were issued against an earlier connection or
            // an earlier session — revalidate each; the outcomes decide (an
            // ack clears the verdict, a fresh refusal re-confirms it).
            for id in terminalSyncFailureIDs {
                if let drop = drops.first(where: { $0.id == id }) {
                    enqueueCloudSync(drop)
                }
            }
        }
    }

    /// Round 6 (counsel flows-2 + sync-4): an explicit user retry for a drop
    /// whose upload previously failed terminally. The verdict is NOT cleared
    /// here — only a subsequent server ack may clear it. Round 10 (counsel
    /// flows-3): retry is BY ID — the row resolves from the live library at
    /// enqueue time, so a presentation-captured stale copy (the share sheet's
    /// mutated `sharedDrop` was one) can never be republished.
    func retrySync(id: UUID) {
        guard let drop = drops.first(where: { $0.id == id }) else { return }
        guard activeUID != nil,
              [.owned, .legacyLocal].contains(DropOwnershipRole(drop: drop, currentUID: activeUID))
        else { return }
        enqueueCloudSync(drop)
    }

    /// Round 10 (counsel lens-1/seams-4/flows-1), predicate corrected in
    /// round 12 (counsel STATE-lens-1/2, FLOWS-lens-2, own-A): THE entry
    /// point for a link-received drop — the receive flow calls this, never
    /// `update()`. Redemption is expressed by opening the LINK, not by
    /// ownership. One rule decides the write: an EXISTING local row is
    /// authoritative (it may carry the recipient's persisted AR placement
    /// edits — the old pendingSyncIDs guard was structurally empty, because
    /// received drops are never marked pending); NO local row means the
    /// fetched copy is the last copy left (deleted earlier, or lost to a
    /// quarantine) and is restored to memory AND disk.
    func redeem(_ drop: GeoDrop) async throws {
        refreshGeneration &+= 1
        let rowGeneration = (rowGenerations[drop.id] ?? 0) &+ 1
        rowGenerations[drop.id] = rowGeneration
        let hadTombstone = pendingDeleteIDs.contains(drop.id)
            || unresolvedDeleteIDs.contains(drop.id)
        let recallUID: String? = hadTombstone
            && DropOwnershipRole(drop: drop, currentUID: activeUID) == .owned
            ? activeUID : nil
        deleteGenerations[drop.id] = (deleteGenerations[drop.id] ?? 0) &+ 1
        deleteTasks[drop.id]?.cancel()
        deleteTasks[drop.id] = nil
        clearPendingDelete(drop.id)
        clearUnresolvedDelete(drop.id)
        deleteAttempts[drop.id] = nil
        var persistError: Error?
        if !drops.contains(where: { $0.id == drop.id }) {
            // Round 14 (counsel seams-2): DISK FIRST, exactly like add() — a
            // memory-only insert made a failed persist look like success, and
            // every later redeem of the same id then silently no-oped on the
            // "row exists" branch while disk stayed empty.
            do {
                try await local.save(drop)
                guard rowGenerations[drop.id] == rowGeneration else { return }
                refreshGeneration &+= 1
                lastPersistError = nil
                drops.insert(drop, at: 0)
                clearLost(drop.id) // a restored row is no longer a recorded loss
            } catch {
                guard rowGenerations[drop.id] == rowGeneration else { return }
                lastPersistError = "Couldn't save the drop: \(error.localizedDescription)"
                persistError = error
            }
        } else if DropOwnershipRole(drop: drop, currentUID: activeUID) == .owned,
                  let existing = drops.first(where: { $0.id == drop.id }),
                  existing.receivedViaLink == true,
                  (existing.ownerUid == nil || existing.ownerUid == drop.ownerUid) {
            // A copy received under another account may become the owner's
            // own link after account switching. Keep its local placement edits
            // and promote only ownership metadata proved by the fetched
            // envelope; do not preserve a stale viewer marker forever.
            var promoted = existing
            promoted.ownerUid = drop.ownerUid
            promoted.receivedViaLink = nil
            do {
                try await local.save(promoted)
                guard rowGenerations[drop.id] == rowGeneration else { return }
                refreshGeneration &+= 1
                if let index = drops.firstIndex(where: { $0.id == drop.id }) {
                    drops[index] = promoted
                }
                lastPersistError = nil
            } catch {
                guard rowGenerations[drop.id] == rowGeneration else { return }
                lastPersistError = "Couldn't save the drop: \(error.localizedDescription)"
                persistError = error
            }
        }
        // Round 12 (counsel own-A — CRITICAL) + round 14 (counsel state-3):
        // the staged-delete recall runs even when the persist FAILED — the
        // delete is already in Firestore's durable mutation queue and only a
        // later serialized save can recreate the document behind it. For the
        // user's OWN drop, enqueue the re-upload; pendingSyncIDs covers the
        // window honestly.
        if let recallUID, cloud != nil {
            if let persistError, activeUID != recallUID {
                // The reopen failed while the account switched. Restore the
                // original delete intent; the user did not get a local row.
                markPendingDelete(drop.id, ownerUID: recallUID)
                throw persistError
            }
            bindPendingSyncOwner(drop.id, uid: recallUID)
            markPending(drop.id)
            let row = drops.first(where: { $0.id == drop.id }) ?? drop
            enqueueCloudSync(row)
        }
        if let persistError { throw persistError }
    }

    /// Wave C SWE-14: local persistence failures throw to the originating CTA.
    /// The in-memory insert happens only AFTER the disk write succeeds.
    func add(_ drop: GeoDrop) async throws {
        guard !drops.contains(where: { $0.id == drop.id }) else {
            throw DropPermissionError.ownershipChanged
        }
        let role = DropOwnershipRole(drop: drop, currentUID: activeUID)
        guard role == .owned || role == .legacyLocal else {
            throw DropPermissionError.cannotEdit
        }
        var authored = drop
        // A newly authored row has known local provenance even before its
        // first cloud ack. The backend still verifies ownership on create and
        // keeps it immutable on update.
        if authored.ownerUid == nil, let uid = activeUID {
            authored.ownerUid = uid
            markProvisionalOwner(drop.id)
        }
        refreshGeneration &+= 1
        rowGenerations[drop.id] = (rowGenerations[drop.id] ?? 0) &+ 1
        do {
            try await local.save(authored)
        } catch {
            clearProvisionalOwner(drop.id)
            lastPersistError = "Couldn't save the drop: \(error.localizedDescription)"
            throw error
        }
        // A refresh may have started while the disk write was suspended and
        // read the old file. Its phase-2 publish must not erase this new row.
        refreshGeneration &+= 1
        lastPersistError = nil
        drops.removeAll { $0.id == drop.id }
        drops.insert(authored, at: 0)
        clearLost(drop.id)
        // Keep the outbox intent for a pre-auth creation. Firebase will answer
        // notSignedIn now, and auth-ready reconciliation will retry after UID
        // attachment even if that refresh finished before this disk save.
        if cloud != nil { markPending(drop.id) }
        enqueueCloudSync(authored)
    }

    /// In-place edit — the EDITOR write path only. Round 10 (counsel
    /// lens-1/seams-4/flows-1): link-received drops go through `redeem(_:)`,
    /// which owns the tombstone-redemption semantics this method carried in
    /// rounds 6–8 and adds the pending-edit protection a fetched copy needs.
    func update(_ drop: GeoDrop, persist: Bool = true) async throws {
        guard let index = drops.firstIndex(where: { $0.id == drop.id }) else {
            throw DropPermissionError.missingDrop
        }
        let live = drops[index]
        guard canEditLocally(id: drop.id) else {
            throw DropPermissionError.cannotEdit
        }
        // ownerUid and the viewer marker are not editor fields. A copied row
        // that strips either cannot turn a received drop into an authored one.
        guard drop.ownerUid == live.ownerUid,
              drop.receivedViaLink == live.receivedViaLink else {
            throw DropPermissionError.ownershipChanged
        }
        let commandUID = activeUID
        refreshGeneration &+= 1
        let rowGeneration = (rowGenerations[drop.id] ?? 0) &+ 1
        rowGenerations[drop.id] = rowGeneration
        if !persist {
            drops[index] = drop
            return
        }
        do {
            try await local.save(drop)
        } catch {
            lastPersistError = "Couldn't save the change: \(error.localizedDescription)"
            throw error
        }
        guard rowGenerations[drop.id] == rowGeneration else {
            throw DropPermissionError.ownershipChanged
        }
        refreshGeneration &+= 1
        guard let currentIndex = drops.firstIndex(where: { $0.id == drop.id }) else {
            throw DropPermissionError.missingDrop
        }
        drops[currentIndex] = drop
        lastPersistError = nil
        clearLost(drop.id)
        if drop.ownerUid == nil, let commandUID {
            bindPendingSyncOwner(drop.id, uid: commandUID)
        }
        if cloud != nil { markPending(drop.id) }
        enqueueCloudSync(drop)
        guard activeUID == commandUID, canEditLocally(id: drop.id) else {
            throw DropPermissionError.ownershipChanged
        }
    }

    /// Compatibility entry point for map actions and older callers. The role
    /// is resolved from the current row; caller-supplied metadata is ignored.
    func remove(_ drop: GeoDrop) async throws {
        switch ownershipRole(id: drop.id) {
        case .owned:
            try await removeOwned(id: drop.id)
        case .received, .legacyLocal:
            try await removeLocalCopy(id: drop.id)
        case .unresolved:
            throw DropPermissionError.cannotEdit
        case nil:
            throw DropPermissionError.missingDrop
        }
    }

    func removeOwned(id: UUID) async throws {
        guard let uid = activeUID, ownershipRole(id: id) == .owned else {
            throw DropPermissionError.cannotEdit
        }
        try await removeLive(id: id, remoteOwnerUID: uid)
    }

    /// Removing a received or legacy local copy never revokes a cloud record.
    /// The intent stays local even if the account changes during the disk write.
    func removeLocalCopy(id: UUID) async throws {
        guard canRemoveLocalCopy(id: id) else {
            throw DropPermissionError.cannotRemoveUnverified
        }
        try await removeLive(id: id, remoteOwnerUID: nil)
    }

    private func removeLive(id: UUID, remoteOwnerUID: String?) async throws {
        guard let live = drops.first(where: { $0.id == id }) else {
            throw DropPermissionError.missingDrop
        }
        refreshGeneration &+= 1
        let rowGeneration = (rowGenerations[id] ?? 0) &+ 1
        rowGenerations[id] = rowGeneration
        // Counsel round 2 (C26): disk FIRST — only a successful delete may
        // destroy the sync bookkeeping.
        do {
            try await local.delete(live)
        } catch {
            lastPersistError = "Couldn't delete the drop: \(error.localizedDescription)"
            throw error
        }
        // Round 12 (counsel STATE-lens-6) corrected in round 14 (counsel
        // state-1/flows-lens-1 — CRITICAL): the re-check keys on THIS ROW's
        // epoch, never the global publish counter — a concurrent refresh must
        // not abandon a delete whose disk row is already destroyed; only
        // another MUTATOR of this drop (e.g. a redeem restoring it) may.
        guard rowGenerations[id] == rowGeneration else {
            log.log("remove(\(id)) superseded by a newer row mutation — bookkeeping skipped")
            return
        }
        refreshGeneration &+= 1
        lastPersistError = nil
        drops.removeAll { $0.id == id }
        forgetLocalID(id)
        syncGenerations[id] = (syncGenerations[id] ?? 0) &+ 1
        syncTasks[id]?.cancel()
        syncTasks[id] = nil
        clearPending(id)
        clearTerminal(id)
        deleteAttempts[id] = nil
        guard cloud != nil, let remoteOwnerUID else { return }
        // Round 12 (counsel FLOWS-lens-1) corrected in round 14 (counsel
        // flows-lens-3 + seams-5): positive cloud provenance is a stamped
        // ownerUid or a recorded ack — a REFUSED write is proof the server
        // does NOT hold the document, never that it does (the terminal clause
        // produced a permanent, unretirable false alarm); and the capture
        // sits below the received-drop return so viewer copies can't leak
        // unclearable entries into the durable set.
        if (live.ownerUid != nil && !provisionalOwnerIDs.contains(id))
            || ackedCloudIDs.contains(id) {
            markCloudProven(id)
        }
        clearProvisionalOwner(id)
        markPendingDelete(id, ownerUID: remoteOwnerUID)
        launchCloudDelete(id)
    }

    /// Round 4 (sync-5): batch mutations report per-item outcomes — one item's
    /// success must never erase another's failure.
    func remove(contentsOf doomed: [GeoDrop]) async {
        var failures = 0
        for drop in doomed {
            do {
                try await remove(drop)
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            lastPersistError = "\(failures) of \(doomed.count) drops couldn't be deleted"
        }
    }

    func removeOwned(ids: [UUID]) async {
        var failures = 0
        for id in ids {
            do { try await removeOwned(id: id) }
            catch { failures += 1 }
        }
        if failures > 0 {
            lastPersistError = "\(failures) of \(ids.count) owned drops couldn't be deleted"
        }
    }

    func removeLocalCopies(ids: [UUID]) async {
        var failures = 0
        for id in ids {
            do { try await removeLocalCopy(id: id) }
            catch { failures += 1 }
        }
        if failures > 0 {
            lastPersistError = "\(failures) of \(ids.count) local copies couldn't be removed"
        }
    }

    /// Owner-acknowledged dismissal of the persist-error banner.
    func clearPersistError() {
        lastPersistError = nil
    }

    /// Re-push every drop the server never acknowledged and replay pending
    /// deletes. Absence from the in-memory array means "not loaded yet",
    /// NEVER "deleted since" (round 2 C1) — this loop only pushes; the reap
    /// in refresh() (after a provably clean load) is the only orphan clearer.
    func reconcileCloud() {
        guard cloud != nil else { return }
        for id in pendingSyncIDs where syncTasks[id] == nil {
            if let drop = drops.first(where: { $0.id == id }) {
                enqueueCloudSync(drop)
            }
        }
        for id in pendingDeleteIDs
        where deleteTasks[id] == nil && (deleteAttempts[id] ?? 0) < 3 {
            launchCloudDelete(id)
        }
    }

    #if DEBUG
    /// Lets concurrency tests observe a completed delete attempt without a
    /// timer; the task itself owns the refusal bookkeeping being asserted.
    func waitForCloudDeleteAttempt(id: UUID) async {
        await deleteTasks[id]?.value
    }
    #endif

    /// Drops close enough to render in the AR camera.
    func drops(near location: CLLocation, within radius: CLLocationDistance) -> [GeoDrop] {
        drops.filter { $0.location.distance(from: location) <= radius }
    }

    // MARK: - Cloud sync pipeline (generation-guarded; per-drop outcomes)

    private func enqueueCloudSync(_ drop: GeoDrop) {
        guard cloud != nil else { return }
        let role = DropOwnershipRole(drop: drop, currentUID: activeUID)
        let originUID = pendingSyncOwners[drop.id]
        guard (role == .owned || role == .legacyLocal),
              originUID == nil || originUID == activeUID else {
            if pendingSyncIDs.contains(drop.id) {
                syncGenerations[drop.id] = (syncGenerations[drop.id] ?? 0) &+ 1
                syncTasks[drop.id]?.cancel()
                syncTasks[drop.id] = nil
            }
            if pendingSyncIDs.contains(drop.id),
               (originUID != nil || (drop.ownerUid != nil && activeUID != nil)) {
                markTerminal(drop.id)
                syncFailureReasons[drop.id] = DropStoreError.ownedByAnotherAccount.errorDescription
            }
            return
        }
        if role == .legacyLocal, originUID == nil, let uid = activeUID {
            bindPendingSyncOwner(drop.id, uid: uid)
        }
        markPending(drop.id)
        // Round 6 (counsel flows-2): the terminal verdict is NOT cleared here.
        // A verdict may be revoked only by the authority that issued it — the
        // server's ack in performCloudSync — never by the client's intention
        // to retry. (The old enqueue-time clear meant an offline edit of a
        // terminal drop silently re-armed the dead-link share.)
        let generation = (syncGenerations[drop.id] ?? 0) &+ 1
        syncGenerations[drop.id] = generation
        syncTasks[drop.id]?.cancel()
        syncTasks[drop.id] = Task { [weak self] in
            await self?.performCloudSync(drop, generation: generation)
        }
    }

    private func performCloudSync(_ drop: GeoDrop, generation: UInt64) async {
        guard let cloud else { return }
        // Round 4 (concurrency-3): a superseded generation must not even issue
        // its write — checked at ENTRY, not only after the save returns.
        guard !Task.isCancelled, syncGenerations[drop.id] == generation else { return }
        defer {
            if syncGenerations[drop.id] == generation { syncTasks[drop.id] = nil }
        }
        var candidate = drop
        if candidate.ownerUid == nil {
            if let originUID = pendingSyncOwners[drop.id] {
                guard activeUID == originUID else { return }
                candidate.ownerUid = originUID
            } else if let uid = activeUID {
                bindPendingSyncOwner(drop.id, uid: uid)
                candidate.ownerUid = uid
            }
        } else {
            guard activeUID == candidate.ownerUid else { return }
        }
        do {
            let stored = try await cloud.save(candidate)
            guard syncGenerations[drop.id] == generation else { return }
            clearPending(drop.id)
            clearTerminal(drop.id)
            syncFailureReasons[drop.id] = nil
            // Round 10 (counsel seams-1b/lens-3): the ack makes "the server
            // has seen this id" a durable first-class fact — the delete
            // pipeline's verdicts stop guessing it from the outbox.
            markAcked(drop.id)
            clearProvisionalOwner(drop.id)
            // A cloud ack proves the server accepted a write. It cannot prove
            // the unreadable local row was restored, so its incident remains
            // until a successful local save/load or explicit acknowledgement.
            // Round 8 (counsel B1/state-3): persist the SERVER-STAMPED ownerUid
            // back to disk. Without it the field is usually nil locally, so the
            // ownedByAnotherAccount pre-check could never fire in the field and
            // a real refusal was misclassified as retryable forever. Only the
            // uid is stamped onto the CURRENT row (never the whole saved copy —
            // a newer edit may already own the row's content). No suspension
            // between the snapshot and the save call, so the local actor
            // serializes us before any later mutation's write.
            if let stampedUid = stored.ownerUid, stampedUid != drop.ownerUid,
               let index = drops.firstIndex(where: { $0.id == drop.id }) {
                var stamped = drops[index]
                stamped.ownerUid = stampedUid
                drops[index] = stamped
                do {
                    try await local.save(stamped)
                } catch {
                    // Best-effort cache of server truth — losing it reverts to
                    // pre-round-8 behavior for this drop, nothing worse.
                    log.error("Couldn't persist server-stamped ownerUid for \(drop.id): \(error.localizedDescription)")
                }
            }
        } catch DropStoreError.notSignedIn {
            // Stays pending; reconcileCloud() re-pushes on auth-ready.
        } catch DropStoreError.ackTimedOut {
            // Round 6: the write is durably staged but unanswered (offline).
            // Stays pending, no error to show — and critically this task ENDS,
            // so the registry entry clears and the next reconcile can retry.
        } catch DropStoreError.ownedByAnotherAccount {
            if activeUID != candidate.ownerUid {
                // Auth changed between the command's preflight and the
                // adapter call. Keep the originating owner's outbox intent so
                // reconnecting that UID can still save the local edit.
                guard syncGenerations[drop.id] == generation else { return }
                markTerminal(drop.id)
                syncFailureReasons[drop.id] = DropStoreError.ownedByAnotherAccount.errorDescription
                return
            }
            // Round 4 (sync-1): terminal — but VISIBLY so, in durable per-drop
            // state that outranks "Synced" everywhere. Never a shared string.
            guard syncGenerations[drop.id] == generation else { return }
            clearPending(drop.id)
            markTerminal(drop.id)
            syncFailureReasons[drop.id] = DropStoreError.ownedByAnotherAccount.errorDescription
        } catch DropStoreError.refusedByServer(let reason) {
            if activeUID != candidate.ownerUid {
                guard syncGenerations[drop.id] == generation else { return }
                markTerminal(drop.id)
                syncFailureReasons[drop.id] = DropStoreError.ownedByAnotherAccount.errorDescription
                return
            }
            // Round 8 (counsel B1): the server ANSWERED with a non-retryable
            // refusal — the terminal-verdict producer that previously existed
            // only as a client-side pre-check on a usually-nil field. Same
            // treatment as the owner mismatch: durable, visible, outranks
            // "Synced", revoked only by a later server ack.
            guard syncGenerations[drop.id] == generation else { return }
            clearPending(drop.id)
            markTerminal(drop.id)
            syncFailureReasons[drop.id] = reason
        } catch {
            guard syncGenerations[drop.id] == generation else { return }
            syncFailureReasons[drop.id] = error.localizedDescription // stays pending
        }
    }

    private func launchCloudDelete(_ id: UUID) {
        guard cloud != nil else { return }
        // Round 8 (counsel process item): same generation discipline as the
        // save pipeline — only the CURRENT generation may spend attempts,
        // clear tombstones, or issue the unresolved verdict.
        let generation = (deleteGenerations[id] ?? 0) &+ 1
        deleteGenerations[id] = generation
        deleteTasks[id]?.cancel()
        deleteTasks[id] = Task { [weak self] in
            await self?.performCloudDelete(id, generation: generation)
        }
    }

    private func performCloudDelete(_ id: UUID, generation: UInt64) async {
        guard let cloud else { return }
        guard !Task.isCancelled, deleteGenerations[id] == generation else { return }
        defer {
            if deleteGenerations[id] == generation { deleteTasks[id] = nil }
        }
        guard let ownerUID = pendingDeleteOwners[id] else {
            // Pre-policy ID-only tombstones have lost the identity that
            // authorized their delete. Keep suppression and a visible
            // unresolved verdict; a server-confirmed absence can retire it.
            clearPendingDelete(id)
            markUnresolvedDelete(id)
            return
        }
        // An account switch must never replay the previous owner's delete
        // under the new UID. Retry remains available when that UID returns.
        guard activeUID == ownerUID else { return }
        var ghost = GeoDrop()
        ghost.id = id
        ghost.ownerUid = ownerUID
        do {
            try await cloud.delete(ghost)
            guard deleteGenerations[id] == generation else { return }
            clearPendingDelete(id)
            deleteAttempts[id] = nil
            clearAcked(id)
            clearCloudProven(id)
        } catch DropStoreError.notSignedIn {
            // Tombstone survives; the auth-ready reconcile replays it.
        } catch DropStoreError.ackTimedOut {
            // Round 6: unanswered, not refused — the delete stays queued
            // both here and in Firestore's local queue; no attempt spent.
        } catch {
            guard deleteGenerations[id] == generation else { return }
            // The adapter may have started under this owner and returned a
            // permission refusal after Auth switched accounts. That answer
            // says nothing about the originating owner's delete intent.
            guard activeUID == ownerUID else { return }
            // Round 12 (counsel SEAMS-lens-2): the attempt budget is spent
            // only on NON-RETRYABLE refusals — a transient failure (offline
            // blips, quota, aborted) keeps the tombstone pending and the next
            // reconcile retries, exactly like the save pipeline.
            guard DropStoreError.terminalRefusalReason(error) != nil else {
                log.log("Cloud delete for \(id) hit a transient failure — no attempt spent: \(error.localizedDescription)")
                return
            }
            // A genuinely REFUSED delete: suppression stays load-bearing,
            // but after bounded refusals the intent resolves. Round 10/12
            // (counsel lens-3, FLOWS-lens-1): the resolution keys on POSITIVE
            // provenance captured at tombstone time (or an ack since) —
            // proven → the cloud copy may genuinely survive: unresolved set,
            // visible surface; unproven → there is no cloud copy to warn
            // about: DONE, no false alarm the rules version can never clear.
            // The delete was still issued either way: a staged create in
            // Firestore's durable queue may yet flush, and the queue
            // serializes it before this delete.
            let attempts = (deleteAttempts[id] ?? 0) + 1
            deleteAttempts[id] = attempts
            log.error("Cloud delete for \(id) refused (attempt \(attempts)): \(error.localizedDescription)")
            if attempts >= 3 {
                clearPendingDelete(id)
                deleteAttempts[id] = nil
                if cloudProvenIDs.contains(id) || ackedCloudIDs.contains(id) {
                    markUnresolvedDelete(id)
                } else {
                    log.log("Refused delete of unproven \(id) resolved as done — no cloud copy is known to exist")
                }
            }
        }
    }

    private func persistPendingSyncOwners() {
        defaults.set(
            Dictionary(uniqueKeysWithValues: pendingSyncOwners.map { ($0.key.uuidString, $0.value) }),
            forKey: Self.pendingSyncOwnerDefaultsKey
        )
    }

    private func bindPendingSyncOwner(_ id: UUID, uid: String) {
        // Callers have already checked a live local row and the current role.
        // Never overwrite an older mutation's origin on an account switch.
        guard pendingSyncOwners[id] == nil || pendingSyncOwners[id] == uid else { return }
        pendingSyncOwners[id] = uid
        persistPendingSyncOwners()
    }

    private func markPending(_ id: UUID) {
        // Round 10 (counsel lens-1 invariant): a drop is never simultaneously
        // pending-upload and pending-delete — every path that marks one side
        // clears the other first (remove() clears pending; redeem() clears
        // the blacklist). The reap and the merge suppression both rely on it.
        assert(
            !pendingDeleteIDs.contains(id) && !unresolvedDeleteIDs.contains(id),
            "invariant violated: \(id) marked pending-sync while tombstoned"
        )
        pendingSyncIDs.insert(id)
        persistSet(pendingSyncIDs, key: Self.pendingDefaultsKey)
    }

    private func clearPending(_ id: UUID) {
        pendingSyncIDs.remove(id)
        persistSet(pendingSyncIDs, key: Self.pendingDefaultsKey)
        pendingSyncOwners[id] = nil
        persistPendingSyncOwners()
    }

    private func markTerminal(_ id: UUID) {
        terminalSyncFailureIDs.insert(id)
        persistSet(terminalSyncFailureIDs, key: Self.terminalDefaultsKey)
    }

    private func clearTerminal(_ id: UUID) {
        guard terminalSyncFailureIDs.contains(id) else { return }
        terminalSyncFailureIDs.remove(id)
        syncFailureReasons[id] = nil
        persistSet(terminalSyncFailureIDs, key: Self.terminalDefaultsKey)
    }

    private func persistPendingDeleteOwners() {
        defaults.set(
            Dictionary(uniqueKeysWithValues: pendingDeleteOwners.map { ($0.key.uuidString, $0.value) }),
            forKey: Self.pendingDeleteOwnerDefaultsKey
        )
    }

    private func markPendingDelete(_ id: UUID, ownerUID: String) {
        assert(
            !pendingSyncIDs.contains(id),
            "invariant violated: \(id) tombstoned while pending-sync"
        )
        pendingDeleteOwners[id] = ownerUID
        persistPendingDeleteOwners()
        pendingDeleteIDs.insert(id)
        persistSet(pendingDeleteIDs, key: Self.pendingDeleteDefaultsKey)
    }

    private func clearPendingDelete(_ id: UUID) {
        pendingDeleteIDs.remove(id)
        persistSet(pendingDeleteIDs, key: Self.pendingDeleteDefaultsKey)
        pendingDeleteOwners[id] = nil
        persistPendingDeleteOwners()
    }

    private func markUnresolvedDelete(_ id: UUID) {
        unresolvedDeleteIDs.insert(id)
        persistSet(unresolvedDeleteIDs, key: Self.unresolvedDeleteDefaultsKey)
    }

    private func clearUnresolvedDelete(_ id: UUID) {
        unresolvedDeleteIDs.remove(id)
        persistSet(unresolvedDeleteIDs, key: Self.unresolvedDeleteDefaultsKey)
    }

    private func markProvisionalOwner(_ id: UUID) {
        provisionalOwnerIDs.insert(id)
        persistSet(provisionalOwnerIDs, key: Self.provisionalOwnerDefaultsKey)
    }

    private func clearProvisionalOwner(_ id: UUID) {
        guard provisionalOwnerIDs.remove(id) != nil else { return }
        persistSet(provisionalOwnerIDs, key: Self.provisionalOwnerDefaultsKey)
    }

    private func markAcked(_ id: UUID) {
        guard !ackedCloudIDs.contains(id) else { return }
        ackedCloudIDs.insert(id)
        persistSet(ackedCloudIDs, key: Self.ackedDefaultsKey)
    }

    private func clearAcked(_ id: UUID) {
        guard ackedCloudIDs.contains(id) else { return }
        ackedCloudIDs.remove(id)
        persistSet(ackedCloudIDs, key: Self.ackedDefaultsKey)
    }

    private func markLost(_ id: UUID) {
        guard !lostRowIDs.contains(id) else { return }
        lostRowIDs.insert(id)
        persistSet(lostRowIDs, key: Self.lostRowsDefaultsKey)
    }

    private func clearLost(_ id: UUID) {
        if let incidentLedger {
            do {
                let prior = incidentLedger.state
                try incidentLedger.localSaveRestored(id)
                lostRowIDs = incidentLedger.visibleIDs
                if incidentLedger.state != prior { storageLedgerError = nil }
            } catch {
                storageLedgerError = "Saved-data recovery couldn't be recorded — check device storage"
            }
            return
        }
        guard lostRowIDs.contains(id) else { return }
        lostRowIDs.remove(id)
        persistSet(lostRowIDs, key: Self.lostRowsDefaultsKey)
    }

    /// Clear acknowledges the currently visible incident identities. The
    /// evidence records and original files remain; a changed digest can
    /// surface again. Commit to disk before changing the published status.
    func acknowledgeLosses() {
        if let incidentLedger {
            do {
                let prior = incidentLedger.state
                try incidentLedger.acknowledgeVisible()
                lostRowIDs = incidentLedger.visibleIDs
                if incidentLedger.state != prior { storageLedgerError = nil }
            } catch {
                storageLedgerError = "Couldn't save the storage acknowledgement — please try again"
            }
            return
        }
        guard storageLedgerError == nil else { return }
        lostRowIDs = []
        persistSet(lostRowIDs, key: Self.lostRowsDefaultsKey)
    }

    private func recordStorageObservation(
        _ observation: StorageIncidentObservation?, localIDs: Set<UUID>?, quarantine: Bool
    ) {
        guard let incidentLedger else { return }
        do {
            let prior = incidentLedger.state
            try incidentLedger.observe(observation, localIDs: localIDs, quarantine: quarantine)
            lostRowIDs = incidentLedger.visibleIDs
            if incidentLedger.state != prior { storageLedgerError = nil }
        } catch {
            storageLedgerError = "Saved-data incident history couldn't be updated — check device storage"
            hasCompletedCleanRefresh = false
        }
    }

    private func forgetLocalID(_ id: UUID) {
        guard let incidentLedger else { return }
        do {
            let prior = incidentLedger.state
            try incidentLedger.localDelete(id)
            if incidentLedger.state != prior { storageLedgerError = nil }
        } catch {
            storageLedgerError = "Saved-data inventory couldn't be updated — check device storage"
        }
    }

    private func markCloudProven(_ id: UUID) {
        guard !cloudProvenIDs.contains(id) else { return }
        cloudProvenIDs.insert(id)
        persistSet(cloudProvenIDs, key: Self.cloudProvenDefaultsKey)
    }

    private func clearCloudProven(_ id: UUID) {
        guard cloudProvenIDs.contains(id) else { return }
        cloudProvenIDs.remove(id)
        persistSet(cloudProvenIDs, key: Self.cloudProvenDefaultsKey)
    }

    private func persistSet(_ set: Set<UUID>, key: String) {
        defaults.set(set.map(\.uuidString).sorted(), forKey: key)
    }
}
