import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Wave 6.2 magic links (PRODUCT-ROUTE §3B).
///
/// The SHARED link is https (custom schemes aren't linkified by iMessage/
/// WhatsApp — field-verified 2026-07-09): a Firebase-Hosted invite page whose
/// "Reveal in AR" button launches `augmentme://drop/<uuid>`. The app accepts
/// both forms (https becomes a Universal Link once the paid-membership
/// associated-domain entitlement exists).
enum DropSharingService {
    static let scheme = "augmentme"
    static let inviteHost = "augmentmereality.web.app"

    static func shareURL(for drop: GeoDrop) -> URL {
        URL(string: "https://\(inviteHost)/d/\(drop.id.uuidString)")!
    }

    /// The message that travels WITH the link — it must carry the magic.
    static func shareMessage(for drop: GeoDrop, senderName: String) -> String {
        let what = drop.content == .text3D && !drop.message.isEmpty
            ? "“\(drop.title)”" : "a surprise"
        let who = drop.recipientName.map { " for \($0)" } ?? ""
        return """
        🎁 \(senderName) left \(what)\(who) in the real world.
        Open in AugmentMeReality to see it where it's hiding — and react live:
        \(shareURL(for: drop).absoluteString)
        """
    }

    static func dropID(from url: URL) -> UUID? {
        // augmentme://drop/<uuid>  (launched by the invite page's button)
        if url.scheme == scheme, url.host == "drop" {
            return UUID(uuidString: url.lastPathComponent)
        }
        // https://<inviteHost>/d/<uuid>  (future Universal Link path)
        if url.scheme == "https", url.host == inviteHost,
           url.pathComponents.count >= 3, url.pathComponents[1] == "d" {
            return UUID(uuidString: url.pathComponents[2])
        }
        return nil
    }

    /// Round 12 (counsel SURF-lens-2 + SEAMS-lens-4): the three REAL outcomes
    /// of a link fetch, as a total type. Only a served `exists == false` may
    /// claim absence — policies such as the historical v2 rules deny an absent
    /// (or private) document, so permission errors, auth-in-flight,
    /// missing config and decode failures are all `.unknown`: retryable,
    /// never an expiry verdict, never an offline claim.
    enum SharedDropFetch {
        case found(GeoDrop)
        /// The SERVER answered: the document does not exist. Requires rules
        /// that permit an absent-document read, as the v3 candidate does.
        case absent
        /// No authoritative answer — offline, denied, unconfigured, or the
        /// payload didn't decode. Retry is meaningful; no cause is claimed.
        case unknown
    }

    /// Fetch a drop someone shared by link. Reads are gated by Firestore rules:
    /// visibility "link"/"public" is readable by any signed-in user.
    /// A transaction read excludes pending local writes as well as cached
    /// results, so an unacknowledged local delete cannot produce `.absent`.
    static func fetchSharedDrop(id: UUID) async -> SharedDropFetch {
        guard AppConfig.firebaseConfigured else { return .unknown }
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await FirestoreServerRead.document(
                Firestore.firestore().collection("drops").document(id.uuidString)
            )
        } catch {
            return .unknown
        }
        guard snapshot.exists else { return .absent }
        // Round 10 (counsel seams-7/lens-7): lenient envelope decode, same
        // policy as the store's — schema drift must not turn a live magic
        // link into "not available".
        struct CloudDrop: Decodable {
            var drop: GeoDrop
            var ownerUid: String
            private enum CodingKeys: String, CodingKey { case drop, ownerUid }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                drop = try c.decode(GeoDrop.self, forKey: .drop)
                ownerUid = try c.decodeIfPresent(String.self, forKey: .ownerUid) ?? ""
            }
        }
        guard var cloud = try? snapshot.data(as: CloudDrop.self) else {
            // The document EXISTS but didn't decode — that is a client-side
            // problem, never proof the drop is gone (round 12, SEAMS-lens-4).
            return .unknown
        }
        if !cloud.ownerUid.isEmpty {
            cloud.drop.ownerUid = cloud.ownerUid
        }
        // Round 8 (counsel state-6 interim fix): opening MY OWN drop's link
        // must not demote it to a viewer copy — `receivedViaLink == true` on an
        // owned drop persists to disk, permanently disabling its cloud sync
        // AND its cloud delete (remove() takes the viewer early-return).
        cloud.drop.receivedViaLink =
            !cloud.ownerUid.isEmpty && cloud.ownerUid == Auth.auth().currentUser?.uid
            ? nil : true
        return .found(cloud.drop)
    }
}
