import Foundation

/// ARKit capture timestamps use monotonic uptime. One GAR session must never
/// consume the same capture twice, even when both render and timer paths feed it.
struct CaptureSubmissionGate {
    private(set) var latestTimestamp: TimeInterval?

    mutating func admit(_ timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp > 0,
              latestTimestamp.map({ timestamp > $0 }) ?? true else { return false }
        latestTimestamp = timestamp
        return true
    }

    mutating func reset() { latestTimestamp = nil }
}
