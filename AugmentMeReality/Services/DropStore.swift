import CoreLocation
import CryptoKit
import Foundation
import os

/// Storage backend for drops. Local JSON is always active (offline cache / no-account
/// mode); CloudKit joins in Wave 3 when `AppConfig.cloudKitEnabled` is true.
protocol DropStore {
    /// `near` is a hint for backends that support geo queries; local storage ignores it.
    func loadDrops(near location: CLLocation?, radius: CLLocationDistance) async throws -> [GeoDrop]
    /// Returns the CANONICAL stored form — a backend that stamps fields during
    /// the write (Firebase stamps `ownerUid`, round 8 counsel B1) reports them
    /// back so the caller can persist server truth instead of guessing it.
    @discardableResult
    func save(_ drop: GeoDrop) async throws -> GeoDrop
    func delete(_ drop: GeoDrop) async throws
}

/// Round 8 (counsel B3/state-1/state-2): a NEGATIVE fact ("the server no
/// longer holds this document") requires a positive per-document check that
/// only the server may answer. Query set-differences and cache-satisfiable
/// reads are structurally forbidden as evidence — an offline delete would
/// count its own unflushed write as proof and retire its own tombstone.
protocol DropAbsenceVerifying {
    /// True ONLY when the SERVER answered and the document does not exist.
    /// Cache-served reads, network failures, permission denials → false.
    func serverConfirmsAbsent(_ id: UUID) async -> Bool
    /// Round 10 (counsel seams-1c/own-3): whether the DEPLOYED backend can
    /// answer an absent-document read at all. Probed once per session so the
    /// library never pays per-tombstone round-trips a rules version cannot
    /// answer — and never mistakes "offline right now" for "can never answer".
    func probeAbsenceCapability() async -> AbsenceCapability
}

/// The three honest answers to "can the server tell us a document is gone?".
enum AbsenceCapability: Sendable {
    /// The server answered an absent-doc read — retirement probes work.
    case answers
    /// The deployed rules DENY absent-doc reads (pre-v3) — probing is futile
    /// until a rules deploy; latch for the session.
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
struct CloudRead {
    var drops: [GeoDrop]
    var servedFromCache: Bool
    var serverConfirmedIDs: Set<UUID>
}

/// Adopted by cloud stores that can report read provenance. The plain
/// `loadDrops` stays for display merging; THIS is what evidence keys on.
protocol ProvenancedDropStore {
    func loadDropsWithProvenance(
        near location: CLLocation?, radius: CLLocationDistance
    ) async throws -> CloudRead
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
    /// File present; some rows skipped (preserved in a sidecar). Round 14
    /// (counsel loss-ledger): the ids of the unreadable rows, where their id
    /// field still decoded — the durable loss record is built from these.
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
protocol LocalStoreDiagnostics: AnyObject {
    func lastLoadOutcome() async -> LocalLoadOutcome?
    func lastLoadReadWarning() async -> String?
    /// User acknowledged the incident banner — resolve the journal.
    func acknowledgeIncident() async
}

/// JSON-file persistence in Application Support.
///
/// Wave C (counsel SWE-8): an `actor`, so every load-modify-write is serialized
/// by construction. The old non-isolated class ran read-modify-write on the
/// cooperative pool from independent Tasks — two slider releases within ~ms
/// could clobber each other's write (an edit that "didn't stick", or a freshly
/// created drop vanishing from disk).
actor LocalDropStore: DropStore, LocalStoreDiagnostics {
    private let fileURL: URL
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "store")
    /// Transient verdict of the LAST load (skipped-rows message; nil when clean).
    private var pendingReadWarning: String?
    /// Round 6: the machine-checkable outcome of the last load.
    private var lastOutcome: LocalLoadOutcome?

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
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("AugmentMeReality", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("drops.json")
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

    func loadDrops(near location: CLLocation?, radius: CLLocationDistance) async throws -> [GeoDrop] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Round 4 (sync-2): an absent file clears only the TRANSIENT
            // warning — a journaled incident survives ("the file vanished" is
            // not evidence of health; the quarantine is what made it vanish).
            pendingReadWarning = nil
            lastOutcome = .absentFile
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Round 4 (sync-3): a read failure is itself a visible incident,
            // recorded BEFORE the rethrow so no caller can lose it.
            lastOutcome = .readFailed
            writeIncident("Your saved drops couldn't be read — check free space and relaunch")
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
                // Round 14 (counsel surf-lens-1): an ACKNOWLEDGED incident is
                // suppressed by content digest — the banner stays down for
                // exactly these bytes, and NOTHING is deleted. New or changed
                // bad content re-raises the incident.
                if contentDigest(data) == acknowledgedDigest() {
                    pendingReadWarning = nil
                } else {
                    // Round 10 (counsel lens-6): the "kept on disk" claim is
                    // made only when the sidecar write actually succeeded.
                    let preserved = preserveUnreadable(data)
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
                try? FileManager.default.removeItem(at: acknowledgedDigestURL)
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
                "corrupt-\(Int(Date().timeIntervalSince1970))"
            )
            // Round 10 (counsel lens-6): the backup claim is checked, never
            // asserted over a swallowed failure.
            let backedUp = (try? FileManager.default.moveItem(at: fileURL, to: quarantine)) != nil
            log.error("drops.json unreadable — quarantine \(backedUp ? "kept" : "FAILED"): \(quarantine.lastPathComponent)")
            pendingReadWarning = nil
            lastOutcome = .quarantinedWholeFile
            // Round 6 (counsel flows-5 composition): no raw filename in user
            // copy — the log carries the diagnostics, the user gets meaning.
            writeIncident(backedUp
                ? "Your saved drops couldn't be read — a backup was kept on this device"
                : "Your saved drops couldn't be read")
            return []
        }
    }

    /// Round 6: the machine-checkable verdict of the last load.
    func lastLoadOutcome() async -> LocalLoadOutcome? { lastOutcome }

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
        if case .skippedRows? = lastOutcome,
           let data = try? Data(contentsOf: fileURL) {
            try? Data(contentDigest(data).utf8)
                .write(to: acknowledgedDigestURL, options: .atomic)
        }
        clearIncident()
        pendingReadWarning = nil
    }

    private var acknowledgedDigestURL: URL {
        fileURL.appendingPathExtension("ackdigest")
    }

    private func acknowledgedDigest() -> String? {
        guard let data = try? Data(contentsOf: acknowledgedDigestURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func contentDigest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Counsel round 2 (C6/C14/C24): exactly one sidecar per DISTINCT
    /// unreadable content — named by content digest, so repeated loads (and
    /// relaunches) of the same bad bytes never accumulate copies.
    /// Returns whether the original bytes are actually preserved on disk —
    /// the caller's user-facing claim depends on it (round 10, counsel lens-6).
    private func preserveUnreadable(_ data: Data) -> Bool {
        let sidecar = fileURL.appendingPathExtension("unreadable-\(contentDigest(data))")
        if FileManager.default.fileExists(atPath: sidecar.path) { return true }
        do {
            try data.write(to: sidecar)
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

    private func clearIncident() {
        try? FileManager.default.removeItem(at: incidentNoteURL)
    }

    /// The user-facing warning: a journaled incident outranks the transient
    /// last-load result; nil only when there is neither.
    func lastLoadReadWarning() -> String? {
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
        var drops = try await loadDrops(near: nil, radius: 0)
        drops.removeAll { $0.id == drop.id }
        drops.append(drop)
        try persist(drops)
        return drop
    }

    func delete(_ drop: GeoDrop) async throws {
        var drops = try await loadDrops(near: nil, radius: 0)
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
    /// Round 14 (counsel surf-lens-2/own-1 — the charter's last live hole):
    /// the DURABLE LOSS LEDGER. Rows destroyed by corruption (skipped rows,
    /// quarantines) are recorded HERE, permanently, independent of banners,
    /// journals, reaps and evidence latches — "a loss that leaves no record"
    /// can no longer converge to "Synced". Retired per-id by a genuine
    /// restore (redeem) or a late server ack, or wholesale by the user.
    @Published private(set) var lostRowIDs: Set<UUID> = []

    private let local: DropStore
    private let cloud: DropStore?
    private let defaults: UserDefaults
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
    /// Round 10 (counsel seams-1c): the session's latched probe result.
    /// `.inconclusive` never latches — it retries next refresh.
    private var knownAbsenceCapability: AbsenceCapability?
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
    private static let pendingDeleteDefaultsKey = "pendingDeleteDropIDs"
    private static let terminalDefaultsKey = "terminalSyncDropIDs"
    private static let unresolvedDeleteDefaultsKey = "unresolvedDeleteDropIDs"
    private static let ackedDefaultsKey = "ackedCloudDropIDs"
    private static let cloudProvenDefaultsKey = "cloudProvenDropIDs"
    private static let lostRowsDefaultsKey = "lostRowIDs"
    /// Round 12 (counsel own-B): a destructive local-read outcome, remembered
    /// durably and INDEPENDENTLY of the journal file — a failed journal write
    /// (or an acknowledged one) must not let an absent store file present as
    /// a brand-new install and earn "Synced" over a destroyed library.
    private static let incidentMemoryKey = "hadLocalReadIncident"
    private var localDiagnostics: LocalStoreDiagnostics? {
        local as? LocalStoreDiagnostics
    }

    /// Store + defaults injection exists for tests (counsel concurrency-5: a
    /// test suite must NEVER touch the shipping app's persisted state);
    /// production picks the cloud store by configuration.
    init(
        localStore: DropStore = LocalDropStore(),
        cloudStore: DropStore? = AppConfig.firebaseConfigured
            ? FirebaseDropStore()
            : (AppConfig.cloudKitEnabled ? CloudKitDropStore() : nil),
        defaults: UserDefaults = .standard
    ) {
        self.local = localStore
        self.cloud = cloudStore
        self.defaults = defaults
        let pending = defaults.stringArray(forKey: Self.pendingDefaultsKey) ?? []
        pendingSyncIDs = Set(pending.compactMap(UUID.init(uuidString:)))
        let deletes = defaults.stringArray(forKey: Self.pendingDeleteDefaultsKey) ?? []
        pendingDeleteIDs = Set(deletes.compactMap(UUID.init(uuidString:)))
        let terminal = defaults.stringArray(forKey: Self.terminalDefaultsKey) ?? []
        terminalSyncFailureIDs = Set(terminal.compactMap(UUID.init(uuidString:)))
        let unresolved = defaults.stringArray(forKey: Self.unresolvedDeleteDefaultsKey) ?? []
        unresolvedDeleteIDs = Set(unresolved.compactMap(UUID.init(uuidString:)))
        let acked = defaults.stringArray(forKey: Self.ackedDefaultsKey) ?? []
        ackedCloudIDs = Set(acked.compactMap(UUID.init(uuidString:)))
        let proven = defaults.stringArray(forKey: Self.cloudProvenDefaultsKey) ?? []
        cloudProvenIDs = Set(proven.compactMap(UUID.init(uuidString:)))
        let lost = defaults.stringArray(forKey: Self.lostRowsDefaultsKey) ?? []
        lostRowIDs = Set(lost.compactMap(UUID.init(uuidString:)))
    }

    /// Round 6: the "Uploading N…" count includes only drops that can actually
    /// be pushed — a pending id with no loadable row is a problem, never
    /// progress (counsel flows-5).
    var uploadingCount: Int {
        pendingSyncIDs.filter { id in drops.contains { $0.id == id } }.count
    }

    /// Round 8 (counsel ux-4): pending writes whose row cannot be loaded.
    /// Round 6 removed these from the progress count; removing them from every
    /// surface turned "we can't read our own outbox" into a false all-clear.
    /// They are a PROBLEM count — never progress, never silence.
    var unpushablePendingCount: Int {
        pendingSyncIDs.count - uploadingCount
    }

    func refresh(near location: CLLocation?) async {
        // Round 4 (sync-4): every mutator bumps the generation; this refresh
        // re-checks after EVERY await and aborts if it was superseded — a
        // stale snapshot must never be published over newer state.
        refreshGeneration &+= 1
        let generation = refreshGeneration

        var merged: [UUID: GeoDrop] = [:]
        var localOutcome: LocalLoadOutcome?
        do {
            let localDrops = try await local.loadDrops(near: nil, radius: 0)
            guard refreshGeneration == generation else { return }
            for drop in localDrops { merged[drop.id] = drop }
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
            return
        }
        if let localDiagnostics {
            let warning = await localDiagnostics.lastLoadReadWarning()
            guard refreshGeneration == generation else { return }
            localReadWarning = warning
            let outcome = await localDiagnostics.lastLoadOutcome()
            guard refreshGeneration == generation else { return }
            localOutcome = outcome
        }
        // Round 10 (counsel own-2) + round 12 (counsel STATE-lens-4/FLOWS-
        // lens-4): TWO-PHASE PUBLISH, and phase 1 is ADDITIVE — it seeds from
        // what is already published (keeping cloud-contributed rows) and
        // overlays the fresh local load. A partial or superseded pass can
        // therefore never blink cloud rows out, tear down their AR entities,
        // or strand the library on "No drops yet"; phase 2 (after a
        // SUCCESSFUL cloud read) remains the authoritative replace.
        var phase1 = Dictionary(uniqueKeysWithValues: drops.map { ($0.id, $0) })
        for (id, drop) in merged { phase1[id] = drop }
        for id in pendingDeleteIDs { phase1[id] = nil }
        for id in unresolvedDeleteIDs { phase1[id] = nil }
        drops = phase1.values.sorted { $0.createdAt > $1.createdAt }

        // Round 10 (counsel ux-1): the read carries PROVENANCE. Merging
        // cache-served rows is fine (display value); EVIDENCE requires the
        // server to have actually answered.
        var cloudReadCompleted = false
        var cloudReadServerServed = false
        if let cloud {
            do {
                let read: CloudRead
                if let provenanced = cloud as? ProvenancedDropStore {
                    read = try await provenanced.loadDropsWithProvenance(
                        near: location, radius: AppConfig.nearbyQueryRadius
                    )
                } else {
                    // A store without provenance (legacy CloudKit) performs
                    // real network reads — there is no cache to serve from
                    // and no latency compensation to fabricate rows.
                    let rows = try await cloud.loadDrops(
                        near: location, radius: AppConfig.nearbyQueryRadius
                    )
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
                    }
                    // A pending local edit is newer than the server copy —
                    // never let a stale cloud read roll it back.
                    if pendingSyncIDs.contains(drop.id), merged[drop.id] != nil { continue }
                    merged[drop.id] = drop
                }
                // Round 12 (counsel SEAMS-lens-3): a verdict is revoked only
                // by its issuing authority — a cache-served read must not
                // clear a server-issued sync failure.
                if cloudReadServerServed { lastSyncError = nil }
            } catch DropStoreError.notSignedIn {
                guard refreshGeneration == generation else { return }
            } catch {
                guard refreshGeneration == generation else { return }
                lastSyncError = error.localizedDescription
            }
        }
        // Phase 2 — the authoritative replace, earned by a COMPLETED cloud
        // read (or the absence of a cloud store). A failed read leaves the
        // additive phase-1 publish standing (round 12, FLOWS-lens-4).
        // Tombstones (pending AND unresolved) suppress the WHOLE merged set:
        // a locally deleted drop must not resurrect from either source while
        // its delete is unconfirmed or refused.
        if cloud == nil || cloudReadCompleted {
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
            // Round 14 (loss ledger): record WHICH rows were destroyed —
            // permanently, before any reap or acknowledgement can erase the
            // evidence they existed.
            for id in lostIDs { markLost(id) }
        case .quarantinedWholeFile?, .readFailed?:
            defaults.set(true, forKey: Self.incidentMemoryKey)
            hasCompletedCleanRefresh = false
            if case .quarantinedWholeFile? = localOutcome {
                // The whole file is gone; the rows we can still NAME as lost
                // are the pending writes — provably never fully uploaded.
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
        if localProvablyClean, cloud == nil || cloudReadServerServed {
            hasCompletedCleanRefresh = true
        }

        // Round 10 (counsel own-3): the user's OWN pending work flushes first;
        // tombstone cleanup never queues ahead of it.
        reconcileCloud()

        // Round 8 (counsel B3 — state-1/state-2/flows-1/flows-2): tombstone
        // RETIREMENT requires a positive, PER-DOCUMENT, SERVER-SOURCED answer
        // — never a set-difference over a cache-satisfiable, uid-scoped query.
        // Round 10 (counsel seams-1c/own-3): capability-gated (the deployed
        // rules may be unable to answer absence at all — probe once, latch
        // answers/denied, retry inconclusive) and capped per pass.
        if let absence = cloud as? DropAbsenceVerifying {
            let tombstones = pendingDeleteIDs.union(unresolvedDeleteIDs)
            if !tombstones.isEmpty {
                if knownAbsenceCapability == nil {
                    let capability = await absence.probeAbsenceCapability()
                    guard refreshGeneration == generation else { return }
                    if capability != .inconclusive {
                        knownAbsenceCapability = capability
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
        localReadWarning = nil
        Task { [weak self] in
            await self?.localDiagnostics?.acknowledgeIncident()
            guard let self else { return }
            await MainActor.run {
                guard self.refreshGeneration == generation else { return }
                self.localReadWarning = nil
            }
            // Round 10 (counsel ux-3): the generation bump above may have
            // aborted an in-flight refresh — the dismissal must not strand
            // the library unpublished for the rest of the session.
            await self.refresh(near: nil)
        }
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
        await refresh(near: nil)
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
                lastPersistError = nil
                drops.insert(drop, at: 0)
                clearLost(drop.id) // a restored row is no longer a recorded loss
            } catch {
                guard rowGenerations[drop.id] == rowGeneration else { return }
                lastPersistError = "Couldn't save the drop: \(error.localizedDescription)"
                persistError = error
            }
        } else {
            clearLost(drop.id)
        }
        // Round 12 (counsel own-A — CRITICAL) + round 14 (counsel state-3):
        // the staged-delete recall runs even when the persist FAILED — the
        // delete is already in Firestore's durable mutation queue and only a
        // later serialized save can recreate the document behind it. For the
        // user's OWN drop, enqueue the re-upload; pendingSyncIDs covers the
        // window honestly.
        if hadTombstone, drop.receivedViaLink != true {
            let row = drops.first(where: { $0.id == drop.id }) ?? drop
            enqueueCloudSync(row)
        }
        if let persistError { throw persistError }
    }

    /// Wave C SWE-14: local persistence failures throw to the originating CTA.
    /// The in-memory insert happens only AFTER the disk write succeeds.
    func add(_ drop: GeoDrop) async throws {
        refreshGeneration &+= 1
        rowGenerations[drop.id] = (rowGenerations[drop.id] ?? 0) &+ 1
        do {
            try await local.save(drop)
        } catch {
            lastPersistError = "Couldn't save the drop: \(error.localizedDescription)"
            throw error
        }
        lastPersistError = nil
        drops.removeAll { $0.id == drop.id }
        drops.insert(drop, at: 0)
        enqueueCloudSync(drop)
    }

    /// In-place edit — the EDITOR write path only. Round 10 (counsel
    /// lens-1/seams-4/flows-1): link-received drops go through `redeem(_:)`,
    /// which owns the tombstone-redemption semantics this method carried in
    /// rounds 6–8 and adds the pending-edit protection a fetched copy needs.
    func update(_ drop: GeoDrop, persist: Bool = true) async throws {
        refreshGeneration &+= 1
        rowGenerations[drop.id] = (rowGenerations[drop.id] ?? 0) &+ 1
        if let index = drops.firstIndex(where: { $0.id == drop.id }) {
            drops[index] = drop
        } else {
            drops.insert(drop, at: 0)
        }
        guard persist else { return }
        do {
            try await local.save(drop)
        } catch {
            lastPersistError = "Couldn't save the change: \(error.localizedDescription)"
            throw error
        }
        lastPersistError = nil
        enqueueCloudSync(drop)
    }

    func remove(_ drop: GeoDrop) async throws {
        refreshGeneration &+= 1
        let rowGeneration = (rowGenerations[drop.id] ?? 0) &+ 1
        rowGenerations[drop.id] = rowGeneration
        // Counsel round 2 (C26): disk FIRST — only a successful delete may
        // destroy the sync bookkeeping.
        do {
            try await local.delete(drop)
        } catch {
            lastPersistError = "Couldn't delete the drop: \(error.localizedDescription)"
            throw error
        }
        // Round 12 (counsel STATE-lens-6) corrected in round 14 (counsel
        // state-1/flows-lens-1 — CRITICAL): the re-check keys on THIS ROW's
        // epoch, never the global publish counter — a concurrent refresh must
        // not abandon a delete whose disk row is already destroyed; only
        // another MUTATOR of this drop (e.g. a redeem restoring it) may.
        guard rowGenerations[drop.id] == rowGeneration else {
            log.log("remove(\(drop.id)) superseded by a newer row mutation — bookkeeping skipped")
            return
        }
        lastPersistError = nil
        drops.removeAll { $0.id == drop.id }
        syncGenerations[drop.id] = (syncGenerations[drop.id] ?? 0) &+ 1
        syncTasks[drop.id]?.cancel()
        syncTasks[drop.id] = nil
        clearPending(drop.id)
        clearTerminal(drop.id)
        deleteAttempts[drop.id] = nil
        // Counsel round 2 (C13): never fire a cloud delete at someone else's
        // document — a received drop's cloud copy belongs to the sharer.
        guard cloud != nil, drop.receivedViaLink != true else { return }
        // Round 12 (counsel FLOWS-lens-1) corrected in round 14 (counsel
        // flows-lens-3 + seams-5): positive cloud provenance is a stamped
        // ownerUid or a recorded ack — a REFUSED write is proof the server
        // does NOT hold the document, never that it does (the terminal clause
        // produced a permanent, unretirable false alarm); and the capture
        // sits below the received-drop return so viewer copies can't leak
        // unclearable entries into the durable set.
        if drop.ownerUid != nil || ackedCloudIDs.contains(drop.id) {
            markCloudProven(drop.id)
        }
        markPendingDelete(drop.id)
        launchCloudDelete(drop.id)
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

    /// Drops close enough to render in the AR camera.
    func drops(near location: CLLocation, within radius: CLLocationDistance) -> [GeoDrop] {
        drops.filter { $0.location.distance(from: location) <= radius }
    }

    // MARK: - Cloud sync pipeline (generation-guarded; per-drop outcomes)

    private func enqueueCloudSync(_ drop: GeoDrop) {
        guard cloud != nil else { return }
        guard drop.receivedViaLink != true else { return }
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
        do {
            let stored = try await cloud.save(drop)
            guard syncGenerations[drop.id] == generation else { return }
            clearPending(drop.id)
            clearTerminal(drop.id)
            syncFailureReasons[drop.id] = nil
            // Round 10 (counsel seams-1b/lens-3): the ack makes "the server
            // has seen this id" a durable first-class fact — the delete
            // pipeline's verdicts stop guessing it from the outbox.
            markAcked(drop.id)
            // Round 14 (loss ledger): a late ack proves the write made it
            // after all (e.g. Firestore's own queue flushed a copy the local
            // file lost) — the loss record retires.
            clearLost(drop.id)
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
            // Round 4 (sync-1): terminal — but VISIBLY so, in durable per-drop
            // state that outranks "Synced" everywhere. Never a shared string.
            guard syncGenerations[drop.id] == generation else { return }
            clearPending(drop.id)
            markTerminal(drop.id)
            syncFailureReasons[drop.id] = DropStoreError.ownedByAnotherAccount.errorDescription
        } catch DropStoreError.refusedByServer(let reason) {
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
        var ghost = GeoDrop()
        ghost.id = id
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

    private func markPendingDelete(_ id: UUID) {
        assert(
            !pendingSyncIDs.contains(id),
            "invariant violated: \(id) tombstoned while pending-sync"
        )
        pendingDeleteIDs.insert(id)
        persistSet(pendingDeleteIDs, key: Self.pendingDeleteDefaultsKey)
    }

    private func clearPendingDelete(_ id: UUID) {
        pendingDeleteIDs.remove(id)
        persistSet(pendingDeleteIDs, key: Self.pendingDeleteDefaultsKey)
    }

    private func markUnresolvedDelete(_ id: UUID) {
        unresolvedDeleteIDs.insert(id)
        persistSet(unresolvedDeleteIDs, key: Self.unresolvedDeleteDefaultsKey)
    }

    private func clearUnresolvedDelete(_ id: UUID) {
        unresolvedDeleteIDs.remove(id)
        persistSet(unresolvedDeleteIDs, key: Self.unresolvedDeleteDefaultsKey)
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
        guard lostRowIDs.contains(id) else { return }
        lostRowIDs.remove(id)
        persistSet(lostRowIDs, key: Self.lostRowsDefaultsKey)
    }

    /// Round 14 (loss ledger, user control per the durable-set shipping
    /// gate): the user has seen the loss record and dismisses it.
    func acknowledgeLosses() {
        lostRowIDs = []
        persistSet(lostRowIDs, key: Self.lostRowsDefaultsKey)
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
