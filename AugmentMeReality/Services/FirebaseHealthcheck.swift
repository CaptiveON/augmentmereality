import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

/// ADR-039 acceptance probe, callable from the hosted test bundle (which must
/// NOT link Firebase itself — Firestore's gRPC double-links). Proves the
/// console setup end-to-end: plist wired, Anonymous auth enabled, Firestore
/// live, rules admitting the owner, and the production drop-store seam.
enum FirebaseHealthcheck {
    @discardableResult
    static func run() async throws -> String {
        guard AppConfig.firebaseConfigured else {
            throw NSError(
                domain: "healthcheck", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Firebase not configured"]
            )
        }
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        // 1. Anonymous auth (verifies the console toggle).
        let auth = Auth.auth()
        let user: User
        if let current = auth.currentUser {
            user = current
        } else {
            user = try await auth.signInAnonymously().user
        }

        // 2. Firestore write+read inside the rules (owner writes own user doc).
        let doc = Firestore.firestore().collection("users").document(user.uid)
        let stamp = Date().timeIntervalSince1970
        try await doc.setData(["healthcheck": stamp], merge: true)
        let snapshot = try await doc.getDocument()
        guard let readBack = snapshot.data()?["healthcheck"] as? Double,
              abs(readBack - stamp) < 0.5 else {
            throw NSError(
                domain: "healthcheck", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "user doc round-trip mismatch"]
            )
        }

        // 3. Cloud drop store round-trip through the production seam.
        let store = FirebaseDropStore()
        var drop = GeoDrop(
            content: .text3D, message: "HEALTHCHECK",
            latitude: 51.5, longitude: -0.12,
            heightAboveGround: 1, scale: 1, colorHex: "#34C759", createdBy: "test"
        )
        drop.facingDegrees = 90
        try await store.save(drop)
        let loaded = try await store.loadDrops(near: nil, radius: 0)
        guard loaded.contains(where: { $0.id == drop.id && $0.message == "HEALTHCHECK" }) else {
            throw NSError(
                domain: "healthcheck", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "saved drop did not come back"]
            )
        }
        try await store.delete(drop)
        return "uid=\(user.uid.prefix(8))… authOK firestoreOK dropStoreOK"
    }
}
