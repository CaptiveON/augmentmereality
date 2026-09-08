#if DEBUG
import FirebaseCore
import FirebaseFirestore
import Foundation

/// Explicitly invoked by a hosted XCTest only. The app module owns Firebase so
/// the test bundle never links a second copy of Firestore/gRPC. All endpoints,
/// project identifiers and Firebase options below are synthetic and fixed.
@MainActor
enum FirestoreServerReadEmulatorProbe {
    struct Report: Sendable {
        let oldServerReadExists: Bool
        let oldServerReadHasPendingWrites: Bool
        let authoritativeReadExistsDuringPendingDelete: Bool
        let rejectedDeleteCode: Int
        let authoritativeReadExistsAfterRejection: Bool
        let authoritativeReadExistsAfterAckedDelete: Bool
        let deniedReadCode: Int
        let unansweredReadProducedNoSnapshot: Bool
        let unansweredReadElapsed: TimeInterval
        let heldWriteRPCs: Int
        let heldReadRPCs: Int
        let nativeReactionWireShapeMatches: Bool
    }

    private struct Observation: Sendable {
        let exists: Bool
        let hasPendingWrites: Bool
    }

    private struct ControlReply: Decodable {
        let project: String
        let backendReady: Bool
        let heldWrites: Int
        let heldReads: Int
    }

    private struct PendingDeleteReport {
        let old: Observation
        let existsDuringDelete: Bool
        let rejectionCode: Int
        let existsAfterRejection: Bool
        let reference: DocumentReference
    }

    private struct UnansweredReport {
        let elapsed: TimeInterval
        let counters: ControlReply
    }

    private enum Failure: Error {
        case notExplicitlyInvoked, serviceConfigurationBundled, invalidFixture
        case fixtureReadinessTimedOut(attempts: Int, lastTransportError: String)
        case expectedCachedDelete, expectedRejectedDelete, expectedAcknowledgedDelete, expectedAcknowledgedWrite
        case expectedDeniedRead, expectedUnansweredRead
    }

    private static let fixtureHTTP: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func run() async throws -> Report {
        guard ProcessInfo.processInfo.environment["AMR_NATIVE_FIRESTORE_EMULATOR_TEST"] == "1" else {
            throw Failure.notExplicitlyInvoked
        }
        // A configured default app could run unrelated authentication during
        // host startup. The opt-in build must exclude both local service files.
        guard Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") == nil,
              Bundle.main.url(forResource: "Secrets", withExtension: "plist") == nil else {
            throw Failure.serviceConfigurationBundled
        }
        try await waitForFixture()
        let name = "native-sdk-test-\(UUID().uuidString)"
        let options = FirebaseOptions(
            googleAppID: "1:000000000000:ios:0000000000000000", gcmSenderID: "000000000000"
        )
        options.projectID = "demo-amr-native-sdk"
        // Firebase Installations is eagerly registered and validates this
        // format even for a named emulator app. This is a synthetic non-key.
        options.apiKey = "A" + String(repeating: "0", count: 38)
        FirebaseApp.configure(name: name, options: options)
        guard let app = FirebaseApp.app(name: name) else { throw Failure.invalidFixture }
        let database = Firestore.firestore(app: app)
        let settings = database.settings
        settings.cacheSettings = MemoryCacheSettings()
        settings.host = "127.0.0.1:8189"
        settings.isSSLEnabled = false // Plaintext transport is restricted to the fixed loopback emulator.
        database.settings = settings
        do {
            let result = try await exercise(database)
            try await database.terminate()
            _ = await app.delete()
            return result
        } catch {
            _ = try? await control("release-writes")
            _ = try? await control("release-reads")
            try? await database.terminate()
            _ = await app.delete()
            throw error
        }
    }

    private static func exercise(_ database: Firestore) async throws -> Report {
        let pending = try await pendingDelete(database)
        let afterAcknowledgement = try await acknowledgedDelete(database)
        let deniedCode = try await deniedRead(database)
        let unanswered = try await unansweredRead(pending.reference)
        let wireShapeMatches = try await nativeReaction(database)
        return Report(
            oldServerReadExists: pending.old.exists,
            oldServerReadHasPendingWrites: pending.old.hasPendingWrites,
            authoritativeReadExistsDuringPendingDelete: pending.existsDuringDelete,
            rejectedDeleteCode: pending.rejectionCode,
            authoritativeReadExistsAfterRejection: pending.existsAfterRejection,
            authoritativeReadExistsAfterAckedDelete: afterAcknowledgement,
            deniedReadCode: deniedCode,
            unansweredReadProducedNoSnapshot: true,
            unansweredReadElapsed: unanswered.elapsed,
            heldWriteRPCs: unanswered.counters.heldWrites,
            heldReadRPCs: unanswered.counters.heldReads,
            nativeReactionWireShapeMatches: wireShapeMatches
        )
    }

    private static func pendingDelete(_ database: Firestore) async throws -> PendingDeleteReport {
        let rejectedID = UUID().uuidString
        _ = try await control("seed/rejected/\(rejectedID)")
        let rejected = database.collection("probe").document(rejectedID)
        // Prime the remote document before creating a local overlay.
        _ = try await observe(rejected, source: .server)
        _ = try await control("hold-writes")
        let deletion = AsyncThrowingStream<Void, Error> { continuation in
            rejected.delete { error in
                if let error { continuation.finish(throwing: error) }
                else { continuation.yield(()); continuation.finish() }
            }
        }
        let cached = try await observe(rejected, source: .cache)
        guard !cached.exists else { throw Failure.expectedCachedDelete }
        // The proxy holds Write RPCs, not Listen/BatchGet/Commit. This proves
        // the old .server lookup can be false while the remote doc still exists.
        let old = try await observe(rejected, source: .server)
        let duringDelete = try await FirestoreServerRead.document(rejected, timeout: 4)
        _ = try await control("release-writes")
        let rejection = await FirestoreAcked.race(deletion, timeout: 4)
        guard case .rejected(let deleteError) = rejection else {
            throw Failure.expectedRejectedDelete
        }
        let afterRejection = try await FirestoreServerRead.document(rejected, timeout: 4)
        return PendingDeleteReport(
            old: old, existsDuringDelete: duringDelete.exists,
            rejectionCode: (deleteError as NSError).code,
            existsAfterRejection: afterRejection.exists, reference: rejected
        )
    }

    private static func acknowledgedDelete(_ database: Firestore) async throws -> Bool {
        let acceptedID = UUID().uuidString
        _ = try await control("seed/accepted/\(acceptedID)")
        let accepted = database.collection("probe").document(acceptedID)
        guard case .acked = await FirestoreAcked.delete(accepted, ackTimeout: 4) else {
            throw Failure.expectedAcknowledgedDelete
        }
        let afterAcknowledgement = try await FirestoreServerRead.document(accepted, timeout: 4)
        return afterAcknowledgement.exists
    }

    private static func deniedRead(_ database: Firestore) async throws -> Int {
        let deniedID = UUID().uuidString
        _ = try await control("seed/denied/\(deniedID)")
        let denied = database.collection("probe").document(deniedID)
        do {
            _ = try await FirestoreServerRead.document(denied, timeout: 4)
            throw Failure.expectedDeniedRead
        } catch let error as NSError where error.domain == FirestoreErrorDomain {
            return error.code
        }
    }

    private static func unansweredRead(_ reference: DocumentReference) async throws -> UnansweredReport {
        // Hold the transaction's read response as an unreachable-server case.
        // A deadline must report no result, never manufacture a missing row.
        _ = try await control("hold-reads")
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await FirestoreServerRead.document(reference, timeout: 0.2)
            throw Failure.expectedUnansweredRead
        } catch FirestoreServerRead.ReadError.timedOut {
            // The expected no-result deadline.
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let counters = try await control("release-reads")
        // A successful later read also exercises late completion of the timed
        // out transaction without poisoning the next caller's result.
        _ = try await FirestoreServerRead.document(reference, timeout: 4)
        return UnansweredReport(elapsed: elapsed, counters: counters)
    }

    private static func nativeReaction(_ database: Firestore) async throws -> Bool {
        // Exercise the actual native Firestore encoder used by ReactionService,
        // including Date -> Firestore timestamp, not only JSONEncoder's shape.
        let reaction = DropReaction(emoji: "😂", uid: "fixture-user", byName: "SDK fixture")
        let reactionReference = database.collection("nativeReactions").document(reaction.id)
        guard case .acked = await FirestoreAcked.setData(
            reactionReference, from: reaction, ackTimeout: 4
        ) else { throw Failure.expectedAcknowledgedWrite }
        let reactionSnapshot = try await FirestoreServerRead.document(reactionReference, timeout: 4)
        let reactionData = reactionSnapshot.data() ?? [:]
        let wireShapeMatches = Set(reactionData.keys) == ["id", "emoji", "uid", "byName", "at"]
            && reactionData["at"] is Timestamp
            && (reactionData["id"] as? String) == reaction.id
        _ = await FirestoreAcked.delete(reactionReference, ackTimeout: 4)
        return wireShapeMatches
    }

    private static func observe(
        _ document: DocumentReference, source: FirestoreSource
    ) async throws -> Observation {
        let stream = AsyncThrowingStream<Observation, Error> { continuation in
            document.getDocument(source: source) { snapshot, error in
                if let error { continuation.finish(throwing: error) }
                else if let snapshot {
                    continuation.yield(Observation(
                        exists: snapshot.exists,
                        hasPendingWrites: snapshot.metadata.hasPendingWrites
                    ))
                    continuation.finish()
                } else { continuation.finish() }
            }
        }
        return try await FirestoreServerRead.race(stream, timeout: 4)
    }

    /// Simulator-to-fixture readiness is setup, not the Firestore deadline
    /// under test. Retry only transient transport failures within one
    /// monotonic budget; invalid fixture/project responses fail immediately.
    private static func waitForFixture() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + 30
        var attempts = 0
        var lastError = "No readiness response"
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            attempts += 1
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            do {
                _ = try await control("ready", method: "GET", timeout: min(5, remaining))
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                print("Native SDK fixture ready after \(attempts) attempt(s), \(String(format: "%.2f", elapsed))s")
                return
            } catch let error as URLError where [
                .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet
            ].contains(error.code) {
                lastError = "\(error.code.rawValue): \(error.localizedDescription)"
                print("Native SDK fixture readiness attempt \(attempts) failed: \(lastError)")
            }
            let pause = min(0.25, max(0, deadline - ProcessInfo.processInfo.systemUptime))
            try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        }
        throw Failure.fixtureReadinessTimedOut(attempts: attempts, lastTransportError: lastError)
    }

    private static func control(
        _ path: String, method: String = "POST", timeout: TimeInterval = 30
    ) async throws -> ControlReply {
        let url = URL(string: "http://127.0.0.1:8187/\(path)")!
        var request = URLRequest(url: url, timeoutInterval: max(0.001, timeout))
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
