import Foundation
import simd

/// Camera localization quality observed with the pose's AR frame. This is
/// distinct from a saved drop's geographic coordinate provenance.
struct VPSPoseQuality: Equatable {
    let horizontalAccuracyMeters: Double
    let yawAccuracyDegrees: Double
    let observedAt: Date

    var isValid: Bool {
        horizontalAccuracyMeters.isFinite && horizontalAccuracyMeters > 0
            && yawAccuracyDegrees.isFinite && (0...45).contains(yawAccuracyDegrees)
    }

    func isCurrent(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return isValid && age.isFinite && (-0.25...1.5).contains(age)
    }
}

/// Source ordering in the AR world frame and for one terrain/rooftop anchor.
struct VPSPoseVersion: Equatable {
    let sessionGeneration: UInt64
    let anchorGeneration: UInt64
    let capturedAt: TimeInterval
    let sequence: UInt64

    func matches(sessionGeneration: UInt64, anchorGeneration: UInt64) -> Bool {
        self.sessionGeneration == sessionGeneration && self.anchorGeneration == anchorGeneration
    }

    func isNewer(than previous: Self) -> Bool {
        if sessionGeneration != previous.sessionGeneration {
            return sessionGeneration > previous.sessionGeneration
        }
        if anchorGeneration != previous.anchorGeneration {
            return anchorGeneration > previous.anchorGeneration
        }
        if capturedAt != previous.capturedAt { return capturedAt > previous.capturedAt }
        return sequence > previous.sequence
    }
}

/// Decides when a resolved VPS pose may move an already visible world-locked drop.
/// A newly accepted pose always replaces the previous deferred pose for that drop.
struct VPSCorrectionAdmission {
    struct Pose {
        let position: SIMD3<Float>
        let rotation: simd_quatf

        var isFinite: Bool {
            let rotationLength = simd_length(rotation.vector)
            return position.x.isFinite && position.y.isFinite && position.z.isFinite
                && rotation.vector.x.isFinite && rotation.vector.y.isFinite
                && rotation.vector.z.isFinite && rotation.vector.w.isFinite
                && rotationLength.isFinite && rotationLength > 0.5
        }
    }

    enum Decision: Equatable {
        case reject
        case ignore
        case snap
        case deferUntilOffscreen
        case holdForEdit
        case interruptGlide
        case glide
    }

    private struct Pending {
        let transform: simd_float4x4
        let pose: Pose
        let quality: VPSPoseQuality?
        let generation: UInt64
    }

    private var pending: [UUID: Pending] = [:]
    private var lastAcceptedVersion: [UUID: VPSPoseVersion] = [:]
    /// Historical quality at acceptance; a deferred pose does not claim that
    /// this measurement remains current when it is eventually applied.
    private var lastAcceptedQuality: [UUID: VPSPoseQuality] = [:]
    private(set) var generation: UInt64 = 0

    var hasPending: Bool { !pending.isEmpty }
    var pendingIDs: [UUID] { Array(pending.keys) }

    func pendingTransform(for id: UUID) -> simd_float4x4? {
        guard let entry = pending[id], entry.generation == generation else { return nil }
        return entry.transform
    }

    func acceptedQuality(for id: UUID) -> VPSPoseQuality? { lastAcceptedQuality[id] }

    func pendingQuality(for id: UUID) -> VPSPoseQuality? {
        guard let entry = pending[id], entry.generation == generation else { return nil }
        return entry.quality
    }

    mutating func accept(
        id: UUID,
        transform: simd_float4x4,
        pose: Pose,
        version: VPSPoseVersion,
        quality: VPSPoseQuality? = nil,
        current: Pose,
        cameraPosition: SIMD3<Float>,
        isVisible: Bool,
        isFirst: Bool,
        glideActive: Bool,
        isEditing: Bool,
        at now: Date = Date()
    ) -> Decision {
        guard pose.isFinite, current.isFinite, version.capturedAt.isFinite,
              quality?.isCurrent(at: now) ?? true,
              lastAcceptedVersion[id].map({ version.isNewer(than: $0) }) ?? true
        else { return .reject }

        // Even an imperceptible newer pose cancels an older visible correction.
        lastAcceptedVersion[id] = version
        lastAcceptedQuality[id] = quality
        pending[id] = nil
        if isEditing {
            pending[id] = Pending(transform: transform, pose: pose,
                                  quality: quality, generation: generation)
            return glideActive ? .interruptGlide : .holdForEdit
        }
        if isFirst {
            pending[id] = Pending(transform: transform, pose: pose,
                                  quality: quality, generation: generation)
            return .glide
        }
        if glideActive {
            pending[id] = Pending(transform: transform, pose: pose,
                                  quality: quality, generation: generation)
            return .interruptGlide
        }

        let decision = Self.decision(from: current, to: pose,
                                     cameraPosition: cameraPosition, isVisible: isVisible)
        if decision == .deferUntilOffscreen || decision == .glide {
            pending[id] = Pending(transform: transform, pose: pose,
                                  quality: quality, generation: generation)
        }
        return decision
    }

    /// Re-evaluates the latest deferred pose after the camera or active glide moves.
    /// A still-visible correction remains queued; every other result consumes it.
    mutating func reconsider(
        id: UUID,
        current: Pose,
        cameraPosition: SIMD3<Float>,
        isVisible: Bool,
        glideActive: Bool
    ) -> Decision? {
        guard let entry = pending[id] else { return nil }
        guard entry.generation == generation else {
            pending[id] = nil
            return nil
        }
        guard !glideActive, current.isFinite else { return nil }
        let decision = Self.decision(from: current, to: entry.pose,
                                     cameraPosition: cameraPosition, isVisible: isVisible)
        if decision != .deferUntilOffscreen { pending[id] = nil }
        return decision
    }

    mutating func remove(_ id: UUID) {
        pending[id] = nil
        lastAcceptedVersion[id] = nil
        lastAcceptedQuality[id] = nil
    }

    mutating func resetGeneration() {
        generation &+= 1
        pending.removeAll()
        lastAcceptedVersion.removeAll()
        lastAcceptedQuality.removeAll()
    }

    private static func decision(
        from current: Pose, to target: Pose,
        cameraPosition: SIMD3<Float>, isVisible: Bool
    ) -> Decision {
        let displacement = simd_length(target.position - current.position)
        let viewDistance = max(simd_length(current.position - cameraPosition), 0.25)
        let screenAngle = atan2(displacement, viewDistance)
        let sourceRotation = simd_normalize(current.rotation.vector)
        let targetRotation = simd_normalize(target.rotation.vector)
        let cosine = min(1, abs(simd_dot(sourceRotation, targetRotation)))
        let rotationAngle = 2 * acos(cosine)

        // Deadbands suppress tracked-pose noise. The snap band is intentionally
        // small at close range: 30 cm at 5 m already spans about 3.4 degrees.
        if displacement <= 0.005 && rotationAngle <= 0.1 * .pi / 180 {
            return .ignore
        }
        if !isVisible || displacement >= 5 { return .glide }
        if displacement <= 0.03 && screenAngle <= 0.15 * .pi / 180
            && rotationAngle <= 0.5 * .pi / 180 {
            return .snap
        }
        return .deferUntilOffscreen
    }
}
