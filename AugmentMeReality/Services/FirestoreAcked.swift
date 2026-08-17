import FirebaseFirestore
import Foundation

/// The server's verdict on a write, as three honest values (round 6, counsel
/// ship-verdict): a binary success/throw model forced callers to fake the
/// third state by gating UI lifecycles on acks that never arrive offline.
/// - `acked`: the SERVER accepted the write.
/// - `queuedLocally`: the write is staged in Firestore's durable local queue
///   (it survives app restarts and flushes on reconnect) but the server has
///   not answered within the deadline — the truthful offline outcome.
/// - `rejected`: the server (or the encoder) refused it.
enum WriteOutcome: Sendable {
    case acked
    case queuedLocally
    case rejected(Error)
}

/// Round 4/6 (counsel flows-6 + round-5 root cause): THE single write seam.
///
/// Every Firestore write in the app goes through here; raw `setData`/`delete`
/// outside this file is a review defect. Round 6 made the seam BOUNDED and
/// CANCELLABLE: the old bare continuation parked forever offline, which made
/// `Task.cancel()` decorative, leaked permanently-suspended tasks, and left
/// registry entries that silently blocked every retry.
enum FirestoreAcked {
    /// Default ack deadline. Past it the write is reported `queuedLocally` —
    /// still durably staged, still flushing on reconnect; callers keep their
    /// pending state and retry the ACK check later, not the write.
    static let defaultAckTimeout: TimeInterval = 10

    static func setData<T: Encodable>(
        _ document: DocumentReference, from value: T, merge: Bool = true,
        ackTimeout: TimeInterval = defaultAckTimeout
    ) async -> WriteOutcome {
        var stagingError: Error?
        // The build closure runs synchronously; an encoding throw means the
        // write was NEVER staged — that is a rejection, not a queue.
        let ack = AsyncThrowingStream<Void, Error> { continuation in
            do {
                try document.setData(from: value, merge: merge) { error in
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.yield(())
                        continuation.finish()
                    }
                }
            } catch {
                stagingError = error
                continuation.finish()
            }
        }
        if let stagingError { return .rejected(stagingError) }
        return await race(ack, timeout: ackTimeout)
    }

    static func delete(
        _ document: DocumentReference,
        ackTimeout: TimeInterval = defaultAckTimeout
    ) async -> WriteOutcome {
        let ack = AsyncThrowingStream<Void, Error> { continuation in
            document.delete { error in
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.yield(())
                    continuation.finish()
                }
            }
        }
        return await race(ack, timeout: ackTimeout)
    }

    /// Races the ack against the deadline. Caller cancellation resolves to
    /// `queuedLocally` (the write IS staged); it never parks a task forever.
    /// Internal (not private) — this is the injectable seam the tests drive:
    /// the stream IS the ack source, so all four outcome mappings (ack, throw,
    /// deadline, cancellation) are exercisable without a Firestore connection.
    static func race(
        _ ack: AsyncThrowingStream<Void, Error>, timeout: TimeInterval
    ) async -> WriteOutcome {
        do {
            return try await withThrowingTaskGroup(of: WriteOutcome.self) { group in
                group.addTask {
                    for try await _ in ack { return .acked }
                    // Round 8 (counsel seam-1) + round 10 (counsel seams-6):
                    // the iterator returns nil on cancellation AND on a
                    // no-yield finish (an SDK contract break). Neither is a
                    // server confirmation — `.acked` is earned ONLY by a
                    // yielded ack; every other end of the stream resolves to
                    // the truthful unknown, `.queuedLocally`.
                    return .queuedLocally
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return .queuedLocally
                }
                let first = try await group.next() ?? .queuedLocally
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            return .queuedLocally
        } catch {
            return .rejected(error)
        }
    }
}
