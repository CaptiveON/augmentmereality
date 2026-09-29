import ARCore
import ARKit
import AVFoundation
import Combine
import CoreLocation
import Foundation
import RealityKit
import os

/// Drives the AR session and keeps rendered entities in sync with nearby drops.
///
/// Placement tiers (see MASTERPLAN.md §1):
/// - **Tier B `geoTracking`** — `ARGeoAnchor`s matched against Apple's street imagery.
///   Sub-meter-ish, but only in supported cities; detected at runtime.
/// - **Tier A `gpsCompass`** — session axes aligned to gravity + true north
///   (`.gravityAndHeading`: +X = east, −Z = north). Each drop is placed at its
///   east/north offset in meters from the viewer's GPS fix; ARKit's world tracking
///   then keeps it glued to the world.
///
/// Design goals (from field testing): content must appear **instantly** with whatever
/// GPS fix exists and stay **visible from any distance** in the correct direction —
/// never "walk to the exact spot and wait". Placement is refined silently (smooth
/// slides) as better fixes arrive; a separate marker keeps far locations findable
/// while the content itself keeps its authored physical size.
@MainActor
final class GeoARSessionManager: NSObject, ObservableObject, PerceptionSubsystemAdapter, PerceptionSubsystemSink {
    enum Mode: Equatable {
        case starting, geoTracking, gpsCompass, unsupported

        var badge: String {
            switch self {
            case .starting: return "Starting…"
            case .geoTracking: return "Precise mode"
            case .gpsCompass: return "Compass mode"
            case .unsupported: return "Unsupported"
            }
        }
    }

    /// Wave 5 (§6, ADR-015): which world-lock model the renderer trusts.
    /// - `pedestrian`: VIO world-lock — place once, full parallax, all occluders.
    /// - `transit`: VIO is untrusted (vehicle at speed, glass); every frame each drop
    ///   is re-expressed relative to the camera from the dead-reckoned geo-pose, and
    ///   only the semantic matte + person segmentation occlude.
    enum RenderPath: String {
        case pedestrian, transit
    }

    static var isDeviceSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    /// Counsel ARP-1: ADR-030's custom person path composites the high-res
    /// stencil against LiDAR scene depth — BOTH must exist. `.personSegmentation`
    /// alone is supported on every A12+ device, so gating only on it made the
    /// custom path claim every phone while the Metal pass could never run on
    /// non-LiDAR hardware (stencil requested, battery burned, zero occlusion).
    /// Without scene depth the session must fall through to
    /// `.personSegmentationWithDepth`, where RealityKit's built-in people
    /// occlusion carries the feature (blurrier, but present).
    static var supportsCustomPersonOcclusion: Bool {
        AppConfig.customPersonOcclusion
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    @Published private(set) var renderPath: RenderPath = .pedestrian
    @Published private(set) var mode: Mode = .starting
    @Published private(set) var statusText = "Starting camera…"
    @Published private(set) var renderedDropCount = 0
    @Published private(set) var nearestDrop: GeoDrop?
    @Published private(set) var nearestDropDistance: CLLocationDistance?
    /// Where the engine is actually rendering the nearest drop, relative to the
    /// camera — field-debugging lifeline when "nothing is visible".
    @Published private(set) var renderDiagnostics: String?
    /// True when LiDAR scene occlusion is active (real objects hide virtual content).
    @Published private(set) var occlusionActive = false
    /// First subsequent scene update with the selected asset ready and in view.
    /// This is a proxy; RealityKit does not expose proof of hero presentation here.
    @Published private(set) var timeToFirstHeroProxyMs: Int?
    @Published private(set) var readinessEpochKind = ARReadinessEpoch.Kind.coldStart
    private(set) var readiness: ARReadinessEpoch?
    private var readinessActive = false
    private var sessionGeneration = 0
    private var hasRunSession = false
    private var readyContentIDs: Set<UUID> = []
    private var lastBaselineExportAt: TimeInterval = 0
    private var baselineHealthMilestones: Set<Int> = []
    /// Reveal signal: a fresh camera frame was observed after the current intent/run.
    @Published private(set) var sessionFrameReady = false
    /// Wave C round 2 (C20): failures that happen while the user is IN AR must
    /// be visible IN AR — a failed slider-commit persist or a failed 3D-model
    /// decode surfaces here (rendered by ARScreen), not only on the Sent tab.
    /// Transient: auto-clears after a few seconds.
    @Published private(set) var persistErrorText: String?
    private var persistErrorClearTask: Task<Void, Never>?
    /// Round 6 (counsel sync-6/arui-6): slot discipline — a cosmetic message
    /// (missing 3D model) must never evict a data-loss message (failed save)
    /// still on screen, and each failed asset announces once per session, not
    /// once per re-placement.
    private var persistErrorIsCritical = false
    private var announcedFailedAssets: Set<String> = []

    func showPersistError(_ message: String, critical: Bool = true) {
        if !critical, persistErrorText != nil, persistErrorIsCritical {
            return // never downgrade a visible data-loss message
        }
        persistErrorText = message
        persistErrorIsCritical = critical
        persistErrorClearTask?.cancel()
        persistErrorClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistErrorText = nil
            self?.persistErrorIsCritical = false
        }
    }

    /// ADR-044 window/glass mode: LiDAR meshes the PANE when you view a far
    /// drop through a window, occluding content behind an invisible wall (and
    /// reflections misfire person segmentation). Detected by a mesh-vs-geo
    /// conflict; sheds the depth-based occluders like Transit does, keeps the
    /// image-based semantic matte.
    @Published private(set) var windowModeActive = false
    private var windowEvidence = 0
    private var windowCounterEvidence = 0
    /// VPS (Tier C) status chip for the HUD; nil when VPS is disabled.
    @Published private(set) var vpsStatusText: String?
    @Published private(set) var vpsLocked = false

    /// Tier C precision layer; passive until it localizes, then owns drop poses.
    private let geospatial = GeospatialEngine()
    private var vpsOwnedDrops: Set<UUID> = []
    private var vpsGlideUntil: [UUID: Date] = [:]

    /// Wave 4.5 SilhouetteRefiner (ADR-011).
    private var semanticPass: SemanticOcclusionPass?
    @Published private(set) var semanticMatteArmed = false

    /// ADR-031 mid-field neural depth (Depth Anything V2 on the Neural Engine).
    private let midDepth = MidFieldDepthEstimator()
    @Published private(set) var midDepthActive = false

    /// One demand snapshot governs both requests and frame-driven consumers.
    private var perceptionPolicy = PerceptionPolicy()
    private var currentPerceptionPlan = PerceptionPolicy.Plan()
    private lazy var perceptionCoordinator = PerceptionCoordinator(sink: self)
    @Published private(set) var powerTier: PowerGovernor.Tier = .idle
    /// Actual capture format in use (ADR-034 field instrument — shows in HUD so
    /// a heat report always carries the resolution/fps evidence).
    @Published private(set) var videoFormatDescription = "?"
    private var cameraVisible = false
    /// Tracking can stay warm during the bounded tab grace. This is distinct
    /// from admission to any frame-driven producer or consumer.
    private var sessionRunning = false
    private var workGeneration: UInt64 { perceptionCoordinator.generation }
    private var workFramesAfter: TimeInterval = 0
    private var lastBatteryLogAt = Date.distantPast
    /// ADR-037: 2 Hz human-presence probe — the 14–29 ms/frame segmentation
    /// stream is requested only while someone is actually in frame.
    private let personSentinel = PersonSentinel()

    /// ADR-020 viewer-side lighting mode: false = natural (scene-lit PBR, real
    /// shading from surrounding light), true = full-bright emissive (night,
    /// backlit). Persisted across sessions; flipping re-skins placed content live.
    @Published private(set) var contentFullBright =
        UserDefaults.standard.bool(forKey: "contentFullBright")

    func setContentFullBright(_ on: Bool) {
        guard on != contentFullBright else { return }
        contentFullBright = on
        UserDefaults.standard.set(on, forKey: "contentFullBright")
        rebuildContentEntities()
    }

    // Systems-health metrics: scene-update cadence (proxy), p95, thermal state,
    // cumulative VPS anchor corrections (drift proxy), motion classification.
    @Published private(set) var renderFPS: Int?
    @Published private(set) var frameP95Ms: Int?
    @Published private(set) var thermalSerious = false
    @Published private(set) var vpsCorrectionCm: Int?
    @Published private(set) var motionState: MotionClassifier.MotionState = .still
    private let motion = MotionClassifier()
    private var vpsCorrectionTotals: [UUID: Float] = [:]
    private var frameCounter = 0
    private var fpsWindowStart = Date()
    private var frameIntervalsMs: [Double] = []
    private var lastFrameAt: Date?
    private var lastFrameUpdateAt = Date.distantPast
    private var lastGARFeedAt = Date.distantPast


    private weak var arView: ARView?
    private weak var locationService: LocationService?
    private weak var library: DropLibrary?

    private var tickTask: Task<Void, Never>?
    private var frameSubscription: Cancellable?
    private var demoDrops: [GeoDrop] = []
    /// ADR-025 Room Test mode: drops anchored purely in AR space (raycast surface),
    /// session-scoped, never persisted, and exempt from every geo positioner —
    /// indoors, GPS/compass/VPS are meters off by physics, so object features are
    /// tested against ARKit's room-scale tracking instead.
    private var roomDrops: [UUID: GeoDrop] = [:]
    /// A tracking reset creates a new world coordinate system. Keep session-only
    /// Room Test drops camera-relative until a fresh, normally tracked frame can
    /// place them in that new system. Exact old-world registration is unavailable
    /// after relocalization has failed, so this preserves their visual relation
    /// to the last reliable camera pose rather than claiming a physical lock.
    private struct RoomRecoveryPlacement {
        let drop: GeoDrop
        let cameraRelativeTransform: simd_float4x4
        let hadGroundLock: Bool
    }
    private var pendingRoomRecovery: [RoomRecoveryPlacement] = []
    private var lastNormalCameraTransform: simd_float4x4?

    // Tier A bookkeeping. All content hangs off one world-fixed root anchored at the
    // AR origin, so child positions are world coordinates and can be moved/animated.
    private var worldRoot: AnchorEntity?
    private var placedHolders: [UUID: Entity] = [:]
    private var placedDrops: [UUID: GeoDrop] = [:]
    /// Way-point orbs above each drop: kept at a minimum apparent size from afar so
    /// the *location* is always findable while the content itself stays true-scale.
    private var markers: [UUID: ModelEntity] = [:]
    /// The content model inside each holder, so the lighting toggle can re-skin
    /// placed drops in place without touching their pose.
    private var contentEntities: [UUID: Entity] = [:]
    /// ADR-028 in-view stability: corrections queued because the drop was on screen
    /// when they arrived. Applied the moment the drop leaves the camera's view (or
    /// immediately if the error crosses the forced threshold). BRIEF killer #2:
    /// the user witnesses presence, never placement.
    private var deferredTargets: [UUID: SIMD3<Float>] = [:]
    private var deferredVPSTransforms: [UUID: simd_float4x4] = [:]

    /// ADR-046: drops that already played their close-range reveal burst.
    private var revealedDrops: Set<UUID> = []

    /// ADR-027 ground lock: once "Place on ground" measures the real surface, that
    /// base world-Y is authoritative — GPS re-syncs and VPS terrain anchors
    /// (Google's terrain can differ ±0.5 m) must not re-float the content.
    /// Cleared when the user moves the height slider (explicit override).
    private var groundLockBaseY: [UUID: Float] = [:]
    /// Ground-contact cue sized to the content's physical footprint. It changes
    /// with authored edits or asset replacement, never with viewer distance.
    private var groundDiscs: [UUID: ModelEntity] = [:]
    /// Drops being live-edited from the HUD sliders right now: every automatic
    /// positioner (compass re-sync, VPS anchor updates) keeps its hands off them
    /// so the object never fights the user's finger.
    private var liveEditingDrops: Set<UUID> = []
    /// Wave D (counsel SWE-5): the drop identity captured at GESTURE START.
    /// Every slider tick and the release-commit resolve their target from
    /// this, never from `nearestDrop` — which is recomputed on a 400 ms timer
    /// and can change mid-drag (the old code then edited and PERSISTED a drop
    /// the user was not touching, and leaked the first drop's id into
    /// `liveEditingDrops` forever, pinning the governor to `.full`).
    private var editingDropID: UUID?
    /// Round 2 (counsel STATE-1): the last non-commit slider tick.
    private var lastLiveEditTickAt = Date.distantPast
    /// Round 3 (counsel STATE-L1) / round 4 (counsel F-D3-04): fingers
    /// physically on sliders, as a DEPTH COUNTER — one boolean couldn't
    /// represent two concurrent thumb gestures (committing one slider killed
    /// a still-live drag on another). Incremented per `beginLiveEdit`,
    /// decremented per gesture commit (floored at zero), zeroed on cancel.
    /// A stationary finger sends no value ticks, so tick-recency alone must
    /// never expire a held gesture; a 30 s backstop covers a lost end event.
    private var heldGestures = 0
    private var gestureHeld: Bool { heldGestures > 0 }
    /// Round 2 (counsel ARPCFG-4): reconstruction keys on RECENT visibility so
    /// a sub-grace tab flip can't destroy and rebuild the LiDAR mesh.
    private var lastCameraVisibleAt = Date.distantPast
    /// Round 2 (counsel ARPCFG-3): device capability for the occlusion option,
    /// computed once — the OPTION is re-derived per tick from this + live state.
    private let occlusionCapable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    private var placementBasis: CLLocation?
    private var basisCameraPosition: SIMD3<Float> = .zero
    /// Refinements are rate-limited: once content is placed it must feel nailed
    /// down, not sliding around after every sensor twitch.
    private var lastRefinementSync = Date.distantPast
    private var headingSampleCount = 0
    private let metricsLog = Logger(
        subsystem: "com.adnan.augmentmereality", category: "metrics"
    )

    // The session's north comes from one compass sample at startup and can be tens of
    // degrees off (metal, indoors). We continuously compare the live compass heading
    // against the AR camera's yaw; the smoothed difference is the session's heading
    // error, and placements are rotated to compensate. ADR-017: whenever VPS earth
    // tracking supplies a yaw measurement, it replaces the compass outright — the
    // compass is direction-dependent and lags on pans, which used to drag placements
    // sideways as the user turned.
    private var headingCorrectionSin = 0.0
    private var headingCorrectionCos = 1.0
    private var appliedHeadingCorrection = 0.0
    /// True while the estimate is fed by VPS yaw rather than the compass.
    private var headingSourceIsVPS = false
    /// Pan-rate gate bookkeeping for compass samples (ADR-017).
    private var lastCompassYawAR: Double?
    private var lastCompassSampleAt = Date.distantPast
    private var lastVPSHeadingSampleAt = Date.distantPast
    private var lastConsumedCompassTimestamp = Date.distantPast
    /// Counsel MATH-3: the heading estimate was seeded from a magnetic-only
    /// sample (cold start, before Core Location could supply true north). The
    /// declination it injected is corrected the moment the first true-north
    /// sample arrives: re-seed outright + force a placement re-sync.
    private var headingSeededMagneticOnly = false

    // Counsel ARP-5/SWE-1 session-delegate state.
    /// When `.limited(.relocalizing)` began after a warm resume; a stall longer
    /// than `relocalizeGiveUpSeconds` falls back to a cold restart.
    private var relocalizingSince: Date?
    private let relocalizeGiveUpSeconds: TimeInterval = 10
    private var lastSessionFailureRecoveryAt = Date.distantPast
    /// Wave B review (C6/C13/C18): a failure inside the recovery rate-limit
    /// window DEFERS recovery instead of dropping it, and the failed state
    /// silences the tick's status/placement work so the failure message and
    /// the dead session can't hide behind healthy-looking HUD text.
    private var sessionFailed = false
    private var failureRetryDeadline: Date?
    /// Wave B review (C9/C19): an interruption that never backgrounds the app
    /// (call banner, Split View, Control Center) leaves the tick loop running
    /// against a frozen frame — placement, heading ingestion and status writes
    /// all hold while this is true.
    private var isInterrupted = false
    /// Uptime of the most recent session (re)run. The ADR-043 reveal signal
    /// only trusts camera frames captured after it — RealityKit render ticks
    /// fire over stale frames too (final check F5).
    private var sessionRunSince: TimeInterval = 0

    /// Radians; positive means the AR world's north points east of true north.
    private var headingCorrection: Double {
        atan2(headingCorrectionSin, headingCorrectionCos)
    }

    // Tier B bookkeeping
    private var geoAnchors: [AnchorEntity] = []
    private var geoAnchoredDropIDs: Set<UUID> = []

    // MARK: - Lifecycle

    func attach(arView: ARView, locationService: LocationService, library: DropLibrary) {
        self.arView = arView
        self.locationService = locationService
        self.library = library
        markCameraIntent()

        guard Self.isDeviceSupported else {
            mode = .unsupported
            statusText = "This device can't run AR."
            return
        }
        // Counsel ARP-5/SWE-1: the baseline contract for a shipping ARKit app —
        // interruptions, errors, tracking state, and relocalization all arrive
        // through the session delegate; before this, every one of them was silent.
        arView.session.delegate = self
        decideModeAndRun()
        startTicking()
        frameSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.frameUpdate()
            }
        }

        geospatial.onDropTransform = { [weak self] dropID, transform, isFirst in
            self?.applyVPSTransform(dropID: dropID, transform: transform, isFirst: isFirst)
        }
        geospatial.start(arView: arView)

        // ADR-032: models decode in the background; drops placed before their
        // model landed carry a placeholder orb — swap in the real thing here.
        // Wave C (counsel SWE-6, round 2 C19): failures rebuild too — waiting
        // placeholders become the explicit "3D?" marker (once; the factory's
        // negative cache stops any further decode) and the user is told in-AR.
        DropEntityFactory.onAssetLoaded = { [weak self] name, success in
            self?.assetTemplateDidLoad(name)
            if !success, self?.announcedFailedAssets.insert(name).inserted == true {
                self?.showPersistError("A 3D model couldn't be loaded", critical: false)
            }
        }

        // The Metal occlusion pass hosts the VPS semantic matte (ADR-018), custom
        // person occlusion (ADR-030), and mid-field neural depth (ADR-031).
        // Create it whenever any job is possible; its render callbacks attach
        // only while a job actually has work (ADR-035) — an installed-but-idle
        // pass still costs a full-screen copy every frame.
        let wantsPersonOcclusion = Self.supportsCustomPersonOcclusion
        // Metric alignment needs LiDAR — same gate as scene depth. Model loading
        // is deferred to first actual need (ANE compile is a launch heat spike).
        let wantsMidDepth = AppConfig.midFieldDepthEnabled
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if AppConfig.vpsEnabled || wantsPersonOcclusion || wantsMidDepth {
            let pass = SemanticOcclusionPass(
                feed: geospatial.semanticFeed,
                labelBuilding: UInt32(GARSemanticLabel.building.rawValue),
                labelTree: UInt32(GARSemanticLabel.tree.rawValue),
                labelStructure: UInt32(GARSemanticLabel.structure.rawValue),
                personOcclusionEnabled: wantsPersonOcclusion,
                midDepthFeed: wantsMidDepth ? midDepth.feed : nil
            )
            pass.prepare(on: arView)
            semanticPass = pass
        }
    }

    func detach() {
        sessionRunning = false
        cameraVisible = false
        invalidatePerceptionWork(reason: "detach")
        tickTask?.cancel()
        tickTask = nil
        frameSubscription?.cancel()
        frameSubscription = nil
        sessionFailed = false
        failureRetryDeadline = nil
        isInterrupted = false
        disarmSemanticMatte()
        semanticPass?.uninstall()
        semanticPass = nil
        geospatial.stop()
        resetPlacements()
        pendingRoomRecovery.removeAll()
        lastNormalCameraTransform = nil
        arView?.session.pause()
        recordSessionPaused()
        arView = nil
        mode = .starting
        statusText = "Starting camera…"
    }

    /// Round 4 (counsel arui-4): frameUpdate — the only writer of
    /// `semanticMatteArmed` — is gated off in exactly the states where the
    /// flag must fall (interrupted, failed, suspended), so the transition
    /// INTO those states must disarm explicitly or the Metal pass stays
    /// attached, burning an offscreen render per frame with the SEM chip lit.
    private func disarmSemanticMatte() {
        semanticMatteArmed = false
        // Round 2 (counsel RSCH-2): clear() releases ARCore's pool-managed
        // semantic buffers on the same edge that stops consuming them —
        // setEnabled(false) alone pinned the last pair across the suspension.
        geospatial.semanticFeed.clear()
        semanticPass?.setCallbacksActive(false)
    }

    private func invalidatePerceptionWork(reason: String) {
        if reason != "cameraHidden" { perceptionPolicy.resetSessionRequests() }
        perceptionCoordinator.invalidate()
        currentPerceptionPlan = perceptionCoordinator.currentPlan
        workFramesAfter = ProcessInfo.processInfo.systemUptime
        midDepthActive = false
        powerTier = .idle
        if reason != "cameraHidden" { occlusionActive = false }
        for name in ["Perception localization admitted", "Perception sentinel admitted",
                     "Perception person admitted", "Perception depth admitted",
                     "Perception semantics requested", "Perception semantics admitted"] {
            ARBaselineMetrics.shared.setWorkload(name, enabled: false)
        }
        disarmSemanticMatte()
        if reason == "cameraHidden" || reason == "suspend" || reason == "detach"
            || reason == "interruption" || reason == "failure" {
            DropEntityFactory.setAssetDemand(renderedAssetNames, active: false)
        }
        ARBaselineMetrics.shared.event("perceptionInvalidated", details:
            "generation=\(workGeneration) reason=\(reason)")
    }

    /// ADR-013: the AR session outlives the camera tab (pre-warm). Suspend pauses
    /// tracking without tearing down the view, VPS session, or Metal pass.
    func suspendSession() {
        sessionRunning = false
        invalidatePerceptionWork(reason: "suspend")
        tickTask?.cancel()
        tickTask = nil
        cameraVisible = false
        sessionFrameReady = false
        // A pending failure retry must never restart the camera while the
        // surface is hidden; interruption state resets with the pause.
        failureRetryDeadline = nil
        isInterrupted = false
        disarmSemanticMatte()
        // Round 2 (counsel ARPCFG-2): a paused session APPLIES nothing — the
        // scheduler resets so resume computes a fresh plan instead of
        // replaying a tuple frozen 5 s into a tab flip (which fired a second
        // session.run at the reveal moment). Round 2 (counsel FLOW-5): a drag
        // interrupted by the suspend terminates without a commit.
        appliedPerception = (reconstruction: false, person: false, depth: false)
        cancelLiveEdit()
        arView?.session.pause()
        recordSessionPaused()
        statusText = "Paused"
    }

    /// Round 3 (counsel STATE-L1): the gesture's TRUE start — ARScreen calls
    /// this from `onEditingChanged(true)`, capturing the target while the
    /// finger is provably down. Ticks and the commit resolve from this
    /// capture; a tick arriving with NO capture and NO held gesture is stale
    /// context and is refused (re-bind refusal).
    func beginLiveEdit() {
        heldGestures = min(heldGestures + 1, 4) // bounded: >4 thumbs is noise
        lastLiveEditTickAt = Date()
        if editingDropID == nil { editingDropID = nearestDrop?.id }
    }

    /// Round 2 (counsel STATE-1/FLOW-5): terminate an unfinished slider
    /// gesture WITHOUT committing — an abandoned drag is not an edit. Clears
    /// the nearest freeze and the governor's live-edit pin.
    func cancelLiveEdit() {
        heldGestures = 0
        guard editingDropID != nil || !liveEditingDrops.isEmpty else { return }
        liveEditingDrops.removeAll()
        editingDropID = nil
    }

    /// Round 3 (counsel STATE-L1 + the caller-clock rule): abandonment as a
    /// PURE function of the caller's clock — a held gesture is never
    /// abandoned by tick recency (a stationary finger is a designed
    /// interaction); an unheld capture expires after 1.5 s; a held gesture
    /// whose end event never arrived expires after 30 s.
    nonisolated static func gestureAbandoned(
        now: Date, lastTick: Date, held: Bool
    ) -> Bool {
        let silent = now.timeIntervalSince(lastTick)
        return held ? silent > 30 : silent > 1.5
    }

    /// Round 3 (counsel ARPCFG-R2-1 + the caller-clock rule): the visibility
    /// grace as a pure function — STRICTLY outlasts the pause it exists to
    /// cover (`pauseGraceSeconds` + one tick + margin), measured from the
    /// TRUE hide edge, so no tab flip can destroy the mesh 0–400 ms before
    /// the pause that made the destruction pointless.
    nonisolated static func cameraRecentlyVisible(
        now: Date, lastVisible: Date
    ) -> Bool {
        now.timeIntervalSince(lastVisible) < AppConfig.pauseGraceSeconds + 1.0
    }

    /// Round 5 (counsel F-D4-04): the visibility term the reconstruction
    /// predicate consumes, as ONE definition used by BOTH call sites (the
    /// tick's plan and the resume plan). The round-4 equality test compared
    /// `reconstructionDesired` against a `perceptionPlan` that DELEGATES to
    /// it — f(x) == f(x), a tautology — while the real divergence surface,
    /// this composition, lived inline at two call sites. Agreement is now by
    /// construction; the table test pins this term's own truth instead.
    nonisolated static func visibilityTerm(
        cameraVisible: Bool, now: Date, lastVisible: Date
    ) -> Bool {
        cameraVisible || cameraRecentlyVisible(now: now, lastVisible: lastVisible)
    }

    /// Round 4 (counsel F-D3-02): THE reconstruction predicate — the single
    /// definition consumed by BOTH the tick's plan and the resume plan, so
    /// the two can never disagree (the round-3 resume conjunct was evaluated
    /// against caller state that made it invariantly false).
    nonisolated static func reconstructionDesired(
        supportsSceneReconstruction: Bool,
        cameraRecentlyVisible: Bool,
        pedestrian: Bool,
        thermalCritical: Bool
    ) -> Bool {
        supportsSceneReconstruction && cameraRecentlyVisible
            && pedestrian && !thermalCritical
    }

    /// Round 4 (counsel F-D3-01): WHO a GESTURE edit binds to, as a pure
    /// decision — a tick binds to its capture; with no capture it binds to
    /// nearest ONLY while a finger is provably down. AUTHORED edits (ground
    /// snap, relocate) never bind here — they carry their explicit target
    /// straight to `applyEdit`. (Round 5, counsel F-D4-DEADPARAM: the
    /// round-4 `authored:` parameter was a literal nil at the one call site
    /// — a dead branch whose table rows guarded dead code — so it is gone.)
    nonisolated static func editTarget(
        capture: UUID?, held: Bool, nearest: UUID?
    ) -> UUID? {
        if let capture { return capture }
        return held ? nearest : nil
    }

    /// Round 5 (counsel F-D4-01): the commit tail as a pure decision — one
    /// finger up decrements the count; the SHARED capture (and with it the
    /// nearest freeze at `updateNearest`) clears only when the LAST finger
    /// lifts. Round 4 cleared it from inside the mutation on the FIRST
    /// commit, un-freezing nearest under a still-held second thumb — the
    /// STATE-L1 wrong-drop persist, resurrected by the counter that fixed
    /// F-D3-04 (round 3's boolean had refused those ticks harmlessly).
    nonisolated static func commitBookkeeping(
        heldGestures: Int, capture: UUID?, committed id: UUID
    ) -> (remainingHeld: Int, capture: UUID?) {
        let remaining = max(0, heldGestures - 1)
        let captureClears = remaining == 0 && capture == id
        return (remaining, captureClears ? nil : capture)
    }

    /// Round 3 (counsel RENDER-LENS-1): the detach decision, re-derived so
    /// BOTH conjuncts bind — 5 s of no work AND 10 s attached. The round-2
    /// form (15 s idle AND 10 s attached) was a dead conjunct: attach always
    /// preceded idleness, so idle > 15 implied attached > 15.
    nonisolated static func passShouldDetach(
        idleFor: TimeInterval, attachedFor: TimeInterval
    ) -> Bool {
        PerceptionCoordinator.callbacksShouldDetach(idleFor: idleFor, attachedFor: attachedFor)
    }

    /// Counsel ARP-4/SWE-2: resume is NOT a cold start. The pre-fix path
    /// re-entered `runGPSCompass()`, whose `[.resetTracking,
    /// .removeExistingAnchors]` + `resetPlacements()` destroyed the world map,
    /// every placement, ground locks, and the heading estimate on every
    /// tab-flip past the 5 s grace window — BRIEF killers #1 and #2 in one
    /// line. ARKit's documented resume idiom is `session.run(config)` with no
    /// options: the retained world map relocalizes (the delegate answers
    /// `sessionShouldAttemptRelocalization` with true) and placements survive —
    /// the exact contract `setPerception` already relies on (ADR-033/034).
    func resumeSession() {
        guard arView != nil, mode != .unsupported else { return }
        // Final check F1: a FAILED session cannot be warm-resumed — the cold
        // run is its documented recovery (and clears the failure state).
        if sessionFailed {
            runGPSCompass()
            startTicking()
            return
        }
        guard mode == .gpsCompass else {
            if mode == .geoTracking {
                // Latent Tier B path (flag-gated off today): warm-resume it
                // too rather than silently demoting to compass (final check F4).
                let config = ARGeoTrackingConfiguration()
                config.planeDetection = [.horizontal]
                runMeasuredSession(config)
                sessionRunSince = ProcessInfo.processInfo.systemUptime
                startTicking()
            } else {
                // Never finished a cold start — do the cold start.
                runGPSCompass()
                startTicking()
            }
            return
        }
        // Round 2 (counsel ARPCFG-2): resume computes its OWN plan — never a
        // replay of the pre-suspend tuple (which was frozen mid-hysteresis and
        // fired a second session.run at the reveal moment). The stable axis
        // resumes immediately; the per-frame ML streams re-earn their place
        // from fresh frames (the sentinel's evidence decayed over the pause),
        // so the common resume is exactly ONE run.
        // Round 4 (counsel F-D3-02): ONE shared predicate for the resume plan
        // and the tick's plan — they can never disagree, so the resume runs
        // the configuration the first tick would also choose (one session.run,
        // including on the beginRevealWarmup path inside the grace window).
        let resumePlan = (
            reconstruction: Self.reconstructionDesired(
                supportsSceneReconstruction: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
                    && ARBaselineExperiment.current.allows(.reconstruction),
                cameraRecentlyVisible: Self.visibilityTerm(
                    cameraVisible: cameraVisible, now: Date(),
                    lastVisible: lastCameraVisibleAt
                ),
                pedestrian: renderPath == .pedestrian,
                thermalCritical: ProcessInfo.processInfo.thermalState == .critical
                    || perceptionPolicy.plan.recoveringFromCritical
            ),
            person: false,
            depth: false
        )
        appliedPerception = resumePlan
        runMeasuredSession(makeConfiguration(
            reconstruction: resumePlan.reconstruction,
            personSeg: false,
            sceneDepth: false
        ))
        relocalizingSince = nil
        sessionFailed = false
        failureRetryDeadline = nil
        isInterrupted = false
        sessionRunSince = ProcessInfo.processInfo.systemUptime
        statusText = "Resuming…"
        startTicking()
    }

    /// ADR-033: the governor idles all perception ML while the camera surface is
    /// off-screen (pre-warm, other tabs) — the map tab must not cook the phone.
    func markCameraHidden() {
        cameraVisible = false
        invalidatePerceptionWork(reason: "cameraHidden")
        readinessActive = false
        // Keep the selected identity for the next warm epoch. Its milestones
        // are inactive here and beginReadinessEpoch creates fresh ones on return.
        ARBaselineMetrics.shared.setWorkload("cameraVisible", enabled: false)
        ARBaselineMetrics.shared.event("cameraHidden")
        ARBaselineMetrics.shared.endEpoch(reason: "cameraHidden")
        ARBaselineMetrics.shared.export()
        // Round 3 (counsel ARPCFG-R2-1): the TRUE hide edge is stamped here —
        // the per-tick stamp was up to 400 ms stale, so the grace expired
        // just before the 5 s pause it exists to cover and roughly half of
        // tab flips still destroyed the mesh.
        lastCameraVisibleAt = Date()
        // Round 2 (counsel FLOW-5): a drag can't outlive the surface it was
        // dragging on — abandon it now, never at the next commit that will
        // never come.
        cancelLiveEdit()
        // Shed fast streams now; reconstruction keeps its existing grace.
        updatePowerTier()
    }

    /// Camera intent precedes session startup, including Receive warmup.
    func markCameraIntent(heroID: UUID? = nil) {
        if let heroID, let previous = readiness?.heroID, heroID != previous {
            readiness = nil
            readinessActive = false
        }
        if !readinessActive {
            beginReadinessEpoch(sessionFailed ? .recovery : (hasRunSession ? .warmResume : .coldStart))
        }
        if let heroID, readiness?.heroID == nil {
            readiness?.selectHero(heroID)
            ARBaselineMetrics.shared.event("selectedHero", details: "id=\(heroID) source=receivedDrop")
        }
    }

    func markCameraVisible() {
        if !cameraVisible { workFramesAfter = ProcessInfo.processInfo.systemUptime }
        cameraVisible = true
        markCameraIntent()
        ARBaselineMetrics.shared.setWorkload("cameraVisible", enabled: true)
        ARBaselineMetrics.shared.event("cameraVisible")
    }

    private func beginReadinessEpoch(_ kind: ARReadinessEpoch.Kind) {
        sessionGeneration += 1
        readinessActive = true
        readinessEpochKind = kind
        let retainedHero = kind != .coldStart ? readiness?.heroID : nil
        readiness = ARReadinessEpoch(kind: kind, generation: sessionGeneration,
                                     startedAt: ProcessInfo.processInfo.systemUptime)
        if let retainedHero { readiness?.selectHero(retainedHero) }
        timeToFirstHeroProxyMs = nil
        baselineHealthMilestones.removeAll()
        lastBaselineExportAt = ProcessInfo.processInfo.systemUptime
        sessionFrameReady = false
        frameCounter = 0
        fpsWindowStart = Date()
        frameIntervalsMs.removeAll(keepingCapacity: true)
        lastFrameAt = nil
        renderFPS = nil
        frameP95Ms = nil
        ARBaselineMetrics.shared.beginEpoch(kind: kind.rawValue, generation: sessionGeneration,
                                            at: readiness?.startedAt)
        let metrics = ARBaselineMetrics.shared
        if metrics.isEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
            metrics.condition("brightness", value: String(Double(UIScreen.main.brightness)))
            metrics.condition("batteryState", value: String(UIDevice.current.batteryState.rawValue))
            metrics.condition("batteryFraction", value: String(UIDevice.current.batteryLevel))
            metrics.condition("initialThermalState", value: String(ProcessInfo.processInfo.thermalState.rawValue))
        }
        metrics.event(kind == .recovery ? "recoveryIntent" : "cameraIntent")
        if let retainedHero {
            ARBaselineMetrics.shared.event("selectedHero", details: "id=\(retainedHero) source=retainedSelection")
        }
    }

    /// Drops a throwaway "IT WORKS 🎉" 15 m in the direction the user is facing —
    /// instant gratification without walking anywhere. Not persisted.
    func placeDemoDrop() {
        guard let location = locationService?.currentLocation(),
              let heading = locationService?.currentHeading(),
              let coordinate = GeoMath.checkedCoordinate(
                from: location.coordinate, bearingDegrees: heading.degrees, distanceMeters: 15
              ) else { return }
        let drop = GeoDrop(
            content: .text3D,
            message: "IT WORKS 🎉",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            heightAboveGround: 2,
            scale: 1.5,
            colorHex: "#34C759",
            createdBy: "You"
        )
        demoDrops.append(drop)
    }

    // MARK: - Room Test mode (ADR-025)

    /// Spawns content on the real surface under the screen-center crosshair
    /// (fallback: 2.5 m ahead at standing height). AR-space anchored: the geo
    /// pipeline never touches it, so it is rock-solid indoors. All live tools
    /// (sliders, ground snap, lighting, occlusion) work on it normally.
    func placeRoomDrop(content: GeoDrop.Content, assetName: String? = nil) {
        guard let arView else { return }
        let camera = arView.cameraTransform
        let coordinate = locationService?.location?.coordinate
            ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        var drop = GeoDrop(
            content: content,
            message: content == .text3D ? "ROOM TEST" : "",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            heightAboveGround: 0,
            scale: 1,
            colorHex: "#32ADE6",
            createdBy: "Room test"
        )
        drop.assetName = assetName
        roomDrops[drop.id] = drop
        placedDrops[drop.id] = drop

        // A baseline Room Test must not inherit an unrelated saved geo drop
        // selected before the operator places the intended fixture. Keep the
        // camera epoch's origin and generation, then pin its first Room Test ID.
        if ARBaselineExperiment.current.selectsRoomHero, readinessActive,
           var epoch = readiness, epoch.heroID == nil {
            epoch.selectHero(drop.id)
            readiness = epoch
            ARBaselineMetrics.shared.event("selectedHero", details:
                "id=\(drop.id) asset=\(assetName ?? content.rawValue) source=roomSelection")
        }

        let holder = makeHolder(for: drop)
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first {
            let t = hit.worldTransform.columns.3
            holder.position = [t.x, t.y + 0.01, t.z]
        } else {
            let forward = -simd_normalize(SIMD3<Float>(
                camera.matrix.columns.2.x, camera.matrix.columns.2.y, camera.matrix.columns.2.z
            ))
            var position = camera.translation + forward * 2.5
            position.y = camera.translation.y - 1.2
            holder.position = position
        }
        holder.orientation = simd_quatf(
            angle: atan2(camera.translation.x - holder.position.x,
                         camera.translation.z - holder.position.z),
            axis: [0, 1, 0]
        )
        ensureWorldRoot(in: arView).addChild(holder)
        placedHolders[drop.id] = holder
        DropEntityFactory.startAnimations(on: holder)
        renderedDropCount = placedHolders.count
        synchronizeAssetDemand()
        observeSelectedContentReadiness()
    }

    func clearRoomDrops() {
        // Round 2 (counsel STATE-3): the third destroy site goes through the
        // ONE cleanup helper like every other — its ad-hoc loop missed
        // editingDropID and revealedDrops.
        for id in roomDrops.keys {
            removePerDropState(id)
        }
        roomDrops.removeAll()
        pendingRoomRecovery.removeAll()
        renderedDropCount = placedHolders.count
    }

    var hasRoomDrops: Bool { !roomDrops.isEmpty }

    // MARK: - Session setup

    private func decideModeAndRun() {
        // Compass mode immediately; upgrades only if this run remains current.
        runGPSCompass()
        if AppConfig.appleGeoAnchorsEnabled, ARGeoTrackingConfiguration.isSupported {
            let generation = workGeneration
            ARGeoTrackingConfiguration.checkAvailability { [weak self] available, _ in
                Task { @MainActor in
                    guard let self, self.arView != nil, self.sessionRunning,
                          self.cameraVisible, self.workGeneration == generation,
                          !self.isInterrupted, !self.sessionFailed else { return }
                    if available {
                        self.runGeoTracking()
                    }
                }
            }
        }
    }

    private func runGeoTracking() {
        guard arView != nil else { return }
        let roomRecovery = snapshotRoomDropsForReset()
        if hasRunSession, readiness?.kind != .recovery || !readinessActive
            || readiness?.firstFreshFrameAt != nil {
            beginReadinessEpoch(.recovery)
        }
        let config = ARGeoTrackingConfiguration()
        config.planeDetection = [.horizontal]
        runMeasuredSession(config, options: [.resetTracking, .removeExistingAnchors])
        resetPlacements()
        pendingRoomRecovery = roomRecovery
        lastNormalCameraTransform = nil
        geospatial.invalidateAllAnchors() // ARP-4: anchors die with the old frame
        mode = .geoTracking
        statusText = "Scanning surroundings to lock precise position…"
    }

    /// Builds the world-tracking configuration for a perception level (ADR-033/034).
    /// `activePerception: false` is the idle diet — camera+VIO+planes only: no
    /// LiDAR meshing, no depth, no person segmentation. `personSeg` adds the
    /// person ML on top — only worth its watts while content is actually in view.
    private func makeConfiguration(
        reconstruction: Bool, personSeg: Bool, sceneDepth: Bool
    ) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        // With VPS active, Google requires plain .gravity alignment (heading-based
        // alignment can rotate the session frame under GARSession's feet). Our
        // heading estimator then supplies north for the compass tier; without VPS,
        // ARKit's own heading alignment gives the best instant start.
        config.worldAlignment = AppConfig.vpsEnabled ? .gravity : .gravityAndHeading
        config.planeDetection = [.horizontal]

        // Wave D (counsel SWE-11): scene reconstruction is STATEFUL — every
        // re-enable rebuilds the mesh from nothing, leaving a multi-second
        // occlusion hole while sceneUnderstanding still requests occlusion.
        // It is requested for the whole camera-visible pedestrian session
        // (shed in transit — counsel ARP-8: meshing glass at vehicle speed
        // for no consumer — and at thermal .critical), decoupled from the
        // fast person/depth semantics gating below.
        if reconstruction, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        // Raw scene depth (ADR-035/037): Apple's depth ML fusion runs at a
        // fixed 60 Hz internally whenever requested — request it only for
        // its actual consumers (person depth-test, mid-field alignment).
        if sceneDepth,
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        // ADR-030 people occlusion: stencil-only `.personSegmentation` (does
        // NOT trigger RealityKit's blurry built-in people occlusion); our
        // Metal pass owns the edge. Counsel ARP-1: the custom path also
        // requires LiDAR scene depth for its depth test — on hardware
        // without it, fall through to `.personSegmentationWithDepth` so
        // RealityKit's built-in people occlusion actually runs (the old
        // gate requested a stencil the pass could never composite: full
        // segmentation cost, zero occlusion, on most of the install base).
        if personSeg {
            if Self.supportsCustomPersonOcclusion, semanticPass != nil,
               ARBaselineExperiment.current.allows(.postprocess) {
                config.frameSemantics.insert(.personSegmentation)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                config.frameSemantics.insert(.personSegmentationWithDepth)
            }
        }

        // ADR-030/034 + Wave D (counsel ARP-6): the capture-format policy has
        // BOTH bounds — fps ≤ target AND area within [720p … 1920×1440]. The
        // old floor-only, exact-fps filter could re-select the 4K@30 heat bug
        // ADR-034 exists to kill, and silently left ARKit's 60 fps default
        // standing when no exact-30 format existed.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let descriptors = formats.map {
            (fps: $0.framesPerSecond,
             width: Int($0.imageResolution.width),
             height: Int($0.imageResolution.height))
        }
        if let index = Self.pickVideoFormat(from: descriptors) {
            config.videoFormat = formats[index]
            let chosen = config.videoFormat
            videoFormatDescription = String(
                format: "%.0f×%.0f@%d",
                chosen.imageResolution.width, chosen.imageResolution.height,
                chosen.framesPerSecond
            )
            metricsLog.log("Capture format \(self.videoFormatDescription)")
        } else {
            // The policy is UNSATISFIABLE on this device — never silent: the
            // HUD carries the evidence (ADR-030 calls capture the single
            // biggest heat lever) and the log makes it a field diagnostic.
            let chosen = config.videoFormat
            videoFormatDescription = String(
                format: "%.0f×%.0f@%d · UNCAPPED",
                chosen.imageResolution.width, chosen.imageResolution.height,
                chosen.framesPerSecond
            )
            metricsLog.error("CAPTURE FORMAT POLICY UNSATISFIABLE — platform default stands (heat risk): \(self.videoFormatDescription)")
        }
        return config
    }

    /// Wave D (counsel ARP-6): the format policy as a PURE function so the
    /// device suite can table-test it without constructing ARVideoFormats.
    /// Preference: highest fps ≤ target, then smallest adequate area.
    /// nil = no format satisfies policy — the caller logs loudly.
    nonisolated static func pickVideoFormat(
        from formats: [(fps: Int, width: Int, height: Int)],
        targetFPS: Int = AppConfig.targetFrameRate
    ) -> Int? {
        let minArea = 1280 * 720
        let maxArea = 1920 * 1440
        var best: (index: Int, fps: Int, area: Int)?
        for (index, format) in formats.enumerated() {
            let area = format.width * format.height
            guard format.fps <= targetFPS, area >= minArea, area <= maxArea else { continue }
            if let current = best {
                if format.fps > current.fps
                    || (format.fps == current.fps && area < current.area) {
                    best = (index: index, fps: format.fps, area: area)
                }
            } else {
                best = (index: index, fps: format.fps, area: area)
            }
        }
        return best?.index
    }

    private func runGPSCompass() {
        guard let arView else { return }
        let roomRecovery = snapshotRoomDropsForReset()
        if hasRunSession, readiness?.kind != .recovery || !readinessActive
            || readiness?.firstFreshFrameAt != nil {
            beginReadinessEpoch(.recovery)
        }
        // Sessions start on the idle diet (pre-warm often precedes any content);
        // the governor upgrades perception the moment something renders.
        let config = makeConfiguration(reconstruction: false, personSeg: false, sceneDepth: false)
        appliedPerception = (reconstruction: false, person: false, depth: false)

        if occlusionCapable {
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
            // Collision shapes on the LiDAR mesh: lets "Place on ground" raycast
            // the real reconstructed surface (ADR-027).
            arView.environment.sceneUnderstanding.options.insert(.collision)
        }
        // Wave D (SWE-11 tail): the chip is LIVE state now — the idle diet has
        // no reconstruction yet; the first governor tick raises it honestly.
        occlusionActive = false

        runMeasuredSession(config, options: [.resetTracking, .removeExistingAnchors])
        resetPlacements()
        pendingRoomRecovery = roomRecovery
        lastNormalCameraTransform = nil
        // Counsel ARP-4: the reset created a NEW world frame — every GARAnchor
        // still lives in the old one. Drop them (keeping the GARSession itself,
        // which is reset-robust) so anchors re-resolve in the fresh frame.
        geospatial.invalidateAllAnchors()
        // A cold run IS the recovery — clear the failure/interruption holds.
        sessionFailed = false
        failureRetryDeadline = nil
        isInterrupted = false
        sessionRunSince = ProcessInfo.processInfo.systemUptime
        mode = .gpsCompass
        statusText = "Waiting for a GPS fix…"
    }

    /// ADR-033/034/037: swap the perception diet WITHOUT resetting tracking —
    /// anchors, world map, and placed content all survive `session.run(config)`.
    /// Wave D (counsel SWE-11): the reconstruction request is its own axis —
    /// stable across tier cycles — while person/depth stay fast-gated.
    private var appliedPerception = (reconstruction: false, person: false, depth: false)
    private func setPerception(reconstruction: Bool, person: Bool, depth: Bool) {
        let desired = (reconstruction: reconstruction, person: person, depth: depth)
        guard desired != appliedPerception, mode == .gpsCompass, arView != nil else { return }
        appliedPerception = desired
        runMeasuredSession(makeConfiguration(
            reconstruction: desired.reconstruction,
            personSeg: desired.person,
            sceneDepth: desired.depth
        ))
        // Round 2 (counsel ARPCFG-2): a reconfiguration restarts the frame
        // stream — the ADR-043 reveal gate must not be satisfied by a frame
        // that predates it.
        sessionRunSince = ProcessInfo.processInfo.systemUptime
        metricsLog.log("Perception recon=\(desired.reconstruction) person=\(desired.person) depth=\(desired.depth) (tier \(self.powerTier.description))")
    }

    private func resetPlacements() {
        if let arView {
            for anchor in geoAnchors {
                arView.scene.removeAnchor(anchor)
            }
            if let worldRoot {
                arView.scene.removeAnchor(worldRoot)
            }
        }
        geoAnchors.removeAll()
        geoAnchoredDropIDs.removeAll()
        worldRoot = nil
        placedHolders.removeAll()
        placedDrops.removeAll()
        markers.removeAll()
        contentEntities.removeAll()
        groundDiscs.removeAll()
        groundLockBaseY.removeAll()
        deferredTargets.removeAll()
        deferredVPSTransforms.removeAll()
        liveEditingDrops.removeAll()
        editingDropID = nil
        heldGestures = 0
        // Wave D (counsel SWE-12): a session reset forgets reveals too — the
        // set grew unbounded across resets before.
        revealedDrops.removeAll()
        roomDrops.removeAll()
        placementBasis = nil
        headingCorrectionSin = 0
        headingCorrectionCos = 1
        appliedHeadingCorrection = 0
        headingSampleCount = 0
        headingSourceIsVPS = false
        lastCompassYawAR = nil
        lastCompassSampleAt = .distantPast
        lastVPSHeadingSampleAt = .distantPast
        lastConsumedCompassTimestamp = .distantPast
        lastRefinementSync = .distantPast
        headingSeededMagneticOnly = false
        relocalizingSince = nil
        vpsOwnedDrops.removeAll()
        vpsGlideUntil.removeAll()
        vpsCorrectionTotals.removeAll()
        vpsCorrectionCm = nil
        renderedDropCount = 0
        readyContentIDs.removeAll()
        timeToFirstHeroProxyMs = nil

    }

    /// Capture the previous normal frame before ARKit discards its world map.
    /// A second reset while waiting for a new normal frame keeps the original
    /// snapshot; otherwise the Room Test would vanish on a failure burst.
    private func snapshotRoomDropsForReset() -> [RoomRecoveryPlacement] {
        guard !roomDrops.isEmpty, let arView else { return pendingRoomRecovery }
        let camera = lastNormalCameraTransform
            ?? arView.session.currentFrame?.camera.transform
            ?? arView.cameraTransform.matrix
        let placed = roomDrops.values.compactMap { drop -> RoomRecoveryPlacement? in
            guard let holder = placedHolders[drop.id] else { return nil }
            return RoomRecoveryPlacement(
                drop: drop,
                cameraRelativeTransform: Self.roomCameraRelativeTransform(
                    camera: camera, holder: holder.transformMatrix(relativeTo: nil)),
                hadGroundLock: groundLockBaseY[drop.id] != nil
            )
        }
        let placedIDs = Set(placed.map { $0.drop.id })
        return pendingRoomRecovery.filter { !placedIDs.contains($0.drop.id) } + placed
    }

    /// Called only after the new run has delivered a fresh normal camera pose.
    /// The old AR world cannot be recovered here; the approximate re-anchor is
    /// explicit in the metric so a physical check can judge its presentation.
    private func restoreRoomDropsIfReady(frame: ARFrame) {
        guard !pendingRoomRecovery.isEmpty,
              Self.canRestoreRoomDrops(
                frameCapturedAt: frame.timestamp, sessionRunAt: sessionRunSince,
                trackingNormal: frame.camera.trackingState == .normal
              ), let arView else { return }
        let root = ensureWorldRoot(in: arView)
        let restoring = pendingRoomRecovery
        pendingRoomRecovery.removeAll()
        for snapshot in restoring {
            let drop = snapshot.drop
            roomDrops[drop.id] = drop
            placedDrops[drop.id] = drop
            let holder = makeHolder(for: drop)
            holder.transform = Transform(matrix: Self.reanchoredRoomTransform(
                camera: frame.camera.transform,
                relativeHolder: snapshot.cameraRelativeTransform))
            root.addChild(holder)
            placedHolders[drop.id] = holder
            if snapshot.hadGroundLock {
                // The lock stores the holder's world Y (as used by GPS/VPS),
                // not a terrain reference with authored height subtracted.
                groundLockBaseY[drop.id] = holder.position.y
            }
            DropEntityFactory.startAnimations(on: holder)
        }
        renderedDropCount = placedHolders.count
        ARBaselineMetrics.shared.event("roomDropsReanchored", details:
            "count=\(restoring.count) generation=\(workGeneration) method=cameraRelativeApproximation")
        observeSelectedContentReadiness()
    }

    nonisolated static func canRestoreRoomDrops(
        frameCapturedAt: TimeInterval, sessionRunAt: TimeInterval, trackingNormal: Bool
    ) -> Bool {
        trackingNormal && frameCapturedAt.isFinite && frameCapturedAt > sessionRunAt
    }

    nonisolated static func roomCameraRelativeTransform(
        camera: simd_float4x4, holder: simd_float4x4
    ) -> simd_float4x4 {
        simd_inverse(camera) * holder
    }

    nonisolated static func reanchoredRoomTransform(
        camera: simd_float4x4, relativeHolder: simd_float4x4
    ) -> simd_float4x4 {
        camera * relativeHolder
    }

    /// VPS resolved (or refined) a drop's exact pose: glide to it once, then track
    /// silently. From here on the compass tier keeps its hands off this drop.
    private func applyVPSTransform(dropID: UUID, transform: simd_float4x4, isFirst: Bool) {
        // Transit: VPS transforms live in the untrusted VIO frame — ignore them;
        // the transit frame loop owns positions (ADR-015).
        guard renderPath == .pedestrian else { return }
        // Never fight the user's finger mid-slide (live HUD adjust).
        guard !liveEditingDrops.contains(dropID) else { return }
        // Round 2 (counsel STATE-5): ownership requires PRESENCE — a drop with
        // no holder must never be marked VPS-owned (the stale mark exempted a
        // re-entering drop from the compass pipeline forever).
        guard let holder = placedHolders[dropID] else { return }
        vpsOwnedDrops.insert(dropID)
        // Ground lock (ADR-027): the locally measured surface overrides the
        // anchor's terrain altitude — Google's terrain can differ by ±0.5 m,
        // which is exactly the re-float the field test caught.
        var transform = transform
        if let lockY = groundLockBaseY[dropID] {
            transform.columns.3.y = lockY
        }
        if isFirst {
            holder.move(
                to: Transform(matrix: transform),
                relativeTo: nil,
                duration: 1.2,
                timingFunction: .easeInOut
            )
            vpsGlideUntil[dropID] = Date().addingTimeInterval(1.3)
        } else if Date() > (vpsGlideUntil[dropID] ?? .distantPast) {
            // §10 drift proxy: cumulative post-glide VPS corrections, in cm.
            let newPosition = SIMD3<Float>(
                transform.columns.3.x, transform.columns.3.y, transform.columns.3.z
            )
            let correction = simd_length(newPosition - holder.position)
            if correction > 0.002 {
                vpsCorrectionTotals[dropID, default: 0] += correction
                vpsCorrectionCm = Int(((vpsCorrectionTotals.values.max() ?? 0) * 100).rounded())
            }
            // Sub-visible refinements snap. Anything a viewer could see is
            // deferred until the drop is off-screen (ADR-028) unless the error is
            // gross (>5 m) — a genuinely misplaced object gets fixed with a glide.
            if correction <= 0.3 {
                holder.setTransformMatrix(transform, relativeTo: nil)
            } else if correction < 5, let arView, isInView(holder.position, arView: arView) {
                deferredVPSTransforms[dropID] = transform
            } else {
                deferredVPSTransforms[dropID] = nil
                holder.move(
                    to: Transform(matrix: transform),
                    relativeTo: nil,
                    duration: 0.5,
                    timingFunction: .easeInOut
                )
                vpsGlideUntil[dropID] = Date().addingTimeInterval(0.55)
            }
        }
    }

    /// On screen (with margin) and in front of the camera — "the user would see
    /// it move". Content wider than the margin can still poke into view while its
    /// anchor is off-screen; accepted imprecision.
    private func isInView(_ worldPosition: SIMD3<Float>, arView: ARView) -> Bool {
        let camera = arView.cameraTransform
        let toPoint = worldPosition - camera.translation
        let forward = -SIMD3<Float>(
            camera.matrix.columns.2.x, camera.matrix.columns.2.y, camera.matrix.columns.2.z
        )
        guard simd_dot(toPoint, forward) > 0 else { return false }
        guard let point = arView.project(worldPosition) else { return false }
        return arView.bounds.insetBy(dx: -80, dy: -80).contains(point)
    }

    /// Perception uses projected content bounds, not the position-correction
    /// margin. A nearby object entirely outside the viewport cannot lend its
    /// distance to another visible object; partially visible content still counts.
    private func isProjectedContentRelevant(_ content: Entity?, at position: SIMD3<Float>,
                                            arView: ARView) -> Bool {
        guard let content else {
            guard let point = arView.project(position) else { return false }
            return arView.bounds.contains(point) && isInView(position, arView: arView)
        }
        let bounds = content.visualBounds(relativeTo: nil)
        let camera = arView.cameraTransform
        let forward = -SIMD3<Float>(camera.matrix.columns.2.x, camera.matrix.columns.2.y,
                                    camera.matrix.columns.2.z)
        var projected: [CGPoint] = []
        for x in [bounds.min.x, bounds.max.x] {
            for y in [bounds.min.y, bounds.max.y] {
                for z in [bounds.min.z, bounds.max.z] {
                    let corner = SIMD3<Float>(x, y, z)
                    if simd_dot(corner - camera.translation, forward) > 0,
                       let point = arView.project(corner), point.x.isFinite, point.y.isFinite {
                        projected.append(point)
                    }
                }
            }
        }
        guard let first = projected.first else { return false }
        let minX = projected.reduce(first.x) { min($0, $1.x) }
        let maxX = projected.reduce(first.x) { max($0, $1.x) }
        let minY = projected.reduce(first.y) { min($0, $1.y) }
        let maxY = projected.reduce(first.y) { max($0, $1.y) }
        return maxX >= arView.bounds.minX && minX <= arView.bounds.maxX
            && maxY >= arView.bounds.minY && minY <= arView.bounds.maxY
    }

    /// Per render frame: apply queued corrections the moment their drop leaves the
    /// view (or grows past the forced threshold).
    private func drainDeferredCorrections(arView: ARView) {
        for (id, target) in deferredTargets {
            guard !liveEditingDrops.contains(id) else { continue }
            guard let holder = placedHolders[id] else {
                deferredTargets[id] = nil
                continue
            }
            let delta = simd_length(target - holder.position)
            if delta < 0.05 {
                deferredTargets[id] = nil
                continue
            }
            if delta >= Float(AppConfig.forcedCorrectionThreshold)
                || !isInView(holder.position, arView: arView) {
                holder.move(
                    to: Transform(scale: .one, rotation: holder.orientation, translation: target),
                    relativeTo: holder.parent,
                    duration: 0.6,
                    timingFunction: .easeInOut
                )
                deferredTargets[id] = nil
                metricsLog.log("ADR-028: deferred GPS/heading correction applied (\(delta) m)")
            }
        }
        for (id, transform) in deferredVPSTransforms {
            guard !liveEditingDrops.contains(id) else { continue }
            guard let holder = placedHolders[id], vpsOwnedDrops.contains(id) else {
                deferredVPSTransforms[id] = nil
                continue
            }
            let newPosition = SIMD3<Float>(
                transform.columns.3.x, transform.columns.3.y, transform.columns.3.z
            )
            let delta = simd_length(newPosition - holder.position)
            if delta < 0.05 {
                deferredVPSTransforms[id] = nil
                continue
            }
            if delta >= 5 || !isInView(holder.position, arView: arView) {
                holder.move(
                    to: Transform(matrix: transform),
                    relativeTo: nil,
                    duration: 0.5,
                    timingFunction: .easeInOut
                )
                vpsGlideUntil[id] = Date().addingTimeInterval(0.55)
                deferredVPSTransforms[id] = nil
                metricsLog.log("ADR-028: deferred VPS correction applied (\(delta) m)")
            }
        }
    }

    // MARK: - Placement tick

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func tick() {
        // Deferred session-failure recovery (Wave B review C6/C13/C18):
        // consumed here so a pending retry dies naturally with the tick loop
        // when the camera surface goes away (suspend cancels the deadline).
        if cameraVisible, sessionRunning, sessionFailed,
           let deadline = failureRetryDeadline, Date() >= deadline {
            failureRetryDeadline = nil
            lastSessionFailureRecoveryAt = Date()
            metricsLog.log("Deferred session-failure recovery firing")
            runGPSCompass()
        }
        // ARP-4: a warm resume that cannot relocalize (the user moved too far
        // while suspended) would sit in .limited(.relocalizing) forever. After a
        // bounded wait, restart cold — reset tracking AND re-request every GAR
        // anchor in the fresh frame — rather than hang on a frozen world.
        if cameraVisible, sessionRunning, !isInterrupted, !sessionFailed,
           let since = relocalizingSince,
           Date().timeIntervalSince(since) > relocalizeGiveUpSeconds {
            relocalizingSince = nil
            metricsLog.log("Relocalization stalled — falling back to cold restart")
            runGPSCompass()
        }
        // Final check F2: while interrupted or failed, the frozen frame must
        // not feed VPS inference (the app's #1 heat source) and the session
        // must not be reconfigured out from under ARKit's own recovery.
        guard sessionRunning, !isInterrupted, !sessionFailed else { return }
        if !cameraVisible {
            updatePowerTier()
            return
        }
        if let frame = arView?.session.currentFrame,
           Self.canRestoreRoomDrops(
               frameCapturedAt: frame.timestamp, sessionRunAt: sessionRunSince,
               trackingNormal: frame.camera.trackingState == .normal
           ) {
            restoreRoomDropsIfReady(frame: frame)
            lastNormalCameraTransform = frame.camera.transform
        }
        updateNearest()
        applyRenderPathIfNeeded()
        updateWindowMode()
        updatePowerTier()
        switch mode {
        case .geoTracking: tickGeoTracking()
        case .gpsCompass: tickGPSCompass()
        case .starting, .unsupported: break
        }
        updateRenderDiagnostics()
        updateHealthMetrics()

        // All frame-fed producers run in frameUpdate, under the same demand
        // and freshness guard. A frozen currentFrame cannot drive a fallback.
    }

    /// ADR-044: is the nearest FAR drop blocked by real-mesh geometry at
    /// window distance? Far drop deliberately in view + full block at <3.5 m =
    /// almost certainly a pane (a true wall would mean the user can't see the
    /// spot anyway — visibility wins, honestly labeled by the GLASS chip).
    private func updateWindowMode() {
        guard renderPath == .pedestrian, let arView,
              let drop = nearestDrop, let holder = placedHolders[drop.id] else {
            windowEvidence = 0
            setWindowMode(false)
            return
        }
        let camPos = arView.cameraTransform.translation
        let toDrop = holder.position - camPos
        let dropDistance = simd_length(toDrop)
        guard dropDistance > 15, isInView(holder.position, arView: arView) else {
            windowEvidence = 0
            windowCounterEvidence += 1
            if windowCounterEvidence >= 6 { setWindowMode(false) }
            return
        }
        let hit = arView.scene.raycast(
            origin: camPos, direction: simd_normalize(toDrop),
            length: min(dropDistance, 30), query: .nearest,
            mask: .sceneUnderstanding, relativeTo: nil
        ).first
        let blockedNear = hit.map { simd_length($0.position - camPos) < 3.5 } ?? false
        if blockedNear {
            windowEvidence += 1
            windowCounterEvidence = 0
            if windowEvidence >= 3 { setWindowMode(true) } // ~1.2 s of evidence
        } else {
            windowEvidence = 0
            windowCounterEvidence += 1
            if windowCounterEvidence >= 6 { setWindowMode(false) }
        }
    }

    private func setWindowMode(_ active: Bool) {
        guard active != windowModeActive else { return }
        windowModeActive = active
        // Round 2 (counsel ARPCFG-3/STATE-2): this transition sets ONLY its
        // flag — the occlusion option is re-derived from live inputs every
        // tick in updatePowerTier. The old edge-toggled restore read
        // `occlusionActive` (live state since Wave D) and could permanently
        // strand the option removed while meshing kept burning watts.
        metricsLog.log("Window mode \(active ? "ON (mesh-vs-geo conflict)" : "off")")
    }

    /// Snapshot projection and distance together, including the captured edit
    /// target while either slider finger remains down.
    private func updatePowerTier() {
        synchronizeAssetDemand()
        let now = Date()
        if editingDropID != nil || gestureHeld,
           Self.gestureAbandoned(now: now, lastTick: lastLiveEditTickAt, held: gestureHeld) {
            cancelLiveEdit()
        }
        if cameraVisible { lastCameraVisibleAt = now }
        var demand = PerceptionDemand()
        demand.cameraVisible = cameraVisible
        demand.sessionRunning = sessionRunning && !isInterrupted && !sessionFailed
        demand.cameraRecentlyVisible = Self.visibilityTerm(
            cameraVisible: cameraVisible, now: now, lastVisible: lastCameraVisibleAt)
        if cameraVisible, demand.sessionRunning, let arView {
            let camera = arView.cameraTransform.translation
            demand.content = placedHolders.compactMap { id, holder in
                guard holder.isEnabled else { return nil }
                let position = holder.position(relativeTo: nil)
                return .init(distance: simd_length(position - camera),
                             isInView: isProjectedContentRelevant(contentEntities[id], at: position, arView: arView),
                             isEditing: editingDropID == id || liveEditingDrops.contains(id))
            }
        }
        demand.heldGestures = heldGestures
        demand.hasLiveEditing = !liveEditingDrops.isEmpty
        demand.vpsConverging = geospatial.isConverging
        demand.pedestrian = renderPath == .pedestrian
        demand.windowModeActive = windowModeActive
        demand.personLikely = personSentinel.personLikely
        let thermal = ProcessInfo.processInfo.thermalState
        thermalSerious = thermal == .serious || thermal == .critical
        demand.thermalSerious = thermalSerious
        demand.thermalCritical = thermal == .critical
        demand.supportsCustomPersonOcclusion = Self.supportsCustomPersonOcclusion
            && semanticPass != nil && ARBaselineExperiment.current.allows(.postprocess)
        demand.supportsPersonSegmentation = demand.supportsCustomPersonOcclusion
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)
        demand.supportsSceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        demand.supportsSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        demand.hasSemanticPass = semanticPass != nil && ARBaselineExperiment.current.allows(.postprocess)
        demand.supportsSemantics = geospatial.semanticSupported
        demand.geospatialAvailable = geospatial.isAvailable && ARBaselineExperiment.current.allows(.localization)
        demand.allowsPersonSegmentation = ARBaselineExperiment.current.allows(.personSegmentation)
        demand.allowsReconstruction = ARBaselineExperiment.current.allows(.reconstruction)
        demand.allowsSentinel = ARBaselineExperiment.current.allows(.sentinel)
        demand.midFieldEnabled = AppConfig.midFieldDepthEnabled && ARBaselineExperiment.current.allows(.neuralDepth)
        demand.midFieldMinimumDistance = Float(AppConfig.midDepthMinContentDistance)
        demand.midFieldMaximumDistance = Float(AppConfig.midDepthLiDARBandMax * AppConfig.midDepthSupportMargin)
        demand.semanticMatteMinimumDistance = AppConfig.semanticMatteTreeDistance
        perceptionPolicy.update(demand, applyingTo: self)

        if currentPerceptionPlan.localization && geospatial.isConverging {
            if convergenceSprintStart == nil { convergenceSprintStart = now }
        } else {
            convergenceSprintStart = nil
        }
    }

    /// The asset queue follows content the camera can actually present. In
    /// particular, opening the app does not decode the entire bundled catalog.
    private var renderedAssetNames: Set<String> {
        Set(placedDrops.values.compactMap { drop -> String? in
            drop.content == .animated ? drop.assetName : nil
        })
    }

    private func synchronizeAssetDemand() {
        let active = cameraVisible && sessionRunning && !isInterrupted && !sessionFailed
            && ProcessInfo.processInfo.thermalState != .critical
            && !currentPerceptionPlan.recoveringFromCritical
        var names = renderedAssetNames
        var priority: String?
        guard active else {
            // Retain delivered identities for live clones during a short hide:
            // cache eviction then need not schedule a pointless re-decode on return.
            DropEntityFactory.setAssetDemand(names, active: false)
            return
        }
        if let drop = nearestDrop, drop.content == .animated, let name = drop.assetName {
            names.insert(name)
            priority = name
        }
        if let heroID = readiness?.heroID,
           let selected = placedDrops[heroID] ?? eligibleDrops.first(where: { $0.id == heroID }),
           selected.content == .animated, let name = selected.assetName {
            names.insert(name)
            priority = name
        }
        DropEntityFactory.setAssetDemand(names, active: true, priority: priority)
    }

    /// This adapter is also the boundary used by deterministic transition tests.
    /// Consumers never infer a second policy from independently gathered facts.
    func applyPerceptionPlan(_ plan: PerceptionPolicy.Plan) {
        let previous = currentPerceptionPlan
        currentPerceptionPlan = plan
        if powerTier != plan.tier {
            powerTier = plan.tier
            metricsLog.log("Power tier → \(plan.tier.description)")
        }
        perceptionCoordinator.applyPerceptionPlan(plan)
        occlusionActive = sessionRunning && !isInterrupted && !sessionFailed
            && appliedPerception.reconstruction
        semanticMatteArmed = perceptionCoordinator.semanticConsumerEnabled
        if !plan.midField { midDepthActive = false }

        if let arView {
            let wanted = !plan.hardShutdown && Self.occlusionOptionDesired(
                capable: occlusionCapable, pedestrian: renderPath == .pedestrian,
                windowModeActive: windowModeActive)
            if wanted {
                arView.environment.sceneUnderstanding.options.insert(.occlusion)
            } else {
                arView.environment.sceneUnderstanding.options.remove(.occlusion)
            }
        }
        let metrics = ARBaselineMetrics.shared
        metrics.setWorkload("Perception localization admitted", enabled: perceptionCoordinator.localizationAdmitted)
        metrics.setWorkload("Perception sentinel admitted", enabled: plan.sentinel)
        metrics.setWorkload("Perception person admitted", enabled: plan.personAdmitted)
        metrics.setWorkload("Perception depth admitted", enabled: plan.midField)
        metrics.setWorkload("Perception semantics requested", enabled: plan.semantics)
        metrics.setWorkload("Perception semantics admitted", enabled: semanticMatteArmed)
        if previous != plan {
            metrics.event("perceptionPlan", details:
                "generation=\(workGeneration) tier=\(plan.tier) recon=\(plan.reconstruction) person=\(plan.person)/\(plan.personUse) depth=\(plan.depth)/\(plan.midField) semantics=\(plan.semantics)/\(semanticMatteArmed) localization=\(plan.localization) hardStop=\(plan.hardShutdown) recovery=\(plan.recoveringFromCritical)")
        }
    }
    // Granular adapters contain no policy. The coordinator's production
    // ordering, admission invalidation and callback dwell are tested with fakes.
    func configure(reconstruction: Bool, person: Bool, depth: Bool) {
        guard sessionRunning, !isInterrupted, !sessionFailed else { return }
        setPerception(reconstruction: reconstruction, person: person, depth: depth)
    }

    func setLocalizationAdmission(allowed: Bool, generation: UInt64) {
        geospatial.setWorkAdmission(allowed, generation: generation)
    }

    func setSemanticsRequested(_ requested: Bool) -> Bool {
        geospatial.setSemanticsActive(requested)
        return geospatial.semanticActive
    }

    var localizationCanUpdate: Bool { geospatial.canUpdate }

    func setSentinelAdmission(allowed: Bool, generation: UInt64) {
        personSentinel.setWorkAdmission(allowed, generation: generation)
    }

    func setDepthAdmission(allowed: Bool, generation: UInt64) {
        midDepth.setWorkAdmission(allowed, generation: generation)
    }

    func setPassAdmission(allowed: Bool, generation: UInt64, person: Bool, depth: Bool) {
        semanticPass?.setWorkAdmission(allowed, generation: generation, person: person, depth: depth)
    }

    func setSemanticConsumerEnabled(_ enabled: Bool) {
        geospatial.semanticFeed.setEnabled(enabled)
        semanticMatteArmed = enabled
    }

    func setCallbacksActive(_ active: Bool) {
        semanticPass?.setCallbacksActive(active)
    }

    /// The existing LiDAR calibration band, shared with the demand policy.
    nonisolated static func midFieldServiceable(distance: Float) -> Bool {
        PerceptionDemand.midFieldServiceable(
            distance: distance, minimum: Float(AppConfig.midDepthMinContentDistance),
            maximum: Float(AppConfig.midDepthLiDARBandMax * AppConfig.midDepthSupportMargin))
    }

    /// Round 2 (counsel ARPCFG-3/STATE-2): the sceneUnderstanding occlusion
    /// option as a PURE predicate, re-derived every tick — never edge-toggled
    /// from window-mode or render-path transitions, whose interleavings
    /// permanently dropped it (the option is cheap to set; the honesty is in
    /// deriving it from live inputs).
    nonisolated static func occlusionOptionDesired(
        capable: Bool, pedestrian: Bool, windowModeActive: Bool
    ) -> Bool {
        capable && pedestrian && !windowModeActive
    }

    /// When the current VPS convergence attempt began; nil once localized.
    private var convergenceSprintStart: Date?

    /// GARSession feed cadence (ADR-034/036). Convergence gets a TIME-BOXED
    /// sprint: every frame for 20 s, 5 Hz to the minute, then 1 Hz retry —
    /// indoors VPS can never lock, and the old `isConverging ? every-frame`
    /// rule burned 30 Hz of feature extraction forever the moment content
    /// rendered (field: "worked till I placed the object; hot in 2 minutes").
    /// A locked scene needs only maintenance: 15 Hz full, 10 Hz cruise.
    private var garFeedInterval: TimeInterval {
        var interval: TimeInterval
        if AppConfig.vpsEnabled, geospatial.isConverging {
            if geospatial.vpsCoverageAvailable == false {
                // Google's own verdict: no VPS coverage here (indoors/uncovered).
                // Sprinting is pure heat — hold a 1 Hz retry until we move.
                interval = 1.0
            } else {
                let elapsed = convergenceSprintStart.map { Date().timeIntervalSince($0) } ?? 0
                interval = elapsed < 20 ? 0 : (elapsed < 60 ? 0.2 : 1.0)
            }
            if powerTier == .idle {
                interval = max(interval, 0.4)
            }
        } else {
            switch powerTier {
            case .full: interval = 1.0 / 15.0
            case .cruise: interval = 0.1
            case .idle: interval = 0.4
            }
        }
        if thermalSerious {
            interval = max(interval, 0.5)
        }
        return interval
    }

    /// Scene-update callback cadence (a proxy) and ProcessInfo thermal state.
    private func updateHealthMetrics() {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        if ARBaselineMetrics.shared.isEnabled, uptime - lastBaselineExportAt >= 10 {
            lastBaselineExportAt = uptime
            ARBaselineMetrics.shared.event("health", details:
                "thermalState=\(ProcessInfo.processInfo.thermalState.rawValue) tier=\(powerTier.description) content=\(placedHolders.count) brightness=\(UIScreen.main.brightness) batteryState=\(UIDevice.current.batteryState.rawValue)")
            if readinessActive, let start = readiness?.startedAt {
                for milestone in [10, 120, 300, 600, 900]
                where uptime - start >= Double(milestone) && !baselineHealthMilestones.contains(milestone) {
                    baselineHealthMilestones.insert(milestone)
                    ARBaselineMetrics.shared.event("health_\(milestone)s", details:
                        "actualElapsed=\(uptime - start) thermalState=\(ProcessInfo.processInfo.thermalState.rawValue); warmth unmeasured")
                }
            }
            ARBaselineMetrics.shared.export()
        }
        let window = now.timeIntervalSince(fpsWindowStart)
        if window >= 2 {
            renderFPS = Int((Double(frameCounter) / window).rounded())
            frameCounter = 0
            fpsWindowStart = now
        }
        let thermal = ProcessInfo.processInfo.thermalState
        thermalSerious = thermal == .serious || thermal == .critical
        if ARBaselineMetrics.shared.isEnabled, thermalSerious {
            // First occurrence survives bounded recent-event eviction.
            ARBaselineMetrics.shared.event("thermalSeriousOrCritical", details: "state=\(thermal.rawValue)")
        }

        let midActive = midDepth.feed.hasSample
        if midActive != midDepthActive {
            midDepthActive = midActive
        }

        // §10 / FT-31: battery drain is a product metric. One log line per 5 min
        // with the active tier — the field numbers that prove the governor works.
        if now.timeIntervalSince(lastBatteryLogAt) > 300 {
            lastBatteryLogAt = now
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            if level >= 0 {
                metricsLog.log("Battery \(Int(level * 100))% · tier \(self.powerTier.description) · thermal \(thermal.rawValue)")
            }
        }

        if frameIntervalsMs.count >= 30 {
            let sorted = frameIntervalsMs.sorted()
            let index = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
            frameP95Ms = Int(sorted[index].rounded())
        }
    }

    /// "Rendered 34 m ahead · 3 m up" for the nearest placed entity.
    private func updateRenderDiagnostics() {
        guard let arView, !placedHolders.isEmpty else {
            renderDiagnostics = nil
            return
        }
        let camTransform = arView.cameraTransform
        let camPos = camTransform.translation
        guard let nearestEntry = placedHolders.min(by: {
            simd_length($0.value.position - camPos) < simd_length($1.value.position - camPos)
        }) else {
            renderDiagnostics = nil
            return
        }
        let (nearestID, holder) = nearestEntry

        let offset = holder.position - camPos
        let horizontal = simd_length(SIMD2(offset.x, offset.z))

        var direction = "nearby"
        let forward = -simd_normalize(SIMD3<Float>(
            camTransform.matrix.columns.2.x,
            0,
            camTransform.matrix.columns.2.z
        ))
        if forward.x.isFinite, horizontal > 2 {
            let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
            let aheadAmount = simd_dot(offset, forward)
            let rightAmount = simd_dot(offset, right)
            if aheadAmount > abs(rightAmount) {
                direction = "ahead"
            } else if aheadAmount < -abs(rightAmount) {
                direction = "behind you"
            } else {
                direction = rightAmount > 0 ? "to your right" : "to your left"
            }
        }

        let vertical = offset.y
        let verticalText = abs(vertical) < 1.5
            ? "eye level"
            : String(format: "%.0f m %@", abs(vertical), vertical > 0 ? "up" : "down")

        // Report the physical content's current angular size. The separate
        // waypoint marker does not enter these bounds.
        var sizeText = ""
        if let content = contentEntities[nearestID] {
            let distance = simd_length(offset)
            let height = content.visualBounds(relativeTo: holder).extents.y
            if distance > 0.5, height > 0.01 {
                let degrees = 2 * atan(Double(height) / (2 * Double(distance))) * 180 / .pi
                sizeText = String(format: " · %.1f°", degrees)
            }
        }
        renderDiagnostics = String(
            format: "Rendered %.0f m %@ · %@%@", horizontal, direction, verticalText, sizeText
        )
    }

    /// Switches the world-lock model when the motion classifier changes its verdict.
    /// Transitions are cheap and reversible: content entities are reused; only the
    /// positioning authority and the occluder set change.
    private func applyRenderPathIfNeeded() {
        guard let arView, motionState != .unknown else { return }
        let desired: RenderPath = motionState == .vehicular ? .transit : .pedestrian
        guard desired != renderPath else { return }
        renderPath = desired
        switch desired {
        case .transit:
            // §6.3: LiDAR/scene-mesh occlusion is unreliable through vehicle glass
            // (it would mesh the window itself), and streetscape occluders live in
            // the now-untrusted VIO frame. Semantic matte + person-seg carry it.
            // Round 2 (counsel ARPCFG-3): the occlusion OPTION is tick-derived
            // in updatePowerTier — transitions set only their own flags.
            geospatial.setOccludersHidden(true)
            vpsOwnedDrops.removeAll()
            vpsGlideUntil.removeAll()
            metricsLog.log("Render path → transit")
        case .pedestrian:
            for (id, holder) in placedHolders where roomDrops[id] == nil { holder.isEnabled = true }
            geospatial.setOccludersHidden(false)
            // Force a clean world-locked re-sync; VPS re-glides as anchors update.
            placementBasis = nil
            lastRefinementSync = .distantPast
            metricsLog.log("Render path → pedestrian")
        }
    }

    private var eligibleDrops: [GeoDrop] {
        guard let location = locationService?.location else { return demoDrops }
        let nearby = library?.drops(near: location, within: AppConfig.arVisibilityRadius) ?? []
        return nearby + demoDrops
    }

    /// Wave D (counsel SWE-5/SWE-12): EVERY site that destroys a drop's
    /// presence goes through here. Per-drop state lives in many parallel maps
    /// and the three old ad-hoc cleanup loops each forgot a different subset —
    /// the leaked `liveEditingDrops` entry alone pinned the power governor to
    /// `.full` for the rest of the session (thermal `.serious` inside 10 min).
    private func removePerDropState(_ id: UUID) {
        placedHolders[id]?.removeFromParent()
        placedHolders[id] = nil
        placedDrops[id] = nil
        markers[id] = nil
        contentEntities[id] = nil
        readyContentIDs.remove(id)
        groundDiscs[id] = nil
        groundLockBaseY[id] = nil
        deferredTargets[id] = nil
        deferredVPSTransforms[id] = nil
        liveEditingDrops.remove(id)
        if editingDropID == id {
            editingDropID = nil
            // Round 4 (counsel F-D3-03/R3-3): the gesture context died with
            // its target — a live finger over a deleted drop must not re-bind.
            heldGestures = 0
        }
        vpsOwnedDrops.remove(id)
        vpsGlideUntil[id] = nil
        vpsCorrectionTotals[id] = nil
        revealedDrops.remove(id)
        // Round 2 (counsel STATE-4): the stale-nearest window closes at
        // removal time, not at the next (possibly frozen) tick.
        if nearestDrop?.id == id {
            nearestDrop = nil
            nearestDropDistance = nil
        }
        // Round 2 (counsel STATE-5): engine-side per-drop state dies WITH the
        // drop — GARAnchors otherwise accumulate for the session and a stale
        // anchor silently re-owns a re-entering drop.
        geospatial.invalidateAnchor(for: id)
    }

    private func updateNearest() {
        // Wave D (counsel SWE-5): nearest is FROZEN while a drag is live — a
        // mid-drag nearest change used to jump the sliders (`syncSliders`) and
        // land the release-commit on a drop the user wasn't editing.
        guard editingDropID == nil else { return }
        // Room drops win by AR-space distance — geo distance is meaningless for
        // them, and indoors they are what the user is testing (ADR-025).
        if !roomDrops.isEmpty, let arView {
            let camPos = arView.cameraTransform.translation
            let nearest = roomDrops.keys
                .compactMap { id in
                    placedHolders[id].map { (id, simd_length($0.position - camPos)) }
                }
                .min { $0.1 < $1.1 }
            if let (id, distance) = nearest {
                nearestDrop = placedDrops[id] ?? roomDrops[id]
                nearestDropDistance = Double(distance)
                return
            }
        }
        guard let location = locationService?.location else {
            nearestDrop = nil
            nearestDropDistance = nil
            return
        }
        let all = (library?.drops ?? []) + demoDrops
        nearestDrop = all.min {
            $0.location.distance(from: location) < $1.location.distance(from: location)
        }
        nearestDropDistance = nearestDrop.map { $0.location.distance(from: location) }
    }

    // MARK: - Tier A: GPS + compass

    private func tickGPSCompass() {
        guard let arView, let locationService else { return }
        // Wave B review (C18/C19): a dead session keeps its failure message and
        // does no placement work; an interrupted one holds everything — the
        // frozen currentFrame would otherwise blend live GPS fixes and compass
        // readings into heading/placement as if the camera were still moving.
        guard !sessionFailed, !isInterrupted else { return }

        // Failure audit (v0.8): permission problems must say so, not spin forever.
        if locationService.authorization == .denied || locationService.authorization == .restricted {
            statusText = "Location access is denied — enable it in Settings to see drops"
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
            statusText = "Camera access is denied — enable it in Settings"
            return
        }

        let now = Date()
        let currentFix = locationService.currentLocation(at: now)
        motionState = motion.update(location: currentFix, at: now)
        guard let fix = currentFix else {
            statusText = renderPath == .transit
                ? "Transit — GPS stale · positions hidden"
                : "Waiting for a current GPS fix…"
            return
        }
        guard let frame = arView.session.currentFrame else {
            statusText = "Starting camera…"
            return
        }

        // Transit trusts the compass more (VIO yaw may be corrupted by the moving
        // scene) — faster correction; pedestrian keeps the slow, stable estimate.
        updateHeadingCorrection(frame: frame, alpha: renderPath == .transit ? 0.2 : 0.08)

        if renderPath == .transit {
            tickTransit(drops: eligibleDrops)
            return
        }

        // In .gravity alignment (VPS mode) the session frame's rotation relative to
        // north is arbitrary — one seeded compass sample is enough to spawn
        // (ADR-003: never trade time-to-first-object for accuracy; refine instead).
        if AppConfig.vpsEnabled, placementBasis == nil, headingSampleCount < 1 {
            statusText = "Reading compass…"
            return
        }

        let drops = eligibleDrops
        let dropIDs = Set(drops.map(\.id))

        // ADR-037: ask Google whether VPS coverage even exists here (re-checked
        // per ~300 m of movement) — no coverage ⇒ no convergence sprinting.
        geospatial.checkCoverage(at: fix.coordinate)

        // Hand precise placement to VPS as soon as it is localized well.
        vpsStatusText = geospatial.statusText
        vpsLocked = geospatial.isAccuratelyLocalized
        if geospatial.isAccuratelyLocalized {
            for drop in drops {
                geospatial.requestAnchor(for: drop, viewer: fix)
            }
        }

        let trackingNormal = frame.camera.trackingState == .normal
        if placementBasis == nil || dropIDs != Set(placedHolders.keys) {
            // Place instantly with whatever fix quality we have. Wave B review
            // (C5/C11/C17): while tracking is limited the basis stays unlatched
            // — re-syncing every 400 ms tick would hard-snap placed content for
            // the whole initializing/relocalizing window. Sync only when there
            // is real work: the first spawn, a drop-set change, or a normal
            // pose ready to latch the basis.
            if trackingNormal || placedHolders.isEmpty
                || dropIDs != Set(placedHolders.keys) {
                syncGPSPlacements(
                    drops: drops, fix: fix, frame: frame,
                    animated: !placedHolders.isEmpty
                )
            }
        } else if let basis = placementBasis, trackingNormal {
            // (Drift measured against a limited-tracking pose is garbage —
            // Wave B review C3: skip the comparison; the basis survives.)
            // How far off is our anchoring? Compare the displacement GPS reports
            // against the displacement AR tracking measured since we anchored —
            // walking moves both equally, so the difference is pure anchoring error.
            let cam = frame.camera.transform.columns.3
            let arEast = Double(cam.x - basisCameraPosition.x)
            let arNorth = Double(-(cam.z - basisCameraPosition.z))
            guard let gpsDelta = GeoMath.checkedENUOffset(from: basis.coordinate, to: fix.coordinate),
                  let correction = GeoMath.driftMeters(
                    gpsENU: gpsDelta, arHorizontal: SIMD2(arEast, arNorth),
                    basisHeadingCorrection: appliedHeadingCorrection
                  ) else {
                placementBasis = nil
                syncGPSPlacements(drops: drops, fix: fix, frame: frame, animated: false)
                statusText = "Location changed — placing nearby drops again"
                return
            }

            let headingDriftRad = abs(atan2(
                sin(headingCorrection - appliedHeadingCorrection),
                cos(headingCorrection - appliedHeadingCorrection)
            ))

            // While the heading estimate is still converging (first ~15 s) small
            // corrections are allowed; after that, only clearly-wrong placements move.
            // VPS-driven heading is degree-accurate, so small disagreements are real
            // and worth a short glide; compass-driven stays hysteretic (its noise
            // band is wider than its signal).
            let headingConverged = headingSampleCount > 40
            let headingLimitRad = headingSourceIsVPS
                ? 3.0 * .pi / 180
                : (headingConverged ? 15.0 : 5.0) * .pi / 180
            let refractoryOver = Date().timeIntervalSince(lastRefinementSync) > 8

            let accuracyImproved = fix.horizontalAccuracy < basis.horizontalAccuracy - 3
            if refractoryOver,
               (accuracyImproved && correction > AppConfig.refinementCorrectionThreshold)
                || correction > AppConfig.forcedCorrectionThreshold
                || headingDriftRad > headingLimitRad {
                syncGPSPlacements(drops: drops, fix: fix, frame: frame, animated: true)
            }
        }

        if placedHolders.isEmpty {
            statusText = "No drops in range — pin one on the Map tab, or try the demo"
        } else if fix.horizontalAccuracy > 20 {
            statusText = String(
                format: "Placed · GPS ±%.0f m — refining as the signal improves",
                fix.horizontalAccuracy
            )
        } else {
            statusText = String(format: headingSeededMagneticOnly
                ? "Provisional magnetic heading · GPS ±%.0f m"
                : "Compass mode · GPS ±%.0f m", fix.horizontalAccuracy)
        }
    }

    /// Creates/moves one holder entity per drop at its world position. Existing
    /// holders slide smoothly to corrected positions instead of popping.
    private func syncGPSPlacements(drops: [GeoDrop], fix: CLLocation, frame: ARFrame, animated: Bool) {
        guard let arView else { return }
        let root = ensureWorldRoot(in: arView)

        // The GPS fix describes where the camera is *right now*.
        let cam = frame.camera.transform.columns.3
        let groundY = estimatedGroundY(frame: frame) ?? (cam.y - 1.5)

        var seen: Set<UUID> = []
        var placedUsingValidOffset = false
        for drop in drops {
            guard let enu = GeoMath.checkedENUOffset(from: fix.coordinate, to: drop.coordinate) else { continue }
            seen.insert(drop.id)
            if !liveEditingDrops.contains(drop.id) {
                placedDrops[drop.id] = drop
                synchronizePhysicalSize(for: drop.id, authoredScale: drop.scale)
            }

            // Drops owned by VPS are world-accurate already — never touch them here.
            // Ditto anything mid-live-edit: the sliders own it until release.
            if placedHolders[drop.id] != nil,
               vpsOwnedDrops.contains(drop.id) || liveEditingDrops.contains(drop.id) {
                continue
            }

            // Rotate the true east/north offset into the AR frame, compensating for
            // the session's measured compass error.
            guard let horizontal = GeoMath.arHorizontal(fromENU: enu, headingCorrection: headingCorrection) else { continue }
            let east = horizontal.x
            let north = horizontal.y
            placedUsingValidOffset = true
            // Whatever the ground estimate did, content must stay in the band the
            // viewer can actually see: never below their feet, never in the clouds.
            // A ground lock (ADR-027) wins outright — it's a real measurement.
            // Rooftop drops (ADR-042) get a nominal building height until the
            // rooftop anchor resolves and glides them onto the real roof.
            let rooftopNominal: Float = drop.isRooftop ? 8 : 0
            let y = groundLockBaseY[drop.id]
                ?? min(max(groundY + rooftopNominal + Float(drop.heightAboveGround), cam.y - 5), cam.y + 40)
            let target = SIMD3<Float>(
                cam.x + Float(east),
                y,
                cam.z - Float(north) // −Z is north
            )

            if let holder = placedHolders[drop.id] {
                let delta = simd_length(target - holder.position)
                if animated, delta > 0.3,
                   delta < Float(AppConfig.forcedCorrectionThreshold),
                   isInView(holder.position, arView: arView) {
                    // ADR-028: never slide content the user is looking at for a
                    // sub-forced correction — queue it for when they pan away.
                    deferredTargets[drop.id] = target
                } else if animated {
                    deferredTargets[drop.id] = nil
                    holder.move(
                        to: Transform(scale: .one, rotation: holder.orientation, translation: target),
                        relativeTo: root,
                        duration: 0.6,
                        timingFunction: .easeInOut
                    )
                } else {
                    deferredTargets[drop.id] = nil
                    holder.position = target
                }
            } else {
                let holder = makeHolder(for: drop)
                holder.position = target
                // Oriented once — then fixed forever, like a signboard. Never
                // billboarded, never rescaled: real perspective and parallax are
                // what make it feel physically present. Creator-chosen compass
                // facing wins; otherwise face where the viewer first sees it from.
                if let facing = drop.facingDegrees {
                    let bearingAR = facing * .pi / 180 - headingCorrection
                    holder.orientation = simd_quatf(
                        angle: Float(.pi - bearingAR), axis: [0, 1, 0]
                    )
                } else {
                    holder.orientation = simd_quatf(
                        angle: atan2(cam.x - target.x, cam.z - target.z), axis: [0, 1, 0]
                    )
                }
                root.addChild(holder)
                placedHolders[drop.id] = holder
                // After scene insertion — playback controllers created earlier
                // than that don't reliably survive (ADR-021).
                DropEntityFactory.startAnimations(on: holder)
            }
        }

        for (id, _) in placedHolders where !seen.contains(id) && roomDrops[id] == nil {
            removePerDropState(id)
        }

        // Counsel ARP-5 + Wave B review (C3/C11): a basis captured while
        // tracking is initializing measures a garbage camera pose, and the
        // GPS-vs-AR drift comparison it seeds then fights every later
        // correction. Content spawns regardless (killer #1 — it is on screen),
        // but the basis LATCHES only from a `.normal` pose. A basis that
        // already exists was latched from a trustworthy pose and must survive
        // a transient limited window untouched — relocalization preserves the
        // world frame, so it is still valid when tracking recovers.
        if placedUsingValidOffset, frame.camera.trackingState == .normal {
            placementBasis = fix
            basisCameraPosition = SIMD3(cam.x, cam.y, cam.z)
            appliedHeadingCorrection = headingCorrection
            lastRefinementSync = Date()
        }
        renderedDropCount = placedHolders.count

        observeSelectedContentReadiness()
    }

    /// Content shared by both render paths: content + grounding disc + way-point
    /// orb. (The v0.3 ground pillar is gone — ADR-027, field verdict "looks weird
    /// with the object"; the orb + disc + guidance arrow carry findability.)
    private func makeHolder(for drop: GeoDrop) -> Entity {
        // Round 4 (counsel arui-1): a model that failed to decode BEFORE this
        // manager existed (launch preload) still gets announced — render-time
        // state, not a decode-time event nobody heard. Round 6 (arui-6): once
        // per asset per session, non-critical (never evicts a save failure).
        if drop.content == .animated, let assetName = drop.assetName,
           DropEntityFactory.isAssetFailed(assetName),
           announcedFailedAssets.insert(assetName).inserted {
            showPersistError(
                "The 3D model for “\(drop.title)” couldn't be loaded", critical: false
            )
        }
        let holder = Entity()
        let content = DropEntityFactory.makeEntity(for: drop, fullBright: contentFullBright)
        holder.addChild(content)
        contentEntities[drop.id] = content
        recordContentReadiness(for: drop)

        // ADR-023 grounding disc (see `groundDiscs`): translucent dark ellipse
        // sitting just above the estimated ground, footprint-sized to the content.
        var shadowMaterial = UnlitMaterial()
        shadowMaterial.color = .init(tint: .black)
        shadowMaterial.blending = .transparent(opacity: 0.35)
        let disc = ModelEntity(mesh: .generateSphere(radius: 1), materials: [shadowMaterial])
        let radius = Self.groundDiscRadius(for: content, relativeTo: holder)
        disc.scale = [radius, 0.01, radius]
        disc.position = [0, -Float(drop.heightAboveGround) + 0.04, 0]
        holder.addChild(disc)
        groundDiscs[drop.id] = disc

        // Way-point orb above the content: the only thing allowed to break
        // true scale, so the *location* stays findable from afar. Hidden
        // once you're close and the content speaks for itself.
        let marker = ModelEntity(
            mesh: .generateSphere(radius: 0.4),
            materials: [UnlitMaterial(color: drop.uiColor)]
        )
        let contentTop = content.visualBounds(relativeTo: holder).max.y
        marker.position = [0, max(contentTop, 0) + 2, 0]
        holder.addChild(marker)
        markers[drop.id] = marker

        // ADR-046 "alive" layer: sparkle aura (iOS 18+) + idle motion for
        // content without its own rigged animations.
        if #available(iOS 18.0, *), drop.content != .fireworks, drop.content != .beacon {
            let bounds = content.visualBounds(relativeTo: holder)
            let aura = DropEffects.sparkleAura(
                color: drop.uiColor,
                radius: max(bounds.extents.x, bounds.extents.y) * 0.6
            )
            aura.position = [0, bounds.center.y, 0]
            holder.addChild(aura)
        }
        let hasOwnAnimations = !content.availableAnimations.isEmpty
            || content.children.contains { !$0.availableAnimations.isEmpty }
        DropEffects.applyIdleMotion(
            DropEffects.idleMotion(for: drop, contentHasAnimations: hasOwnAnimations),
            to: content
        )
        return holder
    }

    /// Apply an authored scale to already rendered content. Called for live edits,
    /// remote edits, and newly decoded assets; distance never enters this path.
    /// The marker is repositioned but its independent readability scale is kept.
    static func applyPhysicalSize(
        _ authoredScale: Float, to content: Entity, in holder: Entity,
        marker: Entity?, disc: Entity?, force: Bool = false
    ) {
        let target = SIMD3<Float>(repeating: authoredScale)
        guard force || content.scale != target else { return }
        content.scale = target
        let top = content.visualBounds(relativeTo: holder).max.y
        marker?.position.y = max(top, 0) + 2
        if let disc {
            let radius = groundDiscRadius(for: content, relativeTo: holder)
            disc.scale = [radius, 0.01, radius]
        }
    }

    private func synchronizePhysicalSize(
        for id: UUID, authoredScale: Double, force: Bool = false
    ) {
        guard let holder = placedHolders[id], let content = contentEntities[id] else { return }
        Self.applyPhysicalSize(Float(authoredScale), to: content, in: holder,
                               marker: markers[id], disc: groundDiscs[id], force: force)
    }

    /// Slightly wider than the content's ground footprint, never smaller than 0.5 m.
    private static func groundDiscRadius(for content: Entity, relativeTo holder: Entity) -> Float {
        let bounds = content.visualBounds(relativeTo: holder)
        return max(max(bounds.extents.x, bounds.extents.z) * 0.55, 0.5)
    }

    /// Live HUD sliders: adjust the nearest drop's height/size while looking at it.
    /// Drag ticks come in with `commit: false` (visual + in-memory only); the
    /// slider-release commit persists to the library and re-pins the VPS terrain
    /// anchor (whose altitude-above-terrain is baked at creation).
    func adjustNearestDrop(
        height: Double? = nil, scale: Double? = nil, rotation: Double? = nil, commit: Bool
    ) {
        // Wave D (counsel SWE-5) / round 3 (STATE-L1) / round 4 (F-D3-01):
        // binding is the PURE `editTarget` decision — a gesture tick binds to
        // its capture (or, finger provably down, to nearest); a tick with
        // neither is refused. AUTHORED edits (ground snap) never come through
        // here — they call `applyEdit` with their explicit target, which the
        // round-3 gate wrongly refused (the flagship "Place on ground" was a
        // silent no-op with an orphaned ground lock).
        guard let id = Self.editTarget(
            capture: editingDropID, held: gestureHeld, nearest: nearestDrop?.id
        ) else { return }
        editingDropID = id
        if !commit {
            lastLiveEditTickAt = Date()
            // Round 6 (counsel F-D5-03): the never-fight-the-finger guard is
            // GESTURE state and lives here, not in the mutation — an authored
            // commit ("Place on ground" mid-drag) must not strip the VPS
            // guard and the governor pin from under a still-held finger.
            liveEditingDrops.insert(id)
        }
        if commit {
            // Round 5 (counsel F-D4-01): commit bookkeeping is PURE and lives
            // in the BINDING half — the shared capture survives until the
            // LAST finger lifts. It stays hoisted above the resolve (round 4,
            // F-D3-03: a failed resolve must not strand the count).
            (heldGestures, editingDropID) = Self.commitBookkeeping(
                heldGestures: heldGestures, capture: editingDropID, committed: id
            )
            // Round 6 (counsel F-D5-03): the finger guard releases with the
            // LAST finger, same rule as the capture.
            if heldGestures == 0 { liveEditingDrops.remove(id) }
        }
        applyEdit(to: id, height: height, scale: scale, rotation: rotation, commit: commit)
    }

    /// Round 4 (counsel F-D3-01): the MUTATION, split from gesture binding —
    /// programmatic (authored) callers commit to an explicit target with no
    /// gesture state read or written. Round 5 (counsel F-D4-01) made that
    /// true for the capture; round 6 (counsel F-D5-03) finished it for the
    /// finger guard — `liveEditingDrops` maintenance moved to the binding
    /// half too (insert on tick, release with the LAST finger), so an
    /// authored snap mid-drag can no longer strip the VPS
    /// never-fight-the-finger guard from under a held thumb. This function
    /// now touches NO gesture or finger state of any kind; a vanished
    /// captured drop is handled at the removal site (`removePerDropState`).
    private func applyEdit(
        to id: UUID, height: Double? = nil, scale: Double? = nil,
        rotation: Double? = nil, commit: Bool
    ) {
        // Round 2 (counsel STATE-4): resolve STRICTLY from owned state — the
        // old `nearestDrop` fallback was invariantly non-nil while a capture
        // existed (updateNearest is frozen), which made the vanish-guard dead
        // code and resurrected deleted drops into the library and the cloud.
        // (A vanished CAPTURED drop is handled by `removePerDropState`, which
        // clears the capture and zeroes the counter at the removal site.)
        guard let resolved = placedDrops[id] ?? roomDrops[id]
            ?? demoDrops.first(where: { $0.id == id }) else { return }
        var drop = resolved
        let oldHeight = drop.heightAboveGround
        if let height { drop.heightAboveGround = height }
        if let scale { drop.scale = scale }
        if let rotation { drop.facingDegrees = rotation }
        placedDrops[id] = drop
        // An authored edit of a non-nearest target must not clobber nearest.
        if nearestDrop == nil || nearestDrop?.id == id { nearestDrop = drop }

        if let holder = placedHolders[id] {
            if let height {
                holder.position.y += Float(height - oldHeight)
                // Keep the grounding disc on the ground under the moved content.
                groundDiscs[id]?.position.y = -Float(drop.heightAboveGround) + 0.04
            }
            if let rotation {
                // Same convention as placement: facing bearing β ⇒ AR yaw π − (β − corr).
                let bearingAR = rotation * .pi / 180 - headingCorrection
                holder.orientation = simd_quatf(angle: Float(.pi - bearingAR), axis: [0, 1, 0])
            }
            if let scale {
                synchronizePhysicalSize(for: id, authoredScale: scale)
            }
        }

        if roomDrops[id] != nil {
            roomDrops[id] = drop // session-scoped; never persisted
        } else if let index = demoDrops.firstIndex(where: { $0.id == id }) {
            demoDrops[index] = drop
        } else if let library {
            let edited = drop
            let persist = commit
            // Wave C round 2 (C20): the user is looking at the camera when a
            // slider commit fails — the failure must show HERE, not only on a
            // tab they aren't on. (library.lastPersistError is also set.)
            Task { [weak self] in
                do {
                    try await library.update(edited, persist: persist)
                } catch {
                    self?.showPersistError("Couldn't save the change — it may revert")
                }
            }
        }

        if commit {
            if height != nil {
                // A deliberate height choice overrides any previous ground lock.
                groundLockBaseY[id] = nil
            }
            if height != nil || rotation != nil, vpsOwnedDrops.contains(id) {
                // Terrain anchors bake altitude AND rotation at creation — re-pin;
                // the fresh anchor glides the drop to its exact terrain-true pose.
                vpsOwnedDrops.remove(id)
                geospatial.invalidateAnchor(for: id)
            }
        }
    }

    /// The nearest drop's current facing bearing for seeding the rotation slider —
    /// stored value if the creator chose one, else derived from the holder's yaw.
    func nearestDropFacingDegrees() -> Double {
        guard let drop = nearestDrop else { return 0 }
        if let facing = (placedDrops[drop.id] ?? drop).facingDegrees { return facing }
        guard let holder = placedHolders[drop.id] else { return 0 }
        let front = holder.orientation.act(SIMD3<Float>(0, 0, 1))
        let yaw = atan2(Double(front.x), Double(front.z))
        let facing = (.pi - yaw + headingCorrection) * 180 / .pi
        return (facing.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
    }

    /// "Literally on the ground" (ADR-027): measure the real surface under the drop
    /// through a truth chain — ARKit plane raycast → LiDAR mesh raycast → sane-band
    /// plane estimate → standing height — then GROUND-LOCK the result so GPS
    /// re-syncs and VPS terrain anchors can't re-float it (field report 2026-07-07:
    /// snap landed, then the geo pipeline lifted it again).
    func snapNearestDropToGround() {
        guard let arView, let drop = nearestDrop,
              let holder = placedHolders[drop.id] else { return }
        let base = holder.position
        var groundY: Float?

        let query = ARRaycastQuery(
            origin: SIMD3(base.x, base.y + 3, base.z),
            direction: SIMD3(0, -1, 0),
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        if let hit = arView.session.raycast(query).first {
            groundY = hit.worldTransform.columns.3.y
        }
        // Round 2 (counsel ARPCFG-6): the mesh rung states its dependency —
        // with reconstruction shed (transit/thermal/camera-grace) the mesh is
        // gone and this raycast can only miss; skipping it makes the
        // degradation explicit instead of discovered as an empty result.
        if groundY == nil, appliedPerception.reconstruction {
            // LiDAR reconstruction mesh (collision shapes enabled at session setup).
            groundY = arView.scene.raycast(
                origin: SIMD3(base.x, base.y + 3, base.z),
                direction: SIMD3(0, -1, 0),
                length: 30,
                query: .nearest,
                mask: .sceneUnderstanding,
                relativeTo: nil
            ).first?.position.y
        }
        if groundY == nil, let frame = arView.session.currentFrame {
            groundY = estimatedGroundY(frame: frame)
        }
        // Round 2 (counsel ARPCFG-6): a GUESS is not a measurement. The old
        // chain fell through to camera.y − 1.65 and then ground-LOCKED and
        // PERSISTED it — overriding VPS terrain truth for the session with an
        // assumed eye height. Without a real surface, the snap declines
        // honestly instead of committing fiction.
        guard let groundY else {
            // Round 3 (counsel UX-3): a declined snap is ADVICE, not a data
            // emergency — the critical slot is reserved for persistence
            // failures and must never be evicted by a convenience feature.
            showPersistError(
                "Couldn't find the ground here — move closer and try again",
                critical: false
            )
            return
        }

        let currentHeight = (placedDrops[drop.id] ?? drop).heightAboveGround
        // Round 4 (counsel F-D3-01): an AUTHORED edit — binds to the drop this
        // function already resolved, with no gesture state involved. Routing
        // through the gesture entry point made this a silent no-op while the
        // ground-lock write below still landed (tap-does-nothing, then
        // moves-by-itself, then reverts on relaunch).
        applyEdit(to: drop.id, height: min(max(currentHeight + Double(groundY + 0.005 - base.y), -2), 20), commit: true)
        // Set AFTER the commit (which clears locks as a manual-override signal).
        groundLockBaseY[drop.id] = groundY + 0.005
    }

    /// ADR-032: a background-decoded model just landed — replace the placeholder
    /// orb of every drop waiting on it, keeping pose/world-lock untouched.
    private func assetTemplateDidLoad(_ name: String) {
        for (id, drop) in placedDrops
        where drop.content == .animated && drop.assetName == name {
            guard !readyContentIDs.contains(id), let holder = placedHolders[id] else { continue }
            contentEntities[id]?.removeFromParent()
            let fresh = DropEntityFactory.makeEntity(for: drop, fullBright: contentFullBright)
            holder.addChild(fresh)
            contentEntities[id] = fresh
            recordContentReadiness(for: drop)
            synchronizePhysicalSize(for: id, authoredScale: drop.scale, force: true)
            DropEntityFactory.startAnimations(on: fresh)
        }
    }

    /// ADR-041 "pin to this exact spot": the user tapped a real-world point in
    /// the camera — make that the drop's true home. The coordinate comes from
    /// VPS when localized (~1–5 m absolute, the precision ceiling for other
    /// viewers) else inverse-ENU from the current GPS fix. The tapped point is
    /// ground-locked so the visual placement is exact for THIS session either way.
    func relocateNearestDrop(to worldPoint: SIMD3<Float>) {
        guard let drop = nearestDrop, let holder = placedHolders[drop.id],
              let arView else { return }
        let id = drop.id
        var updated = placedDrops[id] ?? drop

        // 1. New coordinate — VPS first, GPS+heading fallback.
        guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else { return }
        if let geo = geospatial.geoCoordinate(of: worldPoint), GeoMath.isValid(geo.coordinate) {
            updated.latitude = geo.coordinate.latitude
            updated.longitude = geo.coordinate.longitude
            metricsLog.log("Relocate via VPS ±\(geo.horizontalAccuracy) m")
        } else if let fix = locationService?.currentLocation() {
            guard headingSampleCount > 0, !headingSeededMagneticOnly else {
                showPersistError("Waiting for true north before saving this location")
                return
            }
            let camPos = arView.cameraTransform.translation
            let offset = worldPoint - camPos
            let eastAR = Double(offset.x)
            let northAR = Double(-offset.z)
            guard let enu = GeoMath.enu(fromARHorizontal: SIMD2(eastAR, northAR), headingCorrection: headingCorrection),
                  let coordinate = GeoMath.checkedCoordinate(
                from: fix.coordinate,
                bearingDegrees: atan2(enu.x, enu.y) * 180 / .pi,
                distanceMeters: simd_length(enu)
            ) else {
                showPersistError("Couldn’t locate this spot — wait for a reliable GPS fix")
                return
            }
            updated.latitude = coordinate.latitude
            updated.longitude = coordinate.longitude
            metricsLog.log("Relocate via GPS fallback (±\(fix.horizontalAccuracy) m)")
        } else {
            showPersistError("Couldn’t locate this spot — wait for a current GPS fix")
            return
        }

        // 2. Height above ground at the tapped point (snap small values to 0).
        var groundY: Float?
        if let frame = arView.session.currentFrame {
            groundY = estimatedGroundY(frame: frame)
        }
        let reference = groundY ?? (arView.cameraTransform.translation.y - 1.65)
        var height = Double(worldPoint.y - reference)
        if abs(height) < 0.3 { height = 0 }
        updated.heightAboveGround = min(max(height, -2), 20)

        // 3. Apply everywhere: model, scene (exact tap point), cloud, VPS.
        placedDrops[id] = updated
        nearestDrop = updated
        holder.move(
            to: Transform(
                scale: .one, rotation: holder.orientation,
                translation: SIMD3(worldPoint.x, worldPoint.y + 0.005, worldPoint.z)
            ),
            relativeTo: holder.parent, duration: 0.3, timingFunction: .easeInOut
        )
        groundLockBaseY[id] = worldPoint.y + 0.005
        groundDiscs[id]?.position.y = -Float(updated.heightAboveGround) + 0.04
        deferredTargets[id] = nil
        deferredVPSTransforms[id] = nil
        if vpsOwnedDrops.contains(id) {
            vpsOwnedDrops.remove(id)
            geospatial.invalidateAnchor(for: id) // re-pins at the NEW coordinate
        }
        if let index = demoDrops.firstIndex(where: { $0.id == id }) {
            demoDrops[index] = updated
        } else if roomDrops[id] != nil {
            roomDrops[id] = updated
        } else if let library {
            let toSave = updated
            Task { [weak self] in
                do {
                    try await library.update(toSave, persist: true)
                } catch {
                    self?.showPersistError("Couldn't save the change — it may revert")
                }
            }
        }
    }

    /// ADR-020: swap each placed drop's content for a re-skinned copy in place.
    /// Only the model changes — holder pose, disc, and marker are untouched, so
    /// world-lock and VPS ownership are unaffected.
    private func rebuildContentEntities() {
        for (id, holder) in placedHolders {
            guard let drop = placedDrops[id] else { continue }
            contentEntities[id]?.removeFromParent()
            let fresh = DropEntityFactory.makeEntity(for: drop, fullBright: contentFullBright)
            holder.addChild(fresh)
            contentEntities[id] = fresh
            recordContentReadiness(for: drop)
            synchronizePhysicalSize(for: id, authoredScale: drop.scale, force: true)
            DropEntityFactory.startAnimations(on: fresh)
        }
    }

    /// Pin the intended hero before consulting asset readiness. A ready neighbor
    /// must never replace a missing/heavy selected asset in the measurement.
    private func observeSelectedContentReadiness() {
        guard readinessActive, let arView, var epoch = readiness,
              epoch.heroSceneUpdateProxyAt == nil else { return }
        if epoch.heroID == nil, !ARBaselineExperiment.current.selectsRoomHero {
            let id = nearestDrop?.id ?? placedHolders.min {
                simd_length($0.value.position - arView.cameraTransform.translation)
                    < simd_length($1.value.position - arView.cameraTransform.translation)
            }?.key
            if let id {
                epoch.selectHero(id)
                let drop = placedDrops[id] ?? nearestDrop
                ARBaselineMetrics.shared.event("selectedHero", details:
                    "id=\(id) asset=\(drop?.assetName ?? drop?.content.rawValue ?? "unmeasured")")
            }
        }
        if let id = epoch.heroID, let holder = placedHolders[id] {
            if epoch.assetReadyAt == nil, epoch.placeholderAt == nil {
                let metrics = ARBaselineMetrics.shared
                metrics.condition("heroID", value: id.uuidString)
                metrics.condition("asset", value: placedDrops[id]?.assetName ?? placedDrops[id]?.content.rawValue ?? "unmeasured")
                metrics.condition("distanceMetersAtPlacement", value: String(simd_length(holder.position - arView.cameraTransform.translation)))
            }
            let now = ProcessInfo.processInfo.systemUptime
            let oldPlaceholder = epoch.placeholderAt
            let oldReady = epoch.assetReadyAt
            epoch.observeContent(id: id, ready: readyContentIDs.contains(id), at: now)
            if oldPlaceholder == nil, epoch.placeholderAt != nil {
                ARBaselineMetrics.shared.event("placeholderPlaced", details: "id=\(id)")
            }
            if oldReady == nil, epoch.assetReadyAt != nil {
                ARBaselineMetrics.shared.event("selectedAssetReady", details: "id=\(id)")
            }
        }
        readiness = epoch
    }

    private func recordContentReadiness(for drop: GeoDrop) {
        let ready = drop.content != .animated
            || drop.assetName.map { DropEntityFactory.isAssetReady($0) } == true
        if ready { readyContentIDs.insert(drop.id) }
        else { readyContentIDs.remove(drop.id) }
    }

    private func observeFreshCamera(arView: ARView) {
        guard readinessActive, !isInterrupted, !sessionFailed,
              var epoch = readiness, epoch.firstFreshFrameAt == nil,
              let frame = arView.session.currentFrame else { return }
        epoch.observeCamera(capturedAt: frame.timestamp,
            observedAt: ProcessInfo.processInfo.systemUptime, sessionRunAt: sessionRunSince)
        if epoch.firstFreshFrameAt != nil {
            ARBaselineMetrics.shared.setWorkload("cameraSessionRunning", enabled: true)
            ARBaselineMetrics.shared.event("firstFreshCameraFrameObserved",
                details: "captureUptime=\(frame.timestamp)")
        }
        readiness = epoch
    }

    private func observeHeroSceneUpdate(arView: ARView) {
        guard cameraVisible, readinessActive, !isInterrupted, !sessionFailed,
              var epoch = readiness, epoch.heroSceneUpdateProxyAt == nil,
              let frame = arView.session.currentFrame else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let id = epoch.heroID, readyContentIDs.contains(id),
           let content = contentEntities[id], content.isActive {
            let bounds = content.visualBounds(relativeTo: nil)
            guard bounds.extents.x.isFinite, bounds.extents.y.isFinite, bounds.extents.z.isFinite,
                  simd_length(bounds.extents) > 0.0001 else { return }
            let center = bounds.center
            let point = arView.project(center)
            let visible = isInView(center, arView: arView)
                && point.map { arView.bounds.contains($0) } == true
            epoch.observeSceneUpdate(id: id, contentReady: readyContentIDs.contains(id),
                inViewport: visible,
                freshCamera: frame.timestamp > max(epoch.startedAt, sessionRunSince)
                    && now - frame.timestamp >= 0 && now - frame.timestamp < 0.25, at: now)
            if timeToFirstHeroProxyMs == nil,
               let ms = epoch.milliseconds(to: epoch.heroSceneUpdateProxyAt) {
                timeToFirstHeroProxyMs = ms
                ARBaselineMetrics.shared.event("firstHeroSceneUpdateProxy", details: "id=\(id) ms=\(ms); presentation unmeasured")
                metricsLog.log("Hero scene-update proxy (\(epoch.kind.rawValue), generation \(epoch.generation)): \(ms) ms; presentation unmeasured")
            }
        }
        readiness = epoch
    }

    /// Record the configuration actually passed to ARKit, not feature-flag intent.
    private func runMeasuredSession(_ configuration: ARConfiguration,
                                    options: ARSession.RunOptions = []) {
        guard let arView else { return }
        if options.contains(.resetTracking) {
            invalidatePerceptionWork(reason: "trackingReset")
        }
        let trace = ARBaselineMetrics.shared.measure("Session configuration")
        defer { ARBaselineMetrics.shared.end(trace) }
        arView.session.run(configuration, options: options)
        sessionRunning = true
        sessionRunSince = ProcessInfo.processInfo.systemUptime
        hasRunSession = true
        let metrics = ARBaselineMetrics.shared
        metrics.setWorkload("cameraSessionRunning", enabled: true)
        let reconstruction = (configuration as? ARWorldTrackingConfiguration)
            .map { !$0.sceneReconstruction.isEmpty } ?? false
        metrics.setWorkload("reconstructionRequested", enabled: reconstruction)
        metrics.setWorkload("personSegmentationRequested", enabled:
            configuration.frameSemantics.contains(.personSegmentation)
                || configuration.frameSemantics.contains(.personSegmentationWithDepth))
        metrics.setWorkload("sceneDepthRequested", enabled:
            configuration.frameSemantics.contains(.sceneDepth)
                || configuration.frameSemantics.contains(.smoothedSceneDepth))
        metrics.event("sessionConfiguration", details:
            "type=\(type(of: configuration)) format=\(configuration.videoFormat.imageResolution) fps=\(configuration.videoFormat.framesPerSecond) semantics=\(configuration.frameSemantics.rawValue) reset=\(options.rawValue)")
    }

    private func recordSessionPaused() {
        sessionRunning = false
        readinessActive = false
        let metrics = ARBaselineMetrics.shared
        for name in ["cameraVisible", "cameraSessionRunning", "reconstructionRequested",
                     "personSegmentationRequested", "sceneDepthRequested"] {
            metrics.setWorkload(name, enabled: false)
        }
        metrics.event("sessionPaused")
        metrics.endEpoch(reason: "sessionPaused")
        metrics.export()
    }

    /// Feeds one heading-error sample into the smoothed estimate.
    /// ADR-003: the FIRST sample seeds the estimate outright (even a rough compass
    /// beats assuming zero error) so spawning never waits on EMA warm-up.
    /// ADR-017 heading authority: a fresh VPS yaw measurement always wins — it is
    /// optical, degree-accurate, and immune to the two compass failure modes that
    /// field tests showed dragging content sideways (direction-dependent magnetic
    /// bias, and CLHeading lagging the physical rotation during pans).
    private func updateHeadingCorrection(frame: ARFrame, alpha: Double) {
        if let sample = geospatial.headingErrorSample,
           sample.timestamp > lastVPSHeadingSampleAt,
           (0..<1.5).contains(Date().timeIntervalSince(sample.timestamp)) {
            // VPS path. Low noise ⇒ faster blend; seed instantly on first use.
            let vpsAlpha = headingSourceIsVPS ? max(alpha, 0.25) : 1.0
            ingestHeadingDelta(sample.radians, alpha: vpsAlpha)
            headingSourceIsVPS = true
            headingSeededMagneticOnly = false // optical truth supersedes the seed
            lastVPSHeadingSampleAt = sample.timestamp
            return
        }
        // VPS silent for a while → fall back to the compass.
        if headingSourceIsVPS,
           Date().timeIntervalSince(lastVPSHeadingSampleAt) > 5 {
            headingSourceIsVPS = false
        }
        guard !headingSourceIsVPS else { return }

        guard let heading = locationService?.currentHeading(),
              heading.timestamp > lastConsumedCompassTimestamp else { return }
        lastConsumedCompassTimestamp = heading.timestamp
        let compassHeading = heading.degrees
        // Counsel MATH-3: magnetic heading differs from true north by the local
        // declination (±15° in major US cities) and `headingAccuracy` carries no
        // information about that error — the gate below is structurally blind to
        // it. A magnetic-only sample may only SEED the estimate (ADR-003:
        // instant spawn beats waiting), flagged so the first true-north sample
        // replaces it outright and forces a placement re-sync. Magnetic samples
        // never refine an established estimate — but they DO flow through the
        // pan-gate bookkeeping below (Wave B review C1/C14: an early return
        // here froze the gate's baseline at seed time, so the alpha-1 re-seed
        // arrived with dt > 3 s and bypassed ADR-017's pan rejection — a
        // mid-pan lagged compass reading could become the wholesale heading).
        let isTrueNorth = heading.reference == .trueNorth
        if headingSampleCount > 0, heading.accuracyDegrees > 30 {
            return // compass is unreliable right now; keep the current estimate
        }
        // Camera look direction, projected onto the ground plane.
        let forward = -frame.camera.transform.columns.2
        guard simd_length(SIMD2(forward.x, forward.z)) > 0.5 else {
            return // pointing too far up/down; bearing is ill-defined
        }
        let yawAR = atan2(Double(forward.x), Double(-forward.z)) * 180 / .pi

        // Pan-rate gate (ADR-017): while the camera is turning, the compass reading
        // is stale relative to the instantaneous AR yaw — the delta is fiction.
        let now = Date()
        if let lastYaw = lastCompassYawAR {
            let dt = now.timeIntervalSince(lastCompassSampleAt)
            if dt > 0, dt < 3 {
                let turned = abs(atan2(
                    sin((yawAR - lastYaw) * .pi / 180), cos((yawAR - lastYaw) * .pi / 180)
                )) * 180 / .pi
                if turned / dt > AppConfig.compassMaxPanRateDegreesPerSecond,
                   headingSampleCount > 0 {
                    lastCompassYawAR = yawAR
                    lastCompassSampleAt = now
                    return
                }
            }
        }
        lastCompassYawAR = yawAR
        lastCompassSampleAt = now

        // MATH-3: magnetic never refines an established estimate — bail AFTER
        // the pan baseline update, so the gate stays armed for the re-seed.
        if !isTrueNorth, headingSampleCount > 0 { return }

        let delta = (compassHeading - yawAR) * .pi / 180
        if isTrueNorth, headingSeededMagneticOnly {
            // MATH-3: the estimate still carries the cold-start declination.
            // Replace it wholesale and lift the refinement refractory so the
            // drift check in the next tick can re-sync placements immediately
            // (a sub-15° declination would otherwise never cross the converged
            // re-sync threshold and the error would be permanent).
            headingSeededMagneticOnly = false
            ingestHeadingDelta(delta, alpha: 1)
            lastRefinementSync = .distantPast
            metricsLog.log("MATH-3: first true-north sample replaced magnetic seed; re-sync freed")
            return
        }
        if !isTrueNorth {
            headingSeededMagneticOnly = true // count == 0: this is the seed
        }
        ingestHeadingDelta(delta, alpha: alpha)
    }

    private func ingestHeadingDelta(_ delta: Double, alpha: Double) {
        if headingSampleCount == 0 || alpha >= 1 {
            headingCorrectionSin = sin(delta)
            headingCorrectionCos = cos(delta)
        } else {
            headingCorrectionSin = (1 - alpha) * headingCorrectionSin + alpha * sin(delta)
            headingCorrectionCos = (1 - alpha) * headingCorrectionCos + alpha * cos(delta)
        }
        headingSampleCount += 1
    }

    // MARK: - Transit path (Wave 5, §6, ADR-015)

    /// Ensures holders exist for eligible drops and reports transit status. The
    /// actual positioning happens per render frame in `transitFrameUpdate`.
    private func tickTransit(drops: [GeoDrop]) {
        guard let arView else { return }
        let root = ensureWorldRoot(in: arView)
        var seen: Set<UUID> = []
        for drop in drops {
            seen.insert(drop.id)
            if !liveEditingDrops.contains(drop.id) {
                placedDrops[drop.id] = drop
                synchronizePhysicalSize(for: drop.id, authoredScale: drop.scale)
            }
            if placedHolders[drop.id] == nil {
                let holder = makeHolder(for: drop)
                root.addChild(holder)
                placedHolders[drop.id] = holder
                DropEntityFactory.startAnimations(on: holder)
            }
        }
        for (id, _) in placedHolders where !seen.contains(id) && roomDrops[id] == nil {
            removePerDropState(id)
        }
        renderedDropCount = placedHolders.count

        if let estimate = locationService?.transitEstimate() {
            switch estimate.quality {
            case .degraded:
                statusText = String(format: "Transit — GPS %.0f s old · positions hidden", estimate.measurementAge)
            case .reacquiring:
                statusText = "Transit — checking the new GPS position…"
            case .tracking:
                statusText = placedHolders.isEmpty ? "Transit mode — no drops within 2 km yet"
                    : String(format: "Transit mode · estimated ±%.0f m", estimate.horizontalUncertainty)
            }
        } else {
            statusText = "Transit — waiting for a reliable GPS position"
        }
        observeSelectedContentReadiness()
    }

    /// Per render frame in transit: re-express every drop relative to the camera
    /// from the dead-reckoned geo-pose. VIO translation errors cancel out because
    /// positions are relative to whatever the camera pose is *this frame*; rotation
    /// rides on ARKit yaw continuously corrected against the compass.
    private func transitFrameUpdate(arView: ARView) {
        guard let estimate = locationService?.transitEstimate(), estimate.quality == .tracking else {
            for (id, holder) in placedHolders where roomDrops[id] == nil { holder.isEnabled = false }
            return
        }
        let camPos = arView.cameraTransform.translation
        let device = estimate.coordinate

        for (id, holder) in placedHolders {
            guard roomDrops[id] == nil else { continue } // AR-space anchored (ADR-025)
            guard let drop = placedDrops[id] else { continue }
            guard let enu = GeoMath.checkedENUOffset(from: device, to: drop.coordinate) else {
                holder.isEnabled = false
                continue
            }
            holder.isEnabled = true
            guard let horizontal = GeoMath.arHorizontal(fromENU: enu, headingCorrection: headingCorrection) else {
                holder.isEnabled = false
                continue
            }
            let x = camPos.x + Float(horizontal.x)
            let z = camPos.z - Float(horizontal.y)
            // Flat-earth vertical over ≤2 km: viewer's eye ≈ 1.5 m above local ground.
            // Rooftop drops carry the nominal building height in transit too.
            let y = camPos.y - 1.5 + Float(drop.heightAboveGround)
                + (drop.isRooftop ? 8 : 0)
            holder.position = SIMD3(x, y, z)
            // §6.2: far-field transit giants may yaw-billboard (exempt from ADR-008).
            holder.orientation = simd_quatf(
                angle: atan2(camPos.x - x, camPos.z - z), axis: [0, 1, 0]
            )
        }
    }

    private func ensureWorldRoot(in arView: ARView) -> AnchorEntity {
        if let worldRoot { return worldRoot }
        let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        arView.scene.addAnchor(root)
        worldRoot = root
        return root
    }

    /// Per render frame: keep each drop's way-point orb readable from afar. The
    /// content itself is never touched — it stays world-locked and true-scale, so
    /// perspective, parallax and occlusion behave like a real physical object.
    private func frameUpdate() {
        ARBaselineMetrics.shared.observe("sceneUpdateProxy")
        let trace = ARBaselineMetrics.shared.measure("Scene update elapsed")
        defer { ARBaselineMetrics.shared.end(trace) }
        if let arView { observeFreshCamera(arView: arView) }
        // RealityKit keeps rendering (and firing SceneEvents) on a frozen or
        // dead camera — render callbacks are NOT proof of session health, so
        // hold all per-frame work while interrupted/failed (Wave B review C19).
        guard mode == .gpsCompass, let arView, cameraVisible, sessionRunning,
              !isInterrupted, !sessionFailed
        else { return }
        if !sessionFrameReady,
           let frame = arView.session.currentFrame,
           frame.timestamp > max(sessionRunSince, readiness?.startedAt ?? sessionRunSince) {
            // ADR-043 reveal signal: only a camera frame captured AFTER the
            // (re)run proves the session is live (final check F5).
            sessionFrameReady = true
        }
        observeSelectedContentReadiness()
        observeHeroSceneUpdate(arView: arView)
        frameCounter += 1
        let now = Date()
        lastFrameUpdateAt = now
        if let last = lastFrameAt {
            frameIntervalsMs.append(now.timeIntervalSince(last) * 1000)
            if frameIntervalsMs.count > 240 {
                frameIntervalsMs.removeFirst(frameIntervalsMs.count - 240)
            }
        }
        lastFrameAt = now

        // Fresh frames and one shared plan admit every producer. Off-dwell
        // requests never independently re-enable a consumer.
        if let frame = arView.session.currentFrame,
           frame.timestamp > max(workFramesAfter, sessionRunSince),
           ProcessInfo.processInfo.systemUptime - frame.timestamp >= 0,
           ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.25 {
            if currentPerceptionPlan.localization,
               now.timeIntervalSince(lastGARFeedAt) >= garFeedInterval {
                geospatial.update(with: frame)
                lastGARFeedAt = now
            }
            if currentPerceptionPlan.sentinel {
                personSentinel.update(pixelBuffer: frame.capturedImage)
            }
            if currentPerceptionPlan.midField {
                midDepth.loadIfNeeded()
                midDepth.update(frame: frame, hz: AppConfig.midDepthHz)
            }
        }

        if renderPath == .transit {
            transitFrameUpdate(arView: arView)
        } else if !deferredTargets.isEmpty || !deferredVPSTransforms.isEmpty {
            drainDeferredCorrections(arView: arView)
        }

        guard !placedHolders.isEmpty else { return }
        let camPos = arView.cameraTransform.translation

        let tanHalfAngle = Float(tan(AppConfig.minApparentAngleDegrees * .pi / 180 / 2))

        for (id, marker) in markers {
            guard let holder = placedHolders[id] else { continue }
            let distance = simd_length(holder.position - camPos)
            if distance < 25 {
                marker.isEnabled = false // close enough — the content speaks for itself
                // ADR-046: first arrival earns a celebration burst.
                if !revealedDrops.contains(id), let drop = placedDrops[id] {
                    revealedDrops.insert(id)
                    if #available(iOS 18.0, *) {
                        let burst = DropEffects.revealBurst(color: drop.uiColor)
                        if let content = contentEntities[id] {
                            burst.position = [0, content.visualBounds(relativeTo: holder).center.y, 0]
                        }
                        holder.addChild(burst)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            burst.removeFromParent()
                        }
                    }
                }
                continue
            }
            marker.isEnabled = true
            let requiredDiameter = 2 * distance * tanHalfAngle
            marker.scale = SIMD3(repeating: min(max(1, requiredDiameter / 0.8),
                                                AppConfig.maxDistanceBoost))
        }
    }

    /// Lowest *plausible* horizontal plane ≈ the ground. Night-time depth noise
    /// (reflective roads, headlights) can produce planes tens of meters off, and one
    /// bad plane would sink every drop underground — so only planes within a sane
    /// band below the camera (held at standing height) are trusted.
    private func estimatedGroundY(frame: ARFrame) -> Float? {
        let camY = frame.camera.transform.columns.3.y
        let planeYs = frame.anchors.compactMap { anchor -> Float? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else {
                return nil
            }
            let y = plane.transform.columns.3.y
            guard y > camY - 4, y < camY - 0.5 else { return nil }
            return y
        }
        return planeYs.min()
    }

    // MARK: - Tier B: ARGeoAnchors

    private func tickGeoTracking() {
        guard let arView else { return }

        if let status = arView.session.currentFrame?.geoTrackingStatus {
            switch status.state {
            case .localized:
                statusText = "Precise mode locked — content is world-accurate"
            case .localizing:
                statusText = "Point the camera at buildings across the street…"
            case .initializing:
                statusText = "Initializing precise tracking…"
            case .notAvailable:
                statusText = "Precise tracking unavailable right now"
            @unknown default:
                break
            }
        }

        for drop in eligibleDrops where !geoAnchoredDropIDs.contains(drop.id) {
            // Altitude omitted on purpose: ARKit resolves the ground elevation itself.
            let geoAnchor = ARGeoAnchor(coordinate: drop.coordinate)
            arView.session.add(anchor: geoAnchor)

            // Target-by-identifier avoids the ARAnchor convenience initializer's
            // missing back-deployment symbol with Xcode 26.6 on iOS 17.
            let anchorEntity = AnchorEntity(.anchor(identifier: geoAnchor.identifier))
            let entity = DropEntityFactory.makeEntity(for: drop, fullBright: contentFullBright)
            entity.position.y = Float(drop.heightAboveGround)
            // Geo anchor local frame: +X east, −Z north. Face the viewer's position.
            if let viewer = locationService?.location {
                let bearing = GeoMath.bearing(from: drop.coordinate, to: viewer.coordinate)
                entity.orientation = simd_quatf(
                    angle: Float((180 - bearing) * .pi / 180), axis: [0, 1, 0]
                )
            }
            anchorEntity.addChild(entity)
            arView.scene.addAnchor(anchorEntity)
            DropEntityFactory.startAnimations(on: entity)
            geoAnchors.append(anchorEntity)
            geoAnchoredDropIDs.insert(drop.id)
        }
        renderedDropCount = geoAnchoredDropIDs.count
    }
}

// MARK: - ARSessionDelegate (counsel ARP-5/SWE-1)

/// The baseline lifecycle contract for a shipping ARKit app: interruptions,
/// errors, tracking state, and the relocalize-vs-reset decision all arrive
/// here. Before this extension existed, a phone call froze the viewfinder
/// permanently and a session error died silently behind a black screen.
extension GeoARSessionManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let metrics = ARBaselineMetrics.shared
        guard metrics.isEnabled else { return }
        let trace = metrics.measure("Capture delivery observation")
        defer { metrics.end(trace) }
        let now = ProcessInfo.processInfo.systemUptime
        metrics.observe("captureDelivery", at: now)
        metrics.observe("captureTimestamp", at: frame.timestamp)
        metrics.sample("captureSampleAge", milliseconds: (now - frame.timestamp) * 1000)
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            ARBaselineMetrics.shared.event("sessionInterrupted")
            ARBaselineMetrics.shared.setWorkload("cameraSessionRunning", enabled: false)
            self.readinessActive = false
            ARBaselineMetrics.shared.endEpoch(reason: "sessionInterrupted")
            self.isInterrupted = true
            self.invalidatePerceptionWork(reason: "interruption")
            self.sessionFrameReady = false
            self.disarmSemanticMatte() // arui-4: the flag can't fall on its own here
            self.statusText = "Paused"
            self.metricsLog.log("ARSession interrupted (call / app switch)")
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            guard self.sessionRunning, self.isInterrupted else { return }
            self.isInterrupted = false
            self.workFramesAfter = ProcessInfo.processInfo.systemUptime
            if self.cameraVisible { self.beginReadinessEpoch(.recovery) }
            self.statusText = "Resuming…"
            self.metricsLog.log("ARSession interruption ended — relocalizing")
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        // ARP-4: the entire point of the warm resume — relocalize against the
        // retained world map instead of resetting the world.
        true
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let nsError = error as NSError
        Task { @MainActor in
            self.metricsLog.error("ARSession failed (\(nsError.code)): \(nsError.localizedDescription)")
            self.sessionFrameReady = false
            self.sessionFailed = true
            self.invalidatePerceptionWork(reason: "failure")
            ARBaselineMetrics.shared.setWorkload("cameraSessionRunning", enabled: false)
            self.readinessActive = false
            ARBaselineMetrics.shared.event("sessionFailed", details: "code=\(nsError.code)")
            ARBaselineMetrics.shared.endEpoch(reason: "sessionFailed")
            self.disarmSemanticMatte() // arui-4
            if nsError.domain == ARError.errorDomain,
               nsError.code == ARError.Code.cameraUnauthorized.rawValue {
                // Terminal until the user changes Settings — no retry loop.
                self.statusText = "Camera access is denied — enable it in Settings"
                return
            }
            // A failed session is dead; a fresh cold run is the correct
            // recovery. Rate-limited — but a failure inside the window DEFERS
            // the retry (consumed by tick) instead of dropping it, so a burst
            // of failures can't leave a dead session forever (review C13/C18).
            self.statusText = "Camera hit a problem — restarting…"
            if Date().timeIntervalSince(self.lastSessionFailureRecoveryAt) > 5 {
                // Final check F3: never turn the camera on while the surface is
                // hidden — the tick loop's existence IS "camera surface active"
                // (suspend cancels it). A failure landing after suspend keeps
                // sessionFailed set; the next resume cold-restarts (F1).
                guard self.tickTask != nil, self.sessionRunning, self.cameraVisible else {
                    // A short return inside grace does not call resumeSession.
                    // Keep recovery pending for its first visible policy tick.
                    self.failureRetryDeadline = Date()
                    return
                }
                self.lastSessionFailureRecoveryAt = Date()
                self.runGPSCompass()
            } else {
                self.failureRetryDeadline =
                    self.lastSessionFailureRecoveryAt.addingTimeInterval(5.5)
            }
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        Task { @MainActor in
            if case .limited(.relocalizing) = state {
                if self.relocalizingSince == nil { self.relocalizingSince = Date() }
            } else {
                self.relocalizingSince = nil
            }
        }
    }
}
