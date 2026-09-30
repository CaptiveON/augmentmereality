import Foundation

/// A local role decision. Firestore rules remain the authority for cloud writes;
/// this policy prevents client entry points from treating a viewer copy, an
/// unresolved account, or contradictory metadata as an authored drop.
enum DropOwnershipRole: Equatable {
    case owned
    case received
    /// Pre-ownerUid local rows can still be edited and can ask the cloud to
    /// establish ownership. They cannot be shared or cloud-deleted as owners
    /// until an acknowledged save stamps ownerUid on the local row.
    case legacyLocal
    case unresolved

    init(drop: GeoDrop, currentUID: String?) {
        let uid = currentUID
        let owner = drop.ownerUid
        // Firebase compares UIDs exactly. A malformed owner must not become
        // authoritative because the UI trimmed it into a match.
        if let uid, (uid.isEmpty || uid != uid.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self = .unresolved
            return
        }
        if let owner,
           (owner.isEmpty || owner != owner.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self = .unresolved
            return
        }

        if drop.receivedViaLink == true {
            // An own-UID viewer marker is contradictory. A link fetch resolves
            // an owner's own link without that marker; do not guess here.
            self = owner != nil && owner == uid ? .unresolved : .received
        } else if let owner {
            guard let uid else {
                self = .unresolved
                return
            }
            // A stamped row from a previous account may be its only local
            // copy. Without the link-receipt marker, do not offer local
            // removal as though it were a disposable received copy.
            self = owner == uid ? .owned : .unresolved
        } else {
            // Old locally authored rows predate ownerUid. Link-fetched rows
            // always carry receivedViaLink until the owner is established.
            self = .legacyLocal
        }
    }

    var canEditLocally: Bool { self == .owned || self == .legacyLocal }
    var canShareAsOwner: Bool { self == .owned }
    var canDeleteFromCloud: Bool { self == .owned }
}

enum DropPermissionError: LocalizedError {
    case missingDrop
    case cannotEdit
    case cannotShare
    case cannotRemoveUnverified
    case ownershipChanged

    var errorDescription: String? {
        switch self {
        case .missingDrop:
            return "This drop is no longer in your library"
        case .cannotEdit:
            return "This drop belongs to another account or its ownership is still being checked"
        case .cannotShare:
            return "Wait for this drop's ownership to be verified before sharing"
        case .cannotRemoveUnverified:
            return "Reconnect and verify this drop's ownership before removing it"
        case .ownershipChanged:
            return "This drop's ownership changed — reopen it and try again"
        }
    }
}
