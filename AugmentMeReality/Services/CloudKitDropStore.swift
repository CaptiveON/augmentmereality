import CloudKit
import CoreLocation
import Foundation

/// Wave 3: shared drops via the CloudKit **public database**, so every user of the app
/// sees every (public) drop. Free tier: 10 GB public storage that grows with installs.
///
/// Requires the iCloud → CloudKit capability (paid Apple Developer team). Until then,
/// keep `AppConfig.cloudKitEnabled = false` and everything runs on the local store.
/// The store has no mutable instance state; each operation owns its CloudKit
/// request and returns value drops to the caller.
final class CloudKitDropStore: DropStore {
    private static let recordType = "GeoDrop"

    private var database: CKDatabase {
        CKContainer(identifier: AppConfig.cloudKitContainerID).publicCloudDatabase
    }

    func loadDrops(near location: CLLocation?, radius: CLLocationDistance) async throws -> [GeoDrop] {
        let predicate: NSPredicate
        if let location {
            predicate = NSPredicate(
                format: "distanceToLocation:fromLocation:(location, %@) < %f",
                location, radius
            )
        } else {
            predicate = NSPredicate(value: true)
        }
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let (matches, _) = try await database.records(matching: query, resultsLimit: 200)
        return matches.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return GeoDrop(record: record)
        }
    }

    @discardableResult
    func save(_ drop: GeoDrop) async throws -> GeoDrop {
        let recordID = CKRecord.ID(recordName: drop.id.uuidString)
        let record: CKRecord
        if let existing = try? await database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        }
        drop.populate(record)
        _ = try await database.save(record)
        return drop // legacy store stamps nothing
    }

    func delete(_ drop: GeoDrop) async throws {
        let recordID = CKRecord.ID(recordName: drop.id.uuidString)
        _ = try await database.deleteRecord(withID: recordID)
    }
}

private extension GeoDrop {
    init?(record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let contentRaw = record["content"] as? String,
            let content = Content(rawValue: contentRaw),
            let location = record["location"] as? CLLocation
        else { return nil }

        self.init(
            id: id,
            content: content,
            message: record["message"] as? String ?? "",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            heightAboveGround: record["heightAboveGround"] as? Double ?? 2,
            scale: record["scale"] as? Double ?? 1,
            facingDegrees: record["facingDegrees"] as? Double,
            assetName: record["assetName"] as? String,
            colorHex: record["colorHex"] as? String ?? "#FF4D6D",
            // legacy stopgap store: sharing fields not mapped (Firebase owns them)
            createdBy: record["createdBy"] as? String ?? "Someone",
            createdAt: record["createdAt"] as? Date ?? record.creationDate ?? Date()
        )
    }

    func populate(_ record: CKRecord) {
        record["content"] = content.rawValue
        record["message"] = message
        record["location"] = location
        record["heightAboveGround"] = heightAboveGround
        record["scale"] = scale
        record["facingDegrees"] = facingDegrees
        record["assetName"] = assetName
        record["colorHex"] = colorHex
        record["createdBy"] = createdBy
        record["createdAt"] = createdAt
    }
}
