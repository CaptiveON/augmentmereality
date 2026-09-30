import Foundation

/// Workload tier policy. Device traces, rather than this policy alone, establish
/// its effect on sustained cost and thermal behavior.
struct PowerGovernor {
    /// Ordered by power draw. Comparable so thermal caps can clamp.
    enum Tier: Int, Comparable, CustomStringConvertible {
        /// Nothing worth perceiving: no rendered content, or camera off-screen
        /// (pre-warm). Camera+VIO only; VPS kept barely warm; all ML off.
        case idle = 0
        /// Content exists but the user isn't engaging with it up close (nothing
        /// in view, or everything far and settled). Occlusion for the walk-by
        /// stays; correction layers run at maintenance rates.
        case cruise = 1
        /// The magic moment: content in view / being edited / VPS converging.
        /// Everything runs at full quality.
        case full = 2

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

        var description: String {
            switch self {
            case .idle: return "idle"
            case .cruise: return "cruise"
            case .full: return "full"
            }
        }
    }

    struct Inputs {
        var cameraVisible: Bool
        var hasRenderedContent: Bool
        var contentInView: Bool
        /// Meters to the nearest relevant projected or actively edited drop;
        /// never combine an offscreen object's distance with another's visibility.
        var nearestRenderedDistance: Float?
        /// VPS enabled and still working toward an accurate localization.
        var vpsConverging: Bool
        /// A HUD slider is actively editing a drop.
        var isLiveEditing: Bool
        var thermalSerious: Bool
        var thermalCritical: Bool
    }

    private(set) var tier: Tier = .idle
    /// Downgrades wait out this window so tier flapping can't cause visible
    /// quality oscillation; upgrades are immediate (quality first).
    let downgradeDelay: TimeInterval
    let criticalRecoveryDelay: TimeInterval
    private var downgradeCandidateSince: Date?
    private var criticalRecoverySince: Date?
    private(set) var isRecoveringFromCritical = false

    init(downgradeDelay: TimeInterval = 6, criticalRecoveryDelay: TimeInterval = 6) {
        self.downgradeDelay = downgradeDelay
        self.criticalRecoveryDelay = criticalRecoveryDelay
    }

    mutating func evaluate(_ inputs: Inputs, at now: Date = Date()) -> Tier {
        // Safety edges bypass every ordinary downgrade candidate. A cool
        // interval must follow critical before expensive work can return.
        if inputs.thermalCritical {
            tier = .idle
            downgradeCandidateSince = nil
            criticalRecoverySince = nil
            isRecoveringFromCritical = true
            return tier
        }
        if isRecoveringFromCritical {
            if criticalRecoverySince == nil { criticalRecoverySince = now }
            if now.timeIntervalSince(criticalRecoverySince!) < criticalRecoveryDelay {
                tier = .idle
                downgradeCandidateSince = nil
                return tier
            }
            isRecoveringFromCritical = false
            criticalRecoverySince = nil
        }
        if !inputs.cameraVisible {
            tier = .idle
            downgradeCandidateSince = nil
            return tier
        }

        var desired: Tier
        if !inputs.cameraVisible || !inputs.hasRenderedContent {
            desired = .idle
        } else if inputs.isLiveEditing
            || inputs.vpsConverging
            || (inputs.contentInView && (inputs.nearestRenderedDistance ?? .infinity) < 60) {
            desired = .full
        } else {
            desired = .cruise
        }

        // Thermal policy (ADR-034): `.serious` does NOT demote the tier — the
        // manager sheds by subsystem priority instead (GAR cadence, neural depth,
        // semantic matte) so person occlusion and mesh stay while the user is in
        // the moment. Only `.critical` forces the idle diet to save the session.
        if desired > tier {
            tier = desired
            downgradeCandidateSince = nil
        } else if desired < tier {
            if let since = downgradeCandidateSince {
                if now.timeIntervalSince(since) >= downgradeDelay {
                    tier = desired
                    downgradeCandidateSince = nil
                }
            } else {
                downgradeCandidateSince = now
            }
        } else {
            downgradeCandidateSince = nil
        }
        return tier
    }
}
