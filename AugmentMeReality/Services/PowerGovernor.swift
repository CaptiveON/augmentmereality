import Foundation

/// ADR-033: the power governor — the reason well-engineered AR apps stay cool
/// for hours. Heat is not managed by reacting to thermal warnings; it is managed
/// by never producing it: every expensive subsystem (VPS/semantics inference,
/// person segmentation, LiDAR meshing, neural depth) runs only in the moments
/// the scene actually needs it. This type is pure decision logic — inputs in,
/// tier out — so the policy is unit-testable with an injectable clock.
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
        /// Meters to the nearest rendered drop; nil when none.
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
    private var downgradeCandidateSince: Date?

    init(downgradeDelay: TimeInterval = 6) {
        self.downgradeDelay = downgradeDelay
    }

    mutating func evaluate(_ inputs: Inputs, at now: Date = Date()) -> Tier {
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
        if inputs.thermalCritical {
            desired = min(desired, .idle)
        }

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
