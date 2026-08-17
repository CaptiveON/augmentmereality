import FirebaseAuth
import FirebaseFirestore
import Foundation
import os

/// Wave 6.1 identity (ADR-039). Anonymous-first: every install gets a stable
/// Firebase UID with zero friction; Sign in with Apple upgrades the SAME
/// account later via credential linking (requires the paid Apple Developer
/// entitlement — deferred until membership exists). Fails soft everywhere:
/// without a Firebase config the app runs exactly as before.
@MainActor
final class AccountService: ObservableObject {
    @Published private(set) var uid: String?
    @Published private(set) var profile: UserProfile?
    @Published private(set) var statusText: String?

    private var profileListener: ListenerRegistration?
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "account")
    /// Round 8 (counsel seam-4): the queued-offline note, as a constant so the
    /// listener can recognize and retire exactly this message — and no other
    /// occupant of the shared status slot — when the server later commits.
    private static let queuedProfileStatus =
        "Profile saved on this device — syncing when online"

    func start() {
        guard AppConfig.firebaseConfigured else { return }
        if let user = Auth.auth().currentUser {
            attach(uid: user.uid)
            return
        }
        Task {
            do {
                let result = try await Auth.auth().signInAnonymously()
                attach(uid: result.user.uid)
                log.log("Signed in anonymously")
            } catch {
                statusText = "Couldn't reach the account service — retrying on next launch"
                log.error("Anonymous sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    private func attach(uid: String) {
        self.uid = uid
        profileListener?.remove()
        let doc = Firestore.firestore().collection("users").document(uid)
        // Counsel round 2 (C11): metadata events ON — the cache→server flip
        // with unchanged data is a metadata-only event, and without this the
        // server-confirmed-absence event a genuinely new user needs may never
        // arrive (seeding then never happens at all).
        profileListener = doc.addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, _ in
            Task { @MainActor in
                guard let self else { return }
                if let snapshot, snapshot.exists {
                    do {
                        self.profile = try snapshot.data(as: UserProfile.self)
                        // Round 8 (counsel seam-4): a SERVER-sourced snapshot
                        // with no pending writes is the late ack the queued
                        // verdict was waiting for — the "syncing when online"
                        // note must not outlive the sync it describes.
                        if !snapshot.metadata.isFromCache,
                           !snapshot.metadata.hasPendingWrites,
                           self.statusText == Self.queuedProfileStatus {
                            self.statusText = nil
                        }
                    } catch {
                        // Round 2 (C23): the doc EXISTS but doesn't decode
                        // (schema drift). Never seed over real data — log and
                        // keep waiting for a readable snapshot.
                        self.log.error("Profile exists but failed to decode: \(error.localizedDescription)")
                    }
                } else if let snapshot, !snapshot.exists,
                          !snapshot.metadata.isFromCache,
                          self.profile == nil,
                          self.seedTask == nil {
                    // Wave C (counsel PBS-7): only a SERVER-confirmed absence
                    // means "first run". Round 6 (counsel concurrency-3): the
                    // seed is SINGLE-FLIGHT — further snapshot events during
                    // the (retrying) seed must not start parallel loops.
                    self.seedTask = Task { [weak self] in
                        await self?.seedProfile(uid: uid)
                        self?.seedTask = nil
                    }
                }
            }
        }
    }

    private var seedTask: Task<Void, Never>?

    private func seedProfile(uid: String) async {
        let starter = UserProfile(
            uid: uid,
            handle: "guest-\(uid.prefix(6).lowercased())",
            displayName: "New Dropper"
        )
        // Round 2 (C11): bounded retry — a rules-rejected or flaky seed used to
        // log once and latch the no-profile state forever, silently.
        for attempt in 1...3 {
            // Round 6 (counsel concurrency-3): a real profile may have arrived
            // between attempts — a late retry writing the starter over it
            // (merge covers every field) was a destructive lost-update.
            guard profile == nil else { return }
            let outcome = await FirestoreAcked.setData(
                Firestore.firestore().collection("users").document(uid), from: starter
            )
            guard profile == nil else { return }
            switch outcome {
            case .acked:
                profile = starter
                return
            case .queuedLocally:
                // Staged; the listener will deliver the doc when it commits.
                // Do not overwrite local state on an unconfirmed write.
                return
            case .rejected(let error):
                log.error("Profile seed attempt \(attempt) rejected: \(error.localizedDescription)")
                if attempt == 3 {
                    // Round 10 (counsel ux-7): a REJECTION is not a connection
                    // problem — say what actually happens next (the listener
                    // re-seeds on the next launch) instead of sending the
                    // user to check a connection that is fine.
                    statusText = "Couldn't set up your profile — it will retry on the next launch"
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
            }
        }
    }

    // Round 4 (flows-6): the local acked-write copy is gone — everything
    // routes through the single FirestoreAcked seam.

    /// Handle/display-name edit. Handle uniqueness is enforced server-side in
    /// Wave 6.2 (Cloud Function + reserved-handles doc); client keeps it sane.
    func updateProfile(displayName: String, handle: String) async {
        guard let uid else { return }
        let cleanedHandle = handle.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)
        var updated = profile ?? UserProfile(uid: uid, handle: cleanedHandle, displayName: displayName)
        updated.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.handle = cleanedHandle.isEmpty ? updated.handle : cleanedHandle
        // Optimistic local update; the acked write reports a real failure when
        // the server answers. NOT awaited inline — offline, the ack arrives
        // only on reconnect, and the editor must not hang on it.
        profile = updated
        let document = Firestore.firestore().collection("users").document(uid)
        Task { [weak self] in
            let outcome = await FirestoreAcked.setData(document, from: updated)
            await MainActor.run {
                switch outcome {
                case .acked:
                    self?.statusText = nil
                case .queuedLocally:
                    // Truthful offline state; the queued write flushes later
                    // and the profile listener retires this note on the ack.
                    self?.statusText = Self.queuedProfileStatus
                case .rejected:
                    self?.statusText = "Couldn't save profile — check your connection"
                }
            }
        }
    }
}
