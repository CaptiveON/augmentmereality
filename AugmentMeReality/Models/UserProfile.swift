import Foundation

/// Wave 6.1 identity (ADR-039). Captures hang off Memories, not this document.
struct UserProfile: Codable, Equatable {
    var uid: String
    /// Unique, lowercase, user-chosen; shown as @handle.
    var handle: String
    var displayName: String
    var createdAt: Date = Date()
    /// Legacy fields kept for decoding existing profile documents. There is
    /// no acknowledged-event producer or reconciliation path, so the profile
    /// deliberately does not present these values as user totals.
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
