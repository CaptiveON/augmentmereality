import Foundation

/// Slots cover queued AND running jobs. Lifecycle invalidation must not release
/// them: cancelled work still occupies its executor until completion retires it.
struct OutstandingWorkBudget {
    let limit: Int
    private var tickets: Set<UUID> = []
    init(limit: Int) { precondition(limit > 0); self.limit = limit }
    var available: Int { limit - tickets.count }

    mutating func begin() -> UUID? {
        guard available > 0 else { return nil }
        let ticket = UUID()
        tickets.insert(ticket)
        return ticket
    }

    mutating func finish(_ ticket: UUID) { tickets.remove(ticket) }
}
