import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Wave 6.1 cloud store (ADR-039): Firestore behind the existing `DropStore`
/// seam — the local JSON store stays the offline truth, this syncs it.
///
/// Schema (documents in `drops/{dropId}`): `drop` contains the `GeoDrop`;
/// the envelope also contains
///   ownerUid    — the creator (rules: only the owner writes)
///   geohash     — precision-9 geohash of the coordinate (geo-queries, Wave 7)
///   visibility  — "private" | "link" | "public"  (Wave 6.2/7 use link/public)
/// Wave 6.1 scope: sync MY drops across installs; recipients and public
/// discovery ride on the same schema next waves.
/// The store has no mutable instance state. Firebase SDK objects are obtained
/// inside each operation; only value snapshots leave the async methods.
final class FirebaseDropStore: DropStore, DropAbsenceVerifying, ProvenancedDropStore {
    private struct CloudDrop: Codable {
        var drop: GeoDrop
        var ownerUid: String
        var geohash: String
        var visibility: String

        init(drop: GeoDrop, ownerUid: String, geohash: String, visibility: String) {
            self.drop = drop
            self.ownerUid = ownerUid
            self.geohash = geohash
            self.visibility = visibility
        }

        // Round 8 (counsel B3, researcher's own find): the synthesized decoder
        // was STRICT on the envelope fields, so a row written by an older or
        // newer schema silently vanished from `loadDrops` — and that silent
        // vanishing then fed the (round-6) destructive retirement path as
        // "server-confirmed absence". Same lenient policy as GeoDrop itself:
        // old data — local or cloud — always survives an app update.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            drop = try c.decode(GeoDrop.self, forKey: .drop)
            ownerUid = try c.decodeIfPresent(String.self, forKey: .ownerUid) ?? ""
            geohash = try c.decodeIfPresent(String.self, forKey: .geohash) ?? ""
            visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
                ?? drop.visibility
        }
    }

    func loadDrops(
        near location: CLLocation?, radius: CLLocationDistance
    ) async throws -> [GeoDrop] {
        try await loadDropsWithProvenance(near: location, radius: radius).drops
    }

    /// Round 10 (counsel ux-1): the read reports its PROVENANCE — Firestore
    /// serves `getDocuments()` from the local cache when offline, and no
    /// positive claim (the B4 evidence latch, the acked-ids fact) may be
    /// earned by a read no server answered.
    func loadDropsWithProvenance(
        near location: CLLocation?, radius: CLLocationDistance
    ) async throws -> CloudRead {
        // Wave C (counsel SWE-3): "no user yet" must be distinguishable from
        // "user has no drops" — a silent [] made a pre-auth refresh look like
        // an empty (but healthy) library.
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DropStoreError.notSignedIn
        }
        let snapshot = try await Firestore.firestore().collection("drops")
            .whereField("ownerUid", isEqualTo: uid)
            .getDocuments()
        var confirmed: Set<UUID> = []
        let rows = snapshot.documents.compactMap { document -> GeoDrop? in
            guard var cloud = try? document.data(as: CloudDrop.self) else { return nil }
            // Round 8 (counsel B1): rows uploaded before the drop-level stamp
            // existed carry the uid only on the envelope — propagate it so the
            // library can persist it locally.
            if cloud.drop.ownerUid == nil, !cloud.ownerUid.isEmpty {
                cloud.drop.ownerUid = cloud.ownerUid
            }
            // Round 12 (counsel SEAMS-lens-1): even a server-served snapshot
            // merges the local mutation queue into its results — a row still
            // carrying pending writes has NOT been acknowledged and must not
            // testify to the acked fact. Display keeps every row; evidence
            // keeps only the confirmed ones.
            if !document.metadata.hasPendingWrites {
                confirmed.insert(cloud.drop.id)
            }
            return cloud.drop
        }
        return CloudRead(
            drops: rows,
            servedFromCache: snapshot.metadata.isFromCache,
            serverConfirmedIDs: confirmed
        )
    }

    @discardableResult
    func save(_ drop: GeoDrop) async throws -> GeoDrop {
        // Wave C (counsel SWE-3): the old `guard ... else { return }` was a
        // silent success — a drop created before sign-in finished was never
        // uploaded, yet the share sheet handed out a link to it (dead forever).
        // Throwing keeps it in the pending set for the auth-ready reconcile.
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DropStoreError.notSignedIn
        }
        // A direct adapter call must fail visibly instead of reporting a
        // successful upload for a received copy.
        if drop.receivedViaLink == true { throw DropStoreError.ownedByAnotherAccount }
        // Counsel round 2 (C4/C15): any OTHER owner mismatch must not be a
        // silent success — the ack pipeline would clear pending and report
        // "Synced" for a write that uploaded nothing (the SWE-3 pattern
        // resurrected inside the fix). Throw a distinguishable, terminal error.
        if let owner = drop.ownerUid, owner != uid {
            throw DropStoreError.ownedByAnotherAccount
        }
        var stored = drop
        stored.ownerUid = uid
        stored.receivedViaLink = nil
        let record = CloudDrop(
            drop: stored,
            ownerUid: uid,
            geohash: GeoHash.encode(
                latitude: drop.latitude, longitude: drop.longitude, precision: 9
            ),
            visibility: drop.visibility
        )
        // Wave C (counsel PBS-4): the no-completion `setData(from:merge:)`
        // returns after LOCAL staging — a rules rejection or quota failure was
        // invisible. Round 6: the seam is bounded and three-valued; an
        // unanswered ack maps to `.ackTimedOut` so the caller's task ENDS
        // (keeping the drop pending for the next reconcile) instead of
        // parking forever and blocking every retry.
        let outcome = await FirestoreAcked.setData(
            Firestore.firestore().collection("drops").document(drop.id.uuidString),
            from: record
        )
        switch outcome {
        case .acked:
            return stored
        case .queuedLocally:
            throw DropStoreError.ackTimedOut
        case .rejected(let error):
            // Round 8 (counsel B1/state-3): a refusal with a NON-RETRYABLE code
            // becomes the terminal verdict. Before this, the only terminal
            // producer was a client-side pre-check on a usually-nil field, so
            // genuine server refusals stayed "pending" forever and the share
            // sheet reassured the user about a link that could never work.
            if let reason = DropStoreError.terminalRefusalReason(error) {
                throw DropStoreError.refusedByServer(reason: reason)
            }
            // Round 10 (counsel seams-2): an ENCODER throw is just as
            // permanent — the same payload encodes to the same failure every
            // retry, so leaving it in the retryable fallthrough meant eternal
            // "Uploading…" progress for a write that can never be staged.
            if error is EncodingError {
                throw DropStoreError.refusedByServer(
                    reason: "This drop couldn't be prepared for upload"
                )
            }
            throw error
        }
    }

    func delete(_ drop: GeoDrop) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DropStoreError.notSignedIn
        }
        // Cloud deletion requires a positively known owner. The library's
        // persisted tombstone carries that owner across offline retries; an
        // ID-only ghost or a received marker is never enough authority.
        guard drop.receivedViaLink != true, drop.ownerUid == uid else {
            throw DropStoreError.ownedByAnotherAccount
        }
        let outcome = await FirestoreAcked.delete(
            Firestore.firestore().collection("drops").document(drop.id.uuidString)
        )
        switch outcome {
        case .acked:
            return
        case .queuedLocally:
            throw DropStoreError.ackTimedOut
        case .rejected(let error):
            // Round 8 (counsel seam-6): the old `notFound → success` branch is
            // gone — Firestore deletes are idempotent (deleting an absent doc
            // is an ACK, not notFound) so the branch was unreachable under the
            // current rules AND under the corrected v3 draft. Absent-doc
            // refusals under the CURRENT owner-gated rules surface as
            // permission-denied and resolve through the per-document
            // retirement check (`serverConfirmsAbsent`), which is the honest
            // path: the server itself says whether the row is gone.
            throw error
        }
    }

    /// A per-document transaction read supplies server evidence without the
    /// local mutation overlay that ordinary `.server` reads still include.
    /// Offline, denied, timed-out or cancelled reads never prove absence.
    func serverConfirmsAbsent(_ id: UUID) async -> Bool {
        guard Auth.auth().currentUser != nil else { return false }
        do {
            let snapshot = try await FirestoreServerRead.document(
                Firestore.firestore().collection("drops").document(id.uuidString)
            )
            return !snapshot.exists
        } catch {
            // Permission denials and other failures do not prove absence,
            // regardless of which rules release is currently active.
            return false
        }
    }

    /// Can the active backend answer an absent-document read? A random UUID
    /// is overwhelmingly likely to be absent; an unexpected hit is inconclusive.
    /// Permission denial reports capability, not the identity of a rules release.
    func probeAbsenceCapability() async -> AbsenceCapability {
        guard Auth.auth().currentUser != nil else { return .inconclusive }
        do {
            let snapshot = try await FirestoreServerRead.document(
                Firestore.firestore().collection("drops").document(UUID().uuidString)
            )
            return snapshot.exists ? .inconclusive : .answers
        } catch {
            let nsError = error as NSError
            if nsError.domain == FirestoreErrorDomain,
               nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
                return .denied
            }
            return .inconclusive
        }
    }
}

/// Reads used to assert server facts must exclude pending local mutations.
/// Firebase 11.15's `.server` source still overlays pending writes, and deleted
/// snapshots report `hasPendingWrites == false`, so metadata cannot fix that.
/// Transaction reads use a remote lookup and do not include uncommitted changes
/// (Firebase's FIRFirestore.h transaction contract). This transaction writes no data.
enum FirestoreServerRead {
    enum ReadError: Error {
        case timedOut
        case missingResult
    }

    static func document(
        _ reference: DocumentReference, timeout: TimeInterval = 10
    ) async throws -> DocumentSnapshot {
        try Task.checkCancellation()
        let responses = AsyncThrowingStream<DocumentSnapshot, Error> { continuation in
            let options = TransactionOptions()
            // A concurrent server change is unknown for this read; callers
            // already offer retry. Do not multiply RPCs behind a short deadline.
            options.maxAttempts = 1
            reference.firestore.runTransaction(with: options, block: { transaction, errorPointer in
                do {
                    return try transaction.getDocument(reference)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }, completion: { result, error in
                if let error {
                    continuation.finish(throwing: error)
                } else if let snapshot = result as? DocumentSnapshot {
                    continuation.yield(snapshot)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ReadError.missingResult)
                }
            })
        }
        return try await race(responses, timeout: timeout)
    }

    /// Bounds the caller's wait without parking a continuation after cancellation.
    /// The SDK cannot cancel an in-flight transaction; its eventual completion
    /// only touches this terminated stream, never caller state or persisted data.
    static func race<Value: Sendable>(
        _ responses: AsyncThrowingStream<Value, Error>, timeout: TimeInterval
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for try await response in responses {
                    try Task.checkCancellation()
                    return response
                }
                try Task.checkCancellation()
                throw ReadError.missingResult
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw ReadError.timedOut
            }
            guard let response = try await group.next() else { throw ReadError.missingResult }
            try Task.checkCancellation()
            return response
        }
    }
}

extension DropStoreError {
    /// Round 8 (counsel B1): the refusal taxonomy. Maps a Firestore write
    /// rejection to a user-facing terminal reason when the gRPC code is
    /// non-retryable — the same write can only fail the same way again.
    /// Everything else (unavailable, deadline, aborted, resource-exhausted,
    /// internal, …) returns nil: retryable, stays pending.
    static func terminalRefusalReason(_ error: Error) -> String? {
        let nsError = error as NSError
        return terminalRefusalReason(domain: nsError.domain, code: nsError.code)
    }

    /// Split out so the hosted test bundle (which must not link Firebase —
    /// Firestore's gRPC double-links) can drive the mapping via
    /// `firestoreErrorDomain` + raw gRPC codes, which are a frozen public
    /// contract.
    static func terminalRefusalReason(domain: String, code: Int) -> String? {
        guard domain == FirestoreErrorDomain else { return nil }
        switch FirestoreErrorCode.Code(rawValue: code) {
        case .permissionDenied:
            return "The server refused this drop from this account connection"
        case .unauthenticated:
            return "The server didn't recognize this account connection"
        case .invalidArgument:
            return "The server couldn't accept this drop's content"
        case .failedPrecondition:
            return "The server couldn't accept this change"
        case .notFound:
            return "The server couldn't find where this drop belongs"
        default:
            return nil
        }
    }

    /// The Firestore error domain, exposed for the Firebase-free test bundle.
    static var firestoreErrorDomain: String { FirestoreErrorDomain }
}
