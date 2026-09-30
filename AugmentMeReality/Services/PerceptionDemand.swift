import Foundation

/// One scene snapshot shared by sensor configuration and per-frame consumers.
/// Distances stay attached to the projected object that made them relevant.
struct PerceptionDemand {
    struct Content: Equatable {
        var distance: Float
        var isInView: Bool
        var isEditing: Bool = false
    }

    var cameraVisible: Bool = false
    var sessionRunning: Bool = false
    var cameraRecentlyVisible: Bool = false
    var content: [Content] = []
    var heldGestures: Int = 0
    var hasLiveEditing: Bool = false
    var vpsConverging: Bool = false
    var pedestrian: Bool = true
    var windowModeActive: Bool = false
    var personLikely: Bool = false
    var thermalSerious: Bool = false
    var thermalCritical: Bool = false
    var supportsPersonSegmentation: Bool = false
    var supportsCustomPersonOcclusion: Bool = false
    var supportsSceneReconstruction: Bool = false
    var supportsSceneDepth: Bool = false
    var hasSemanticPass: Bool = false
    var geospatialAvailable: Bool = false
    var supportsSemantics: Bool = false
    var allowsPersonSegmentation: Bool = true
    var allowsReconstruction: Bool = true
    var allowsSentinel: Bool = true
    var midFieldEnabled: Bool = false
    // Existing supported bands, supplied by AppConfig by the production caller.
    var midFieldMinimumDistance: Float = 4
    var midFieldMaximumDistance: Float = 5
    var semanticMinimumDistance: Float = 55
    var semanticMatteMinimumDistance: Float = 15

    var isEditing: Bool { heldGestures > 0 || hasLiveEditing }

    static func midFieldServiceable(distance: Float, minimum: Float, maximum: Float) -> Bool {
        distance.isFinite && distance > minimum && distance < maximum
    }

    var relevantContent: [Content] {
        content.filter {
            $0.distance.isFinite && $0.distance >= 0
                && ($0.isInView || ($0.isEditing && isEditing))
        }
    }
}

/// The production manager and test fakes receive the same complete plan.
@MainActor
protocol PerceptionSubsystemAdapter: AnyObject {
    func applyPerceptionPlan(_ plan: PerceptionPolicy.Plan)
}

/// Stateful scheduling only: no sensor, render or depth algorithm lives here.
struct PerceptionPolicy {
    struct Plan: Equatable {
        var tier: PowerGovernor.Tier = .idle
        var reconstruction = false
        /// Actual ARKit requests, including the bounded ordinary off dwell.
        var person = false
        var depth = false
        /// Admission excludes streams merely retained for ordinary off dwell.
        var personAdmitted = false
        /// Built-in people occlusion remains in use while its ARKit request is
        /// retained; the custom pass can close its consumer independently.
        var personUse = false
        var customPersonUse = false
        var midField = false
        var semantics = false
        var sentinel = false
        var localization = false
        var passNeeded = false
        var hardShutdown = true
        var recoveringFromCritical = false
    }

    private let now: () -> Date
    private let perceptionOffDelay: TimeInterval
    private var governor: PowerGovernor
    private var personDownSince: Date?
    private var depthDownSince: Date?
    private(set) var plan = Plan()

    init(
        now: @escaping () -> Date = Date.init,
        downgradeDelay: TimeInterval = 6,
        perceptionOffDelay: TimeInterval = 10,
        criticalRecoveryDelay: TimeInterval = 6
    ) {
        self.now = now
        self.perceptionOffDelay = perceptionOffDelay
        governor = PowerGovernor(
            downgradeDelay: downgradeDelay, criticalRecoveryDelay: criticalRecoveryDelay
        )
    }

    /// A new ARKit run has no inherited frame semantics or off-dwell work.
    /// Critical recovery survives lifecycle changes so resume cannot bypass it.
    mutating func resetSessionRequests() {
        plan = Plan()
        plan.recoveringFromCritical = governor.isRecoveringFromCritical
        personDownSince = nil
        depthDownSince = nil
    }

    @MainActor
    @discardableResult
    mutating func update(
        _ demand: PerceptionDemand, applyingTo adapter: any PerceptionSubsystemAdapter
    ) -> Plan {
        let next = update(demand)
        adapter.applyPerceptionPlan(next)
        return next
    }

    @discardableResult
    mutating func update(_ demand: PerceptionDemand) -> Plan {
        let time = now()
        let relevant = demand.relevantContent
        let visibleSession = demand.cameraVisible && demand.sessionRunning
        let tier = governor.evaluate(.init(
            cameraVisible: visibleSession,
            hasRenderedContent: !demand.content.isEmpty,
            contentInView: !relevant.isEmpty,
            nearestRenderedDistance: relevant.map(\.distance).min(),
            vpsConverging: demand.vpsConverging,
            isLiveEditing: demand.isEditing,
            thermalSerious: demand.thermalSerious,
            thermalCritical: demand.thermalCritical
        ), at: time)
        let thermalStop = demand.thermalCritical || governor.isRecoveringFromCritical
        let hardShutdown = !visibleSession || thermalStop
        let active = !hardShutdown && tier > .idle
        let projectedWork = active && !relevant.isEmpty
        let depthPath = demand.pedestrian && !demand.windowModeActive
        let personEligible = projectedWork && !demand.windowModeActive
            && demand.supportsPersonSegmentation && demand.allowsPersonSegmentation
        let personAdmitted = personEligible && demand.personLikely
        // A distant virtual object can still have a nearby real person in front
        // of it. Person admission intentionally has no virtual-distance ceiling.
        let midField = projectedWork && depthPath && tier == .full
            && !demand.thermalSerious && demand.midFieldEnabled
            && demand.hasSemanticPass && demand.supportsSceneDepth
            && relevant.contains {
                PerceptionDemand.midFieldServiceable(
                    distance: $0.distance, minimum: demand.midFieldMinimumDistance,
                    maximum: demand.midFieldMaximumDistance
                )
            }
        let semanticDistance = demand.pedestrian
            ? max(demand.semanticMinimumDistance, demand.semanticMatteMinimumDistance)
            : demand.semanticMatteMinimumDistance
        let semantics = projectedWork && !demand.thermalSerious
            && demand.geospatialAvailable && demand.supportsSemantics && demand.hasSemanticPass
            && relevant.contains { $0.distance > semanticDistance }
        // Warm grace retains existing reconstruction only. Hiding cannot admit
        // new reconstruction, and pause/interruption/failure release all work.
        let reconstruction = demand.sessionRunning && !thermalStop
            && demand.supportsSceneReconstruction && demand.allowsReconstruction
            && demand.pedestrian
            && (demand.cameraVisible || (demand.cameraRecentlyVisible && plan.reconstruction))
        let desiredDepth = demand.supportsSceneDepth
            && ((personAdmitted && demand.supportsCustomPersonOcclusion) || midField)
        // Mode/capability loss is a hard exclusion, not an ordinary person miss.
        let stopPerson = hardShutdown || demand.windowModeActive
            || !demand.supportsPersonSegmentation || !demand.allowsPersonSegmentation
        let person = Self.retainedRequest(
            desired: personAdmitted, applied: plan.person, bypass: stopPerson,
            now: time, delay: perceptionOffDelay, downSince: &personDownSince
        )
        let stopDepth = hardShutdown || demand.windowModeActive || !demand.supportsSceneDepth
            || (!demand.pedestrian && !person)
        let depth = Self.retainedRequest(
            desired: desiredDepth, applied: plan.depth, bypass: stopDepth,
            now: time, delay: perceptionOffDelay, downSince: &depthDownSince
        )
        plan = Plan(
            tier: tier, reconstruction: reconstruction, person: person, depth: depth,
            personAdmitted: personAdmitted,
            personUse: demand.supportsCustomPersonOcclusion ? personAdmitted : person,
            customPersonUse: personAdmitted && demand.supportsCustomPersonOcclusion,
            midField: midField, semantics: semantics,
            sentinel: personEligible && demand.allowsSentinel,
            localization: !hardShutdown && demand.geospatialAvailable,
            passNeeded: (personAdmitted && demand.supportsCustomPersonOcclusion)
                || midField || semantics,
            hardShutdown: hardShutdown,
            recoveringFromCritical: governor.isRecoveringFromCritical
        )
        return plan
    }

    private static func retainedRequest(
        desired: Bool, applied: Bool, bypass: Bool,
        now: Date, delay: TimeInterval, downSince: inout Date?
    ) -> Bool {
        if bypass { downSince = nil; return false }
        if desired { downSince = nil; return true }
        guard applied else { downSince = nil; return false }
        if downSince == nil { downSince = now }
        if now.timeIntervalSince(downSince!) >= delay {
            downSince = nil
            return false
        }
        return true
    }
}
