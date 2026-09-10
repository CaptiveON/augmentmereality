import Foundation

/// A lifecycle generation identifies the camera run; a revision also invalidates
/// work when one producer is disabled and re-enabled within that same run.
/// Owners serialize access with their existing lock or main-actor isolation.
struct PerceptionWorkAdmission {
    struct Token: Equatable, Sendable {
        let sessionGeneration: UInt64
        fileprivate let revision: UInt64
    }

    private(set) var allowed = false
    private(set) var sessionGeneration: UInt64 = 0
    private var revision: UInt64 = 0

    @discardableResult
    mutating func setAllowed(_ allowed: Bool, generation: UInt64) -> Bool {
        guard self.allowed != allowed || sessionGeneration != generation else { return false }
        self.allowed = allowed
        sessionGeneration = generation
        revision &+= 1
        return true
    }

    var token: Token? {
        allowed ? Token(sessionGeneration: sessionGeneration, revision: revision) : nil
    }

    func accepts(_ candidate: Token) -> Bool {
        token == candidate
    }
}
