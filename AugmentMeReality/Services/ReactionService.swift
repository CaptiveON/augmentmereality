import FirebaseAuth
import FirebaseFirestore
import Foundation
import os

/// Wave 6.2 live reactions — the loop's payoff. Reactions are documents in
/// `drops/{id}/reactions`; Firestore snapshot listeners deliver them to the
/// sender in ~sub-second, no push entitlement needed (FCM upgrades this at
/// the paid-membership milestone).
struct DropReaction: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var emoji: String
    var uid: String
    var byName: String
    var at: Date = Date()
}

@MainActor
final class ReactionService: ObservableObject {
    /// Most recent reaction on one of MY shared drops (sender-side toast).
    @Published private(set) var incoming: DropReaction?
    @Published private(set) var incomingDropTitle: String?

    private var listeners: [String: ListenerRegistration] = [:]
    /// Round 8 (counsel flows-4): drop ids whose listener has delivered its
    /// INITIAL snapshot. The first delivery is history (it belongs to the
    /// Memory, not a toast); every `.added` change after it is live — a
    /// structural watermark, unlike the old client-clock cutoff, which
    /// silently swallowed any queued reaction that flushed after the sender
    /// relaunched (the reaction's stamped time predates the new session).
    private var primedListeners: Set<String> = []
    /// Wave D R2 (counsel STATE-6): the DURABLE per-drop watermark — the last
    /// reaction document id this device has surfaced. The scene-background
    /// teardown re-primes every listener, and without this the re-attach's
    /// initial snapshot (which contains exactly the reaction that landed
    /// while backgrounded) was swallowed as "history".
    private var lastSeenReactionIDs: [String: String]
    private static let watermarkDefaultsKey = "lastSeenReactionIDs"
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "reactions")

    init() {
        lastSeenReactionIDs = UserDefaults.standard
            .dictionary(forKey: Self.watermarkDefaultsKey) as? [String: String] ?? [:]
    }

    private func recordSeen(key: String, reactionID: String) {
        guard lastSeenReactionIDs[key] != reactionID else { return }
        lastSeenReactionIDs[key] = reactionID
        UserDefaults.standard.set(lastSeenReactionIDs, forKey: Self.watermarkDefaultsKey)
    }

    // MARK: Viewer side

    /// Round 6: the send's honest outcomes for the delivery pill.
    enum SendResult {
        case delivered
        /// Durably staged in Firestore's local queue; flushes on reconnect.
        case queued
    }

    /// Send one reaction to a drop I'm watching.
    ///
    /// Round 4 (counsel flows-6) + round 6: routed through the bounded acked
    /// seam. `delivered` means the SERVER accepted; `queued` is the truthful
    /// offline outcome; a rejection throws. The old no-completion `setData`
    /// made "Sent to <sender>" a lie whenever the rules rejected the write.
    func send(
        _ emoji: String, to drop: GeoDrop, from profile: UserProfile?
    ) async throws -> SendResult {
        guard AppConfig.firebaseConfigured,
              let uid = Auth.auth().currentUser?.uid else {
            throw DropStoreError.notSignedIn
        }
        let reaction = DropReaction(
            emoji: emoji, uid: uid, byName: profile?.displayName ?? "Someone"
        )
        let outcome = await FirestoreAcked.setData(
            Firestore.firestore().collection("drops")
                .document(drop.id.uuidString)
                .collection("reactions").document(reaction.id),
            from: reaction
        )
        switch outcome {
        case .acked:
            return .delivered
        case .queuedLocally:
            return .queued
        case .rejected(let error):
            log.error("Reaction send rejected: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: Sender side

    /// ALL of my link-shared drops — the single definition of "shared" used
    /// by the attach window, the listen key AND the prune, so they can never
    /// drift apart (counsel PBS-3, round 14 flows-lens-5).
    nonisolated static func sharedDrops(in drops: [GeoDrop], myUid: String) -> [GeoDrop] {
        drops.filter {
            ($0.ownerUid == nil || $0.ownerUid == myUid)
                && $0.visibility != "private"
                && $0.receivedViaLink != true
        }
    }

    /// The drops the sender-side listener ATTACHES to: newest first, capped
    /// at 10 (cost bound).
    nonisolated static func watchedDrops(in drops: [GeoDrop], myUid: String) -> [GeoDrop] {
        Array(sharedDrops(in: drops, myUid: myUid).prefix(10))
    }

    /// Counsel PBS-3: the subscription must be keyed on the IDENTITY of what is
    /// subscribed to, never on a collection count. Round 14 (counsel
    /// flows-lens-5): keyed on the FULL shared set — a change anywhere in it
    /// (not just inside the newest-10 window) re-invokes the listen pass, so
    /// the corrected uncapped prune is actually reachable.
    nonisolated static func listenKey(for drops: [GeoDrop], myUid: String?) -> String {
        guard let myUid else { return "-" }
        let ids = sharedDrops(in: drops, myUid: myUid)
            .map(\.id.uuidString).sorted().joined(separator: "·")
        return "\(myUid)·\(ids)"
    }

    /// Listen on my link-shared drops. Round 8 (counsel flows-4): the initial
    /// snapshot is HISTORY (it belongs to the Memory, never a toast); every
    /// `.added` document change after it is live and toasts — regardless of
    /// its stamped client time, so a reaction that flushes from the viewer's
    /// offline queue after the sender relaunched still arrives. Wave B final
    /// check F6 still holds: the watermark is per-listener, so a re-key while
    /// a reaction is in flight cannot swallow it.
    func listenToMySharedDrops(_ drops: [GeoDrop], myUid: String?) {
        guard AppConfig.firebaseConfigured, let myUid else { return }
        let mine = Self.watchedDrops(in: drops, myUid: myUid)
        // Round 10 (counsel seams-5 tail) corrected in round 12 (counsel
        // SURF-lens-4): prune only listeners whose drop left the SHARED set
        // entirely (deleted/unshared) — never a drop that merely fell out of
        // the newest-10 attach window, whose already-attached listener is the
        // sender's only reaction surface for it.
        let allSharedKeys = Set(
            Self.sharedDrops(in: drops, myUid: myUid).map(\.id.uuidString)
        )
        for (key, registration) in listeners where !allSharedKeys.contains(key) {
            registration.remove()
            listeners[key] = nil
            primedListeners.remove(key)
        }
        for drop in mine where listeners[drop.id.uuidString] == nil {
            let title = drop.title
            let key = drop.id.uuidString
            listeners[key] = Firestore.firestore()
                .collection("drops").document(key)
                .collection("reactions")
                .order(by: "at", descending: true).limit(to: 1)
                .addSnapshotListener { [weak self] snapshot, error in
                    Task { @MainActor in
                        guard let self else { return }
                        guard let snapshot else {
                            // Round 10 (counsel flows-5): a dead registration
                            // is released so the next listen pass re-attaches,
                            // instead of silencing this drop's toasts for the
                            // rest of the session.
                            if let error {
                                self.log.error("Reaction listener \(key) died: \(error.localizedDescription)")
                            }
                            self.listeners[key]?.remove()
                            self.listeners[key] = nil
                            self.primedListeners.remove(key)
                            return
                        }
                        guard self.primedListeners.contains(key) else {
                            self.primedListeners.insert(key)
                            // Round 2 (counsel STATE-6): the initial snapshot
                            // is history — EXCEPT what arrived while this
                            // device was torn down. The durable watermark
                            // tells them apart: a newest row that isn't the
                            // last one surfaced here is a MISSED reaction.
                            if let doc = snapshot.documents.first {
                                let known = self.lastSeenReactionIDs[key]
                                if let known, doc.documentID != known,
                                   !doc.metadata.hasPendingWrites,
                                   let reaction = try? doc.data(as: DropReaction.self),
                                   reaction.uid != myUid {
                                    self.incoming = reaction
                                    self.incomingDropTitle = title
                                    self.log.log("Missed reaction surfaced: \(reaction.emoji)")
                                }
                                self.recordSeen(key: key, reactionID: doc.documentID)
                            }
                            return
                        }
                        guard let added = snapshot.documentChanges
                                  .first(where: { $0.type == .added }),
                              let reaction = try? added.document.data(as: DropReaction.self)
                        else { return }
                        self.recordSeen(key: key, reactionID: added.document.documentID)
                        guard reaction.uid != myUid else { return }
                        self.incoming = reaction
                        self.incomingDropTitle = title
                        self.log.log("Reaction received: \(reaction.emoji)")
                    }
                }
        }
    }

    /// Round 10 (counsel ux-2/flows-2): the Memory recap carries PROVENANCE.
    /// An unreachable server is UNKNOWN, never zero — and rows the SDK is
    /// still holding in its local write queue are not "landed".
    struct ReactionRecap {
        var rows: [DropReaction]
        /// True only when the SERVER answered this read.
        var serverAnswered: Bool
        /// Round 12 (counsel SURF-lens-6): the earliest server-confirmed
        /// reaction INCLUDING the viewer's own — the "FIRST IN n S" badge
        /// must not crown someone else's later reaction when the viewer
        /// reacted first (own rows are excluded from `rows` for counting,
        /// not for timing).
        var firstAt: Date?
        static let unavailable = ReactionRecap(
            rows: [], serverAnswered: false, firstAt: nil
        )
    }

    /// All OTHER people's server-confirmed reactions on a drop (Memory recap).
    /// The viewer's own reaction is excluded — it renders with its true
    /// delivery outcome on its own line, and counting it here through the
    /// cache fabricated a receipt directly under a QUEUED badge.
    func reactions(for drop: GeoDrop) async -> ReactionRecap {
        guard AppConfig.firebaseConfigured else { return .unavailable }
        let myUid = Auth.auth().currentUser?.uid
        do {
            let snapshot = try await Firestore.firestore()
                .collection("drops").document(drop.id.uuidString)
                .collection("reactions").order(by: "at").getDocuments()
            let confirmed = snapshot.documents
                .filter { !$0.metadata.hasPendingWrites } // unflushed ≠ landed
                .compactMap { try? $0.data(as: DropReaction.self) }
            return ReactionRecap(
                rows: confirmed.filter { $0.uid != myUid },
                serverAnswered: !snapshot.metadata.isFromCache,
                firstAt: confirmed.first?.at
            )
        } catch {
            log.error("Reaction recap read failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    func clearIncoming() {
        incoming = nil
        incomingDropTitle = nil
    }

    func stop() {
        listeners.values.forEach { $0.remove() }
        listeners.removeAll()
        primedListeners.removeAll()
    }
}
