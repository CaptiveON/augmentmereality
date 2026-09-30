#if DEBUG
import FirebaseCore
import FirebaseFirestore
import Foundation

/// Opt-in native SDK test of the production FirebaseDropStore owner query.
/// The named app, synthetic UID and local fixture are confined to Debug.
@MainActor
enum FirestoreOwnerPagingEmulatorProbe {
    struct Report: Sendable {
        let smallPageCount: Int
        let smallPageMilliseconds: Double
        let largePageCounts: [Int]
        let largePageMilliseconds: [Double]
        let largeUniqueRows: Int
        let foreignQueriesDenied: Bool
        let pendingRowWasDisplayed: Bool
        let pendingRowWasUnconfirmed: Bool
        let pendingPageWasServerServed: Bool
        let pendingPageBlockedCursor: Bool
        let heldOwnerWriteRPC: Bool
        let pendingDeleteCacheMissing: Bool
        let pendingDeletePageCount: Int
        let pendingDeleteRowOmitted: Bool
        let pendingDeletePageReachedEnd: Bool
        let pendingDeletePageWasServerServed: Bool
        let pendingDeletePageBlockedCursor: Bool
        let heldOwnerDeleteRPC: Bool
    }

    private struct ControlReply: Decodable {
        let project: String
        let backendReady: Bool
        let heldWrites: Int
        let ownerPageSeeds: Int
    }

    private enum Failure: Error {
        case notExplicitlyInvoked, serviceConfigurationBundled, invalidFixture
        case invalidOwnerPage, missingPendingWrite, missingWriteRPC, writeNotAcknowledged
    }

    private static let fixtureHTTP: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func run() async throws -> Report {
        guard ProcessInfo.processInfo.environment["AMR_NATIVE_FIRESTORE_EMULATOR_TEST"] == "1" else {
            throw Failure.notExplicitlyInvoked
        }
        guard Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") == nil,
              Bundle.main.url(forResource: "Secrets", withExtension: "plist") == nil else {
            throw Failure.serviceConfigurationBundled
        }
        let seed = try await control("seed-owner-pages", timeout: 90)
        guard seed.ownerPageSeeds == 1 else { throw Failure.invalidFixture }

        let name = "native-owner-page-\(UUID().uuidString)"
        let options = FirebaseOptions(
            googleAppID: "1:000000000000:ios:0000000000000000", gcmSenderID: "000000000000"
        )
        options.projectID = "demo-amr-native-sdk"
        options.apiKey = "A" + String(repeating: "0", count: 38)
        FirebaseApp.configure(name: name, options: options)
        // A separate client guarantees a fresh Write stream for the held
        // deletion. Reusing the edit client's already-open gRPC stream would
        // bypass the proxy's new-RPC hold and make this test nondeterministic.
        let deleteName = "\(name)-delete"
        FirebaseApp.configure(name: deleteName, options: options)
        guard let app = FirebaseApp.app(name: name),
              let deleteApp = FirebaseApp.app(name: deleteName) else {
            throw Failure.invalidFixture
        }
        let database = Firestore.firestore(app: app)
        let deletionDatabase = Firestore.firestore(app: deleteApp)
        for client in [database, deletionDatabase] {
            let settings = client.settings
            settings.cacheSettings = MemoryCacheSettings()
            settings.host = "127.0.0.1:8189"
            settings.isSSLEnabled = false
            client.settings = settings
        }
        do {
            let report = try await exercise(database, deletionDatabase: deletionDatabase)
            try await database.terminate()
            try await deletionDatabase.terminate()
            _ = await app.delete()
            _ = await deleteApp.delete()
            return report
        } catch {
            _ = try? await control("release-writes")
            try? await database.terminate()
            try? await deletionDatabase.terminate()
            _ = await app.delete()
            _ = await deleteApp.delete()
            throw error
        }
    }

    private static func exercise(
        _ database: Firestore, deletionDatabase: Firestore
    ) async throws -> Report {
        let smallStore = FirebaseDropStore(emulatorDatabase: database, ownerUID: "fixture-small")
        let smallStarted = ProcessInfo.processInfo.systemUptime
        let small = try await smallStore.loadOwnerPage(
            after: nil, limit: OwnerLibraryPagingPolicy.pageSize
        )
        let smallMilliseconds = elapsedMilliseconds(since: smallStarted)
        guard !small.read.servedFromCache, small.reachedEnd,
              small.documentIDs.count == 10, small.read.drops.count == 10,
              small.unreadableDocumentCount == 0 else { throw Failure.invalidOwnerPage }

        let ownerStore = FirebaseDropStore(emulatorDatabase: database, ownerUID: "fixture-owner")
        var cursor: String?
        var pageCounts: [Int] = []
        var pageMilliseconds: [Double] = []
        var seen: Set<UUID> = []
        for _ in 0..<5 {
            let started = ProcessInfo.processInfo.systemUptime
            let page = try await ownerStore.loadOwnerPage(
                after: cursor, limit: OwnerLibraryPagingPolicy.pageSize
            )
            pageMilliseconds.append(elapsedMilliseconds(since: started))
            pageCounts.append(page.documentIDs.count)
            guard !page.read.servedFromCache,
                  page.documentIDs.count <= OwnerLibraryPagingPolicy.pageSize,
                  page.unreadableDocumentCount == 0,
                  page.read.drops.count == page.documentIDs.count,
                  page.read.drops.allSatisfy({ $0.ownerUid == "fixture-owner" }),
                  page.read.serverConfirmedIDs == Set(page.read.drops.map(\.id)) else {
                throw Failure.invalidOwnerPage
            }
            for drop in page.read.drops {
                guard seen.insert(drop.id).inserted else { throw Failure.invalidOwnerPage }
            }
            cursor = try OwnerLibraryPagingPolicy.nextCursor(after: cursor, page: page)
            if page.reachedEnd { break }
        }
        guard pageCounts == [64, 64, 2], seen.count == 130, cursor == nil else {
            throw Failure.invalidOwnerPage
        }

        let unfilteredDenied = await isPermissionDenied(
            database.collection("drops").limit(to: 1)
        )
        let foreignDenied = await isPermissionDenied(
            database.collection("drops").whereField("ownerUid", isEqualTo: "foreign-owner")
                .order(by: FieldPath.documentID()).limit(to: 1)
        )

        // Hold the native Write RPC, then read the first owner page. The SDK
        // merges its local pending edit into a server-served query snapshot;
        // the store must display it without treating it as acknowledged.
        let beforeWrite = try await control("ready", method: "GET").heldWrites
        _ = try await control("hold-writes")
        let pendingID = ownerPageID(8)
        let reference = database.collection("drops").document(pendingID)
        let write = AsyncThrowingStream<Void, Error> { continuation in
            reference.setData([
                "ownerUid": "fixture-owner",
                "drop": ["id": pendingID, "ownerUid": "fixture-owner",
                         "message": "pending-native-edit"]
            ], merge: true) { error in
                if let error { continuation.finish(throwing: error) }
                else { continuation.yield(()); continuation.finish() }
            }
        }
        var staged = false
        for _ in 0..<40 {
            if let snapshot = try? await reference.getDocument(source: .cache),
               snapshot.metadata.hasPendingWrites {
                staged = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard staged else { throw Failure.missingPendingWrite }
        var heldOwnerWrite = false
        for _ in 0..<40 {
            heldOwnerWrite = try await control("ready", method: "GET").heldWrites > beforeWrite
            if heldOwnerWrite { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard heldOwnerWrite else { throw Failure.missingWriteRPC }

        let pendingPage = try await ownerStore.loadOwnerPage(
            after: nil, limit: OwnerLibraryPagingPolicy.pageSize
        )
        let pendingRowWasDisplayed = pendingPage.read.drops.first {
            $0.id.uuidString == pendingID
        }?.message == "pending-native-edit"
        let pendingRowWasUnconfirmed = !pendingPage.read.serverConfirmedIDs.contains(
            UUID(uuidString: pendingID)!
        )
        let pendingPageWasServerServed = !pendingPage.read.servedFromCache
        _ = try await control("release-writes")
        guard case .acked = await FirestoreAcked.race(write, timeout: 5) else {
            throw Failure.writeNotAcknowledged
        }

        // A pending delete can vanish from a query with no per-row metadata
        // left to flag the local overlay. The library's durable pending-delete
        // set must block cursor/completion evidence even in that SDK case.
        let deletionOwnerStore = FirebaseDropStore(
            emulatorDatabase: deletionDatabase, ownerUID: "fixture-owner"
        )
        let deletionBaseline = try await deletionOwnerStore.loadOwnerPage(
            after: nil, limit: OwnerLibraryPagingPolicy.pageSize
        )
        guard !deletionBaseline.read.servedFromCache,
              deletionBaseline.read.drops.contains(where: { $0.id.uuidString == pendingID }) else {
            throw Failure.invalidOwnerPage
        }
        let deletionReference = deletionDatabase.collection("drops").document(pendingID)
        let beforeDelete = try await control("ready", method: "GET").heldWrites
        _ = try await control("hold-writes")
        let deletion = AsyncThrowingStream<Void, Error> { continuation in
            deletionReference.delete { error in
                if let error { continuation.finish(throwing: error) }
                else { continuation.yield(()); continuation.finish() }
            }
        }
        var pendingDeleteCacheMissing = false
        for _ in 0..<40 {
            if let snapshot = try? await deletionReference.getDocument(source: .cache),
               !snapshot.exists {
                pendingDeleteCacheMissing = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard pendingDeleteCacheMissing else { throw Failure.missingPendingWrite }
        var heldOwnerDelete = false
        for _ in 0..<40 {
            heldOwnerDelete = try await control("ready", method: "GET").heldWrites > beforeDelete
            if heldOwnerDelete { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard heldOwnerDelete else { throw Failure.missingWriteRPC }
        let deletePage = try await deletionOwnerStore.loadOwnerPage(
            after: nil, limit: OwnerLibraryPagingPolicy.pageSize
        )
        let deletePageBlocked = !OwnerLibraryPagingPolicy.mayAdvance(
            deletePage, pendingLocalOperations: true
        )
        _ = try await control("release-writes")
        guard case .rejected = await FirestoreAcked.race(deletion, timeout: 5) else {
            throw Failure.writeNotAcknowledged
        }

        let pendingDeleteRowOmitted = !deletePage.read.drops.contains {
            $0.id.uuidString == pendingID
        }
        print("Native owner pages: small 10 docs in \(smallMilliseconds) ms; large \(pageCounts) docs in \(pageMilliseconds) ms; pending delete page \(deletePage.documentIDs.count) docs, row omitted=\(pendingDeleteRowOmitted), reached end=\(deletePage.reachedEnd), metadata pending=\(deletePage.containsPendingWrites)")
        return Report(
            smallPageCount: small.documentIDs.count,
            smallPageMilliseconds: smallMilliseconds,
            largePageCounts: pageCounts,
            largePageMilliseconds: pageMilliseconds,
            largeUniqueRows: seen.count,
            foreignQueriesDenied: unfilteredDenied && foreignDenied,
            pendingRowWasDisplayed: pendingRowWasDisplayed,
            pendingRowWasUnconfirmed: pendingRowWasUnconfirmed,
            pendingPageWasServerServed: pendingPageWasServerServed,
            pendingPageBlockedCursor: pendingPage.containsPendingWrites,
            heldOwnerWriteRPC: heldOwnerWrite,
            pendingDeleteCacheMissing: pendingDeleteCacheMissing,
            pendingDeletePageCount: deletePage.documentIDs.count,
            pendingDeleteRowOmitted: pendingDeleteRowOmitted,
            pendingDeletePageReachedEnd: deletePage.reachedEnd,
            pendingDeletePageWasServerServed: !deletePage.read.servedFromCache,
            pendingDeletePageBlockedCursor: deletePageBlocked,
            heldOwnerDeleteRPC: heldOwnerDelete
        )
    }

    private static func ownerPageID(_ index: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012X", index)
    }

    private static func elapsedMilliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private static func isPermissionDenied(_ query: Query) async -> Bool {
        do {
            _ = try await query.getDocuments(source: .server)
            return false
        } catch {
            let result = error as NSError
            return result.domain == FirestoreErrorDomain
                && result.code == FirestoreErrorCode.permissionDenied.rawValue
        }
    }

    private static func control(
        _ path: String, method: String = "POST", timeout: TimeInterval = 30
    ) async throws -> ControlReply {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:8187/\(path)")!,
            timeoutInterval: timeout
        )
        request.httpMethod = method
        let (data, response) = try await fixtureHTTP.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.invalidFixture
        }
        let reply = try JSONDecoder().decode(ControlReply.self, from: data)
        guard reply.project == "demo-amr-native-sdk", reply.backendReady else {
            throw Failure.invalidFixture
        }
        return reply
    }
}
#endif
