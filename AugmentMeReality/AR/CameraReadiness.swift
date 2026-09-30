import Foundation

/// The viewfinder's user-visible readiness policy. This is independent of
/// RealityKit so lifecycle, delayed assets, and stale callbacks can be tested
/// without a camera. Times use the same monotonic uptime clock as ARFrame.
///
/// `ready` means that a selected, loaded hero was eligible in a fresh scene
/// update. It is a scene-update proxy, not proof that a pixel was presented.
struct CameraReadiness {
    enum Tracking: Equatable {
        case unknown
        case normal
        case limited
        case unavailable
    }

    enum Asset: Equatable {
        case unrequested
        case loading
        case ready
        case failed
    }

    enum Failure: Equatable {
        case cameraPermissionDenied
        case sessionFailed
        case selectedAssetFailed
    }

    enum Degradation: Equatable {
        case cameraUnavailable
        case viewfinderStalled
        case trackingLimited
        case assetDelayed
        case heroNotVisible
    }

    enum Phase: Equatable {
        case hidden
        case opening
        case discovering
        case loading
        case recovering
        case ready
        case degraded(Degradation)
        case failed(Failure)
    }

    enum WaitingFor: Equatable {
        case none
        case camera
        case tracking
        case selection
        case asset
        case heroSceneUpdate
    }

    enum SuggestedAction: Equatable {
        case none
        case wait
        case scanSurroundings
        case turnTowardHero
        case retry
        case openSettings
    }

    /// Capture this with an asynchronous asset request. An old completion must
    /// not change a new camera epoch or a subsequently selected hero.
    struct Selection: Equatable, Hashable {
        let generation: Int
        let revision: UInt64
        let heroID: UUID
    }

    /// Evidence from a SceneEvents.Update callback for the selected content.
    /// `fullContent` excludes a budget cue and `assetReady` excludes placeholders
    /// and the failed-model marker. The caller must use the frame for this update.
    struct HeroSceneEvidence {
        let capturedAt: TimeInterval
        let observedAt: TimeInterval
        let sessionRunAt: TimeInterval
        let trackingNormal: Bool
        let holderEnabled: Bool
        let fullContent: Bool
        let contentActive: Bool
        let assetReady: Bool
        let inViewport: Bool
    }

    struct Snapshot: Equatable {
        let generation: Int
        let kind: ARReadinessEpoch.Kind?
        let phase: Phase
        let waitingFor: WaitingFor
        let selection: Selection?
        let tracking: Tracking
        let asset: Asset?
        let firstFreshCameraAt: TimeInterval?
        let cameraLive: Bool
        let firstHeroSceneUpdateProxyAt: TimeInterval?
        let deadlineAt: TimeInterval?
        let timedOut: Bool

        /// A deadline reveals the camera with guidance; it never changes the
        /// phase to `ready` or asserts that the camera/hero is presented.
        var showsLiveViewfinder: Bool {
            guard phase != .hidden else { return false }
            if firstFreshCameraAt != nil || timedOut { return true }
            if case .failed = phase { return true }
            return false
        }

        var suggestedAction: SuggestedAction {
            switch phase {
            case .discovering: return .scanSurroundings
            case .degraded(.assetDelayed): return .wait
            case .degraded(.cameraUnavailable), .degraded(.viewfinderStalled),
                 .failed(.sessionFailed), .failed(.selectedAssetFailed): return .retry
            case .degraded(.trackingLimited): return .scanSurroundings
            case .degraded(.heroNotVisible): return .turnTowardHero
            case .failed(.cameraPermissionDenied): return .openSettings
            case .hidden, .opening, .loading, .recovering, .ready: return .none
            }
        }
    }

    private static let maximumCameraAge: TimeInterval = 0.25
    private static let maximumSceneUpdateAge: TimeInterval = 1.0

    private let timeoutSeconds: TimeInterval
    private var generation = -1
    private var kind: ARReadinessEpoch.Kind?
    private var startedAt: TimeInterval = 0
    private var active = false
    private var selectionRevision: UInt64 = 0
    private var selection: Selection?
    private var tracking: Tracking = .unknown
    private var lastTrackingAt: TimeInterval?
    private var asset: Asset = .unrequested
    private var assetReadyAt: TimeInterval?
    private var lastAssetAt: TimeInterval?
    private var firstFreshCameraAt: TimeInterval?
    private var cameraLive = false
    private var lastCameraObservationAt: TimeInterval?
    private var sceneUpdateStalled = false
    private var firstHeroSceneUpdateProxyAt: TimeInterval?
    private var lastHeroObservationAt: TimeInterval?
    private var heroQualifiedInLatestUpdate = false
    private var deadlineAt: TimeInterval?
    private var timedOut = false
    private var sessionFailure: Failure?

    init(timeoutSeconds: TimeInterval) {
        self.timeoutSeconds = timeoutSeconds.isFinite && timeoutSeconds > 0
            ? timeoutSeconds : 1.6
    }

    var snapshot: Snapshot {
        let phase: Phase
        if !active {
            phase = .hidden
        } else if let sessionFailure {
            phase = .failed(sessionFailure)
        } else if selection != nil && asset == .failed {
            phase = .failed(.selectedAssetFailed)
        } else if firstFreshCameraAt != nil && !cameraLive {
            phase = .degraded(.cameraUnavailable)
        } else if sceneUpdateStalled {
            phase = .degraded(.viewfinderStalled)
        } else if selection == nil && firstFreshCameraAt != nil
                    && (tracking == .limited || tracking == .unavailable) {
            phase = .degraded(.trackingLimited)
        } else if selection == nil && firstFreshCameraAt != nil {
            phase = .discovering
        } else if heroQualifiedInLatestUpdate && tracking == .normal {
            phase = .ready
        } else if timedOut || firstHeroSceneUpdateProxyAt != nil {
            phase = .degraded(degradation)
        } else if kind == .recovery || kind == .warmResume {
            phase = .recovering
        } else if firstFreshCameraAt == nil {
            phase = .opening
        } else {
            phase = .loading
        }

        let waitingFor: WaitingFor
        if !active || sessionFailure != nil || asset == .failed || phase == .ready {
            waitingFor = .none
        } else if !cameraLive {
            waitingFor = .camera
        } else if sceneUpdateStalled {
            waitingFor = .heroSceneUpdate
        } else if tracking == .limited || tracking == .unavailable {
            waitingFor = .tracking
        } else if selection == nil {
            waitingFor = .selection
        } else if tracking != .normal {
            waitingFor = .tracking
        } else if asset != .ready {
            waitingFor = .asset
        } else {
            waitingFor = .heroSceneUpdate
        }

        return Snapshot(
            generation: generation, kind: kind, phase: phase,
            waitingFor: waitingFor, selection: selection, tracking: tracking,
            asset: selection == nil ? nil : asset,
            firstFreshCameraAt: firstFreshCameraAt,
            cameraLive: cameraLive,
            firstHeroSceneUpdateProxyAt: firstHeroSceneUpdateProxyAt,
            deadlineAt: deadlineAt, timedOut: timedOut
        )
    }

    /// Each camera intent, warm resume, or reset has a strictly newer manager
    /// generation. A late begin from an older operation cannot resurrect it.
    mutating func begin(generation: Int, kind: ARReadinessEpoch.Kind,
                        heroID: UUID? = nil, at: TimeInterval) {
        guard generation > self.generation, at.isFinite else { return }
        self.generation = generation
        self.kind = kind
        startedAt = at
        active = true
        selectionRevision = heroID == nil ? 0 : 1
        selection = heroID.map {
            Selection(generation: generation, revision: selectionRevision, heroID: $0)
        }
        tracking = .unknown
        lastTrackingAt = nil
        asset = .unrequested
        assetReadyAt = nil
        lastAssetAt = nil
        firstFreshCameraAt = nil
        cameraLive = false
        lastCameraObservationAt = nil
        sceneUpdateStalled = false
        firstHeroSceneUpdateProxyAt = nil
        lastHeroObservationAt = nil
        heroQualifiedInLatestUpdate = false
        deadlineAt = at + timeoutSeconds
        timedOut = false
        sessionFailure = nil
    }

    /// A hidden/background camera has no pending deadline. Its old events are
    /// inert even if a sleeping timeout task later wakes up.
    mutating func hide(generation: Int) {
        guard active, generation == self.generation else { return }
        active = false
        deadlineAt = nil
        heroQualifiedInLatestUpdate = false
    }

    /// Changing the selected hero starts a new selection clock within the same
    /// camera epoch. Camera/tracking evidence survives; old hero work does not.
    @discardableResult
    mutating func selectHero(_ heroID: UUID?, generation: Int,
                             at: TimeInterval) -> Selection? {
        guard active, generation == self.generation, at.isFinite,
              at >= startedAt else { return selection }
        if selection?.heroID == heroID { return selection }
        selectionRevision &+= 1
        selection = heroID.map {
            Selection(generation: generation, revision: selectionRevision, heroID: $0)
        }
        asset = .unrequested
        assetReadyAt = nil
        lastAssetAt = nil
        firstHeroSceneUpdateProxyAt = nil
        lastHeroObservationAt = nil
        heroQualifiedInLatestUpdate = false
        deadlineAt = at + timeoutSeconds
        timedOut = false
        return selection
    }

    mutating func observeCamera(generation: Int, capturedAt: TimeInterval,
                                observedAt: TimeInterval, sessionRunAt: TimeInterval) {
        guard accepts(generation),
              observedAt >= (lastCameraObservationAt ?? startedAt),
              freshFrame(capturedAt: capturedAt, observedAt: observedAt,
                         sessionRunAt: sessionRunAt) else { return }
        lastCameraObservationAt = observedAt
        if firstFreshCameraAt == nil { firstFreshCameraAt = observedAt }
        cameraLive = true
    }

    /// A policy tick may revoke *current* readiness if capture or scene
    /// updates stop. The first-frame and first-hero timestamps remain
    /// historical measurements; later fresh observations can recover state.
    mutating func revokeStaleCamera(generation: Int, latestCapturedAt: TimeInterval?,
                                    lastSceneUpdateAt: TimeInterval?,
                                    observedAt: TimeInterval, sessionRunAt: TimeInterval) {
        guard accepts(generation), firstFreshCameraAt != nil,
              observedAt.isFinite,
              observedAt >= (lastCameraObservationAt ?? startedAt) else { return }
        lastCameraObservationAt = observedAt
        if let latestCapturedAt,
           freshFrame(capturedAt: latestCapturedAt, observedAt: observedAt,
                      sessionRunAt: sessionRunAt) {
            if let lastSceneUpdateAt, lastSceneUpdateAt.isFinite,
               lastSceneUpdateAt >= startedAt,
               observedAt >= lastSceneUpdateAt {
                sceneUpdateStalled = observedAt - lastSceneUpdateAt
                    >= Self.maximumSceneUpdateAge
                if sceneUpdateStalled { heroQualifiedInLatestUpdate = false }
            }
        } else {
            cameraLive = false
            heroQualifiedInLatestUpdate = false
        }
    }

    mutating func observeTracking(_ state: Tracking, generation: Int,
                                  at: TimeInterval) {
        guard accepts(generation), at.isFinite, at >= startedAt,
              at >= (lastTrackingAt ?? startedAt) else { return }
        lastTrackingAt = at
        tracking = state
        if state != .normal { heroQualifiedInLatestUpdate = false }
    }

    mutating func observeAsset(_ state: Asset, for token: Selection,
                               at: TimeInterval) {
        guard accepts(token.generation), selection == token,
              at.isFinite, at >= startedAt,
              at >= (lastAssetAt ?? startedAt) else { return }
        lastAssetAt = at
        if state != .ready {
            assetReadyAt = nil
            heroQualifiedInLatestUpdate = false
        } else if asset != .ready {
            assetReadyAt = at
        }
        asset = state
        if state == .failed { deadlineAt = nil }
    }

    mutating func observeHeroSceneUpdate(for token: Selection,
                                         evidence: HeroSceneEvidence) {
        guard accepts(token.generation), selection == token,
              evidence.observedAt.isFinite, evidence.observedAt >= startedAt,
              evidence.observedAt > (lastHeroObservationAt ?? startedAt) else { return }
        lastHeroObservationAt = evidence.observedAt
        sceneUpdateStalled = false
        let qualified = cameraLive && tracking == .normal
            && asset == .ready && evidence.trackingNormal
            && evidence.holderEnabled && evidence.fullContent
            && evidence.contentActive && evidence.assetReady
            && evidence.inViewport
            && freshFrame(capturedAt: evidence.capturedAt,
                          observedAt: evidence.observedAt,
                          sessionRunAt: evidence.sessionRunAt)
            && evidence.observedAt > max(firstFreshCameraAt ?? startedAt,
                                         assetReadyAt ?? startedAt)
        heroQualifiedInLatestUpdate = qualified
        if qualified {
            if firstHeroSceneUpdateProxyAt == nil {
                firstHeroSceneUpdateProxyAt = evidence.observedAt
            }
            deadlineAt = nil
        }
    }

    /// The timer only marks incomplete readiness as degraded. It never emits a
    /// successful hero observation, even if it fires after loading completes.
    mutating func expireDeadline(generation: Int, at: TimeInterval) {
        guard accepts(generation), let deadlineAt,
              at.isFinite, at >= deadlineAt else { return }
        timedOut = true
        self.deadlineAt = nil
    }

    mutating func failSession(_ failure: Failure, generation: Int) {
        guard accepts(generation), failure != .selectedAssetFailed else { return }
        sessionFailure = failure
        heroQualifiedInLatestUpdate = false
        deadlineAt = nil
    }

    private var degradation: Degradation {
        if !cameraLive { return .cameraUnavailable }
        if tracking != .normal { return .trackingLimited }
        if selection != nil && asset != .ready { return .assetDelayed }
        return .heroNotVisible
    }

    private func accepts(_ eventGeneration: Int) -> Bool {
        active && eventGeneration == generation && sessionFailure == nil
    }

    private func freshFrame(capturedAt: TimeInterval, observedAt: TimeInterval,
                            sessionRunAt: TimeInterval) -> Bool {
        capturedAt.isFinite && observedAt.isFinite && sessionRunAt.isFinite
            && capturedAt > max(startedAt, sessionRunAt)
            && observedAt >= capturedAt
            && observedAt - capturedAt < Self.maximumCameraAge
    }
}
