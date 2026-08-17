import Foundation

/// Wave 6.1 identity (ADR-039). The profile is a trophy shelf, not a feed
/// (PRODUCT-ROUTE §3A): moments delivered and reactions received are the
/// headline numbers; captures hang off Memories, not off the profile doc.
struct UserProfile: Codable, Equatable {
    var uid: String
    /// Unique, lowercase, user-chosen; shown as @handle.
    var handle: String
    var displayName: String
    var createdAt: Date = Date()
    /// Denormalized counters (Cloud Functions maintain them server-side later;
    /// client-incremented until Wave 6.2's backend rules land).
    var momentsDelivered: Int = 0
    var reactionsReceived: Int = 0

    /// Two-letter monogram for avatar placeholders.
    var monogram: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        let joined = letters.joined()
        return joined.isEmpty ? "☺︎" : joined.uppercased()
    }
}
