import os.lock

/// RealityKit's update callback submits a wake-up, never an ARFrame. There is
/// at most one queued/running main-actor update even across detach/reattach.
/// The actor reads the latest frame when it executes; old installs cannot
/// deliver into a new scene or release a newer request's slot.
final class SceneUpdateAdmission: Sendable {
    struct Ticket: Equatable, Sendable {
        let generation: UInt64
        let serial: UInt64
    }

    private struct State {
        var generation: UInt64 = 0
        var serial: UInt64 = 0
        var active = false
        var pending: Ticket?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start() -> UInt64 {
        state.withLock {
            $0.generation &+= 1
            $0.active = true
            return $0.generation
        }
    }

    func stop() {
        state.withLock {
            $0.active = false
            $0.generation &+= 1
            // A scheduled task still owns its slot until it actually finishes.
        }
    }

    func begin(generation: UInt64) -> Ticket? {
        state.withLock {
            guard $0.active, $0.generation == generation, $0.pending == nil else { return nil }
            $0.serial &+= 1
            let ticket = Ticket(generation: generation, serial: $0.serial)
            $0.pending = ticket
            return ticket
        }
    }

    func accepts(_ ticket: Ticket) -> Bool {
        state.withLock { $0.active && $0.generation == ticket.generation && $0.pending == ticket }
    }

    func finish(_ ticket: Ticket) {
        state.withLock {
            if $0.pending == ticket { $0.pending = nil }
        }
    }
}
