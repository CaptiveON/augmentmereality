import Foundation

/// ADR-014: still / walking / vehicular from GNSS speed, with hysteresis so the mode
/// never flaps (a jog must not enter vehicular; a station stop must not exit it).
///
/// Wave-5 groundwork: Transit Mode switches the render path on `vehicular`. Until that
/// path ships, the classification is surfaced in the HUD to gather field data on the
/// user's real commutes and tune these initial engineering thresholds:
/// enter vehicular at sustained >7 m/s (~25 km/h) for 5 s; exit at sustained <7 m/s
/// for 10 s (sticky through brief stops).
final class MotionClassifier {
    enum MotionState: String {
        case still, walking, vehicular
    }

    private(set) var state: MotionState = .still
    private var candidate: MotionState = .still
    private var candidateSince = Date()

    @discardableResult
    func update(speed: Double, at now: Date = Date()) -> MotionState {
        let instantaneous: MotionState
        if speed > 7 {
            instantaneous = .vehicular
        } else if speed > 0.6 {
            instantaneous = .walking
        } else {
            instantaneous = .still
        }

        if instantaneous != candidate {
            candidate = instantaneous
            candidateSince = now
        }
        guard candidate != state else { return state }

        let dwell = now.timeIntervalSince(candidateSince)
        let required: TimeInterval
        if candidate == .vehicular {
            required = 5 // slow to enter
        } else if state == .vehicular {
            required = 10 // sticky exit: survive station stops and red lights
        } else {
            required = 3
        }
        if dwell >= required {
            state = candidate
        }
        return state
    }
}
