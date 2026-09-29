import Foundation

/// Admission for live RealityKit content. Units express relative authoring cost;
/// they are neither decoded geometry size nor a measurement of resident RAM.
struct SceneContentBudget {
    struct Limits: Equatable {
        var fullCount: Int
        var fullCost: Int
        var sourceBytes: Int
        var perAssetSourceBytes: Int
        var cueCount: Int

        static let normal = Limits(fullCount: 8, fullCost: 16,
                                   sourceBytes: 64 * 1_024 * 1_024,
                                   perAssetSourceBytes: 32 * 1_024 * 1_024, cueCount: 24)
        static let serious = Limits(fullCount: 4, fullCost: 8,
                                    sourceBytes: 32 * 1_024 * 1_024,
                                    perAssetSourceBytes: 32 * 1_024 * 1_024, cueCount: 12)
        static let critical = Limits(fullCount: 1, fullCost: 4,
                                     sourceBytes: 32 * 1_024 * 1_024,
                                     perAssetSourceBytes: 32 * 1_024 * 1_024, cueCount: 6)
    }

    enum Pressure {
        case normal, serious, critical, hidden, hiddenPressure

        var limits: Limits {
            switch self {
            case .normal, .hidden: return .normal
            case .serious: return .serious
            case .critical, .hiddenPressure: return .critical
            }
        }
    }

    struct Candidate {
        let id: UUID
        let distance: Double
        let cost: Int
        /// Compressed source-file proxy for each clone; unknown is Int.max.
        let sourceBytes: Int
        let selected: Bool
        let editing: Bool
    }

    struct Selection: Equatable {
        var full: Set<UUID> = []
        var cues: Set<UUID> = []
        var totalCandidates = 0

        var visible: Set<UUID> { full.union(cues) }
        var unloadedCount: Int { max(0, totalCandidates - visible.count) }
    }

    static func select(
        _ candidates: [Candidate], previous: Selection = Selection(),
        pressure: Pressure = .normal
    ) -> Selection {
        let limits = pressure.limits
        let totalCandidateCount = Set(candidates.map(\.id)).count
        // Duplicated identities can arise when a local and cloud view of one
        // drop overlap. Keep one candidate and one resource allocation.
        var unique: [UUID: Candidate] = [:]
        for candidate in candidates {
            if case .hiddenPressure = pressure, !previous.visible.contains(candidate.id) {
                continue
            }
            if let old = unique[candidate.id], rank(old, previous: previous.full) <= rank(candidate, previous: previous.full) {
                continue
            }
            unique[candidate.id] = candidate
        }
        let available = Set(unique.keys)
        if case .hidden = pressure {
            // A short camera hide keeps existing scene ownership stable and
            // admits no new content. The preparation queue is suspended apart.
            return Selection(full: previous.full.intersection(available),
                             cues: previous.cues.intersection(available),
                             totalCandidates: totalCandidateCount)
        }

        let ordered = unique.values.sorted {
            let left = rank($0, previous: previous.full)
            let right = rank($1, previous: previous.full)
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
        var result = Selection(totalCandidates: totalCandidateCount)
        var usedCost = 0
        var usedSourceBytes = 0
        for candidate in ordered {
            let cost = max(1, candidate.cost)
            let sourceBytes = max(0, candidate.sourceBytes)
            if result.full.count < limits.fullCount,
               (pressure != .hiddenPressure || previous.full.contains(candidate.id)),
               cost <= limits.fullCost - usedCost,
               sourceBytes <= limits.perAssetSourceBytes,
               sourceBytes <= limits.sourceBytes - usedSourceBytes {
                result.full.insert(candidate.id)
                usedCost += cost
                usedSourceBytes += sourceBytes
            }
        }
        let cueOrder = ordered.filter { !result.full.contains($0.id) }.sorted {
            let left = cueRank($0, previous: previous.cues)
            let right = cueRank($1, previous: previous.cues)
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
        result.cues = Set(cueOrder.prefix(limits.cueCount).map(\.id))
        return result
    }

    private static func rank(_ candidate: Candidate, previous: Set<UUID>) -> Double {
        let distance = candidate.distance.isFinite ? max(0, candidate.distance) : .greatestFiniteMagnitude
        let stableDistance = previous.contains(candidate.id) ? distance * 0.75 : distance
        if candidate.editing { return -3_000_000 + stableDistance }
        if candidate.selected { return -2_000_000 + stableDistance }
        if distance <= 12 { return -1_000_000 + stableDistance }
        return stableDistance
    }

    private static func cueRank(_ candidate: Candidate, previous: Set<UUID>) -> Double {
        let distance = candidate.distance.isFinite ? max(0, candidate.distance) : .greatestFiniteMagnitude
        return (candidate.selected ? -2_000_000 : 0)
            + (candidate.editing ? -3_000_000 : 0)
            + (previous.contains(candidate.id) ? distance * 0.75 : distance)
    }
}
