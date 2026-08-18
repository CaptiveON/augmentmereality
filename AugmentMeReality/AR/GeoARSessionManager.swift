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
/// slides) as better fixes arrive, and far content is scaled up to a minimum apparent
/// size that hands over to true perspective as you approach.
@MainActor
final class GeoARSessionManager: NSObject, ObservableObject {
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
    /// Killer-#1 metric (BRIEF): ms from AR attach to first rendered object.
    @Published private(set) var timeToFirstObjectMs: Int?
    /// ADR-043 reveal signal: true once the running session has rendered a frame.
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

    /// ADR-033 power governor: every expensive subsystem runs only while the
    /// scene needs it. Heat is prevented, not reacted to.
    private var governor = PowerGovernor()
    @Published private(set) var powerTier: PowerGovernor.Tier = .idle
    /// Actual capture format in use (ADR-034 field instrument — shows in HUD so
    /// a heat report always carries the resolution/fps evidence).
    @Published private(set) var videoFormatDescription = "?"
    private var cameraVisible = false
    private var lastBatteryLogAt = Date.distantPast
    /// Person-segmentation ML lingers this long after content leaves the view so
    /// glance-away/glance-back doesn't churn session reconfigurations.
    private var lastContentInViewAt = Date.distantPast
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

    // Systems-health metrics (§10): render fps, frame-time p95, thermal state,
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
    private var cameraVisibleAt: Date?

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
    /// ADR-023 grounding discs: the size-vs-distance disambiguator. Without a
    /// ground-contact cue, angular growth is perceptually ambiguous between
    /// "bigger" and "closer"; a shadow planted at the object's ground spot that
    /// only grows laterally makes scaling read as "giant, still far away".
    private var groundDiscs: [UUID: ModelEntity] = [:]
    /// ADR-049: the perceptual-size factor currently baked into each content
    /// entity's scale (content.scale = drop.scale × this). Invalidated whenever
    /// the content model is swapped so the factor is re-applied to the fresh
    /// entity on the next frame.
    private var appliedCompensation: [UUID: Float] = [:]
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
    private var attachedAt: Date?
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
        attachedAt = Date()
        timeToFirstObjectMs = nil

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
        arView?.session.pause()
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

    /// ADR-013: the AR session outlives the camera tab (pre-warm). Suspend pauses
    /// tracking without tearing down the view, VPS session, or Metal pass.
    func suspendSession() {
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
        personDownSince = nil
        depthDownSince = nil
        cancelLiveEdit()
        arView?.session.pause()
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
        idleFor > 5 && attachedFor > 10
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
        guard let arView, mode != .unsupported else { return }
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
                arView.session.run(config)
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
                supportsSceneReconstruction: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
                cameraRecentlyVisible: Self.visibilityTerm(
                    cameraVisible: cameraVisible, now: Date(),
                    lastVisible: lastCameraVisibleAt
                ),
                pedestrian: renderPath == .pedestrian,
                thermalCritical: ProcessInfo.processInfo.thermalState == .critical
            ),
            person: false,
            depth: false
        )
        appliedPerception = resumePlan
        arView.session.run(makeConfiguration(
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
        // Round 3 (counsel ARPCFG-R2-1): the TRUE hide edge is stamped here —
        // the per-tick stamp was up to 400 ms stale, so the grace expired
        // just before the 5 s pause it exists to cover and roughly half of
        // tab flips still destroyed the mesh.
        lastCameraVisibleAt = Date()
        // Round 2 (counsel FLOW-5): a drag can't outlive the surface it was
        // dragging on — abandon it now, never at the next commit that will
        // never come.
        cancelLiveEdit()
    }

    /// Killer-#1 measurement point: TTFO counts from the moment the user can see
    /// the camera, not from session start. Pre-warmed content ⇒ 0 ms.
    func markCameraVisible() {
        cameraVisible = true
        cameraVisibleAt = Date()
        if !placedHolders.isEmpty {
            timeToFirstObjectMs = 0
            metricsLog.log("TTFO: 0 ms (pre-warmed; content already placed)")
        } else {
            timeToFirstObjectMs = nil
        }
    }

    /// Drops a throwaway "IT WORKS 🎉" 15 m in the direction the user is facing —
    /// instant gratification without walking anywhere. Not persisted.
    func placeDemoDrop() {
        guard let location = locationService?.location else { return }
        let heading = locationService?.headingDegrees ?? 0
        let coordinate = GeoMath.coordinate(
            from: location.coordinate, bearingDegrees: heading, distanceMeters: 15
        )
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
        recordTTFOIfNeeded()
    }

    func clearRoomDrops() {
        // Round 2 (counsel STATE-3): the third destroy site goes through the
        // ONE cleanup helper like every other — its ad-hoc loop missed
        // editingDropID and revealedDrops.
        for id in roomDrops.keys {
            removePerDropState(id)
        }
        roomDrops.removeAll()
        renderedDropCount = placedHolders.count
    }

    var hasRoomDrops: Bool { !roomDrops.isEmpty }

    // MARK: - Session setup

    private func decideModeAndRun() {
        if AppConfig.appleGeoAnchorsEnabled, ARGeoTrackingConfiguration.isSupported {
            ARGeoTrackingConfiguration.checkAvailability { [weak self] available, _ in
                Task { @MainActor in
                    guard let self, self.arView != nil else { return }
                    if available {
                        self.runGeoTracking()
                    }
                }
            }
        }
        // Compass mode immediately; upgrades to geo tracking if the check succeeds.
        runGPSCompass()
    }

    private func runGeoTracking() {
        guard let arView else { return }
        let config = ARGeoTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        resetPlacements()
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
            if Self.supportsCustomPersonOcclusion {
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

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        resetPlacements()
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
        guard desired != appliedPerception, mode == .gpsCompass, let arView else { return }
        appliedPerception = desired
        arView.session.run(makeConfiguration(
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
        appliedCompensation.removeAll()
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
        lastRefinementSync = .distantPast
        headingSeededMagneticOnly = false
        relocalizingSince = nil
        vpsOwnedDrops.removeAll()
        vpsGlideUntil.removeAll()
        vpsCorrectionTotals.removeAll()
        vpsCorrectionCm = nil
        renderedDropCount = 0
        // Round 5 (counsel F-D4-TTFO): re-arm the Killer-#1 instrument WHERE
        // PLACEMENTS DIE, so no restorer call ordering can decide it. The
        // round-4 reorder let a failed-session resume latch TTFO = 0 from
        // pre-failure holders that this very reset then destroyed — the
        // metric failed in the flattering direction, the one a field run
        // cannot detect. attach() clears it on entry; this is the twin.
        timeToFirstObjectMs = nil
        cameraVisibleAt = Date()
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
        if sessionFailed, let deadline = failureRetryDeadline, Date() >= deadline {
            failureRetryDeadline = nil
            lastSessionFailureRecoveryAt = Date()
            metricsLog.log("Deferred session-failure recovery firing")
            runGPSCompass()
        }
        // ARP-4: a warm resume that cannot relocalize (the user moved too far
        // while suspended) would sit in .limited(.relocalizing) forever. After a
        // bounded wait, restart cold — reset tracking AND re-request every GAR
        // anchor in the fresh frame — rather than hang on a frozen world.
        if let since = relocalizingSince,
           Date().timeIntervalSince(since) > relocalizeGiveUpSeconds {
            relocalizingSince = nil
            metricsLog.log("Relocalization stalled — falling back to cold restart")
            runGPSCompass()
        }
        // Final check F2: while interrupted or failed, the frozen frame must
        // not feed VPS inference (the app's #1 heat source) and the session
        // must not be reconfigured out from under ARKit's own recovery.
        guard !isInterrupted, !sessionFailed else { return }
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

        // Pre-warm (ADR-013): while the ARView is off-screen the render loop idles,
        // so keep the VPS session fed from here (2.5 Hz is plenty to converge).
        if Date().timeIntervalSince(lastFrameUpdateAt) > 0.5,
           let frame = arView?.session.currentFrame {
            geospatial.update(with: frame)
        }
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

    /// ADR-033: feed the governor the scene's actual demands, apply the verdict.
    private func updatePowerTier() {
        // Round 2 (counsel STATE-1/FLOW-5) corrected in round 3 (STATE-L1)
        // and round 4 (F-D3-03): abandonment never fires on a HELD gesture,
        // and the backstop is UNGATED on the capture — a latched hold with no
        // capture (lost end event before any tick) must still expire.
        if editingDropID != nil || gestureHeld,
           Self.gestureAbandoned(
               now: Date(), lastTick: lastLiveEditTickAt, held: gestureHeld
           ) {
            cancelLiveEdit()
        }
        if cameraVisible { lastCameraVisibleAt = Date() }
        var contentInView = false
        var nearestRendered: Float?
        var anyContentMidServiceable = false
        if let arView, !placedHolders.isEmpty {
            let camPos = arView.cameraTransform.translation
            for holder in placedHolders.values {
                let distance = simd_length(holder.position - camPos)
                nearestRendered = min(nearestRendered ?? .infinity, distance)
                if Self.midFieldServiceable(distance: distance) {
                    anyContentMidServiceable = true
                }
                if !contentInView, isInView(holder.position, arView: arView) {
                    contentInView = true
                }
            }
        }
        let thermal = ProcessInfo.processInfo.thermalState
        let tier = governor.evaluate(.init(
            cameraVisible: cameraVisible,
            hasRenderedContent: !placedHolders.isEmpty,
            contentInView: contentInView,
            nearestRenderedDistance: nearestRendered,
            vpsConverging: geospatial.isConverging,
            isLiveEditing: !liveEditingDrops.isEmpty,
            thermalSerious: thermal == .serious,
            thermalCritical: thermal == .critical
        ))
        if tier != powerTier {
            powerTier = tier
            metricsLog.log("Power tier → \(tier.description)")
        }
        if contentInView {
            lastContentInViewAt = Date()
        }
        // Track convergence attempts for the sprint ladder (ADR-036).
        if geospatial.isConverging {
            if convergenceSprintStart == nil {
                convergenceSprintStart = Date()
                metricsLog.log("VPS convergence sprint started")
            }
        } else {
            convergenceSprintStart = nil
        }
        // Perception ML above idle. Person segmentation (14–29 ms/frame, the
        // single hottest ARKit stream) only while content is in view AND a human
        // is actually present (ADR-037 sentinel). The scene-depth ML fusion runs
        // only for its real consumers: the person depth-test or mid-field
        // alignment with far content.
        // Window mode (ADR-044): reflections misfire the person model and the
        // LiDAR band is all pane — both depth consumers shed.
        // Wave D (counsel SWE-11/ARP-8): the request set is a PURE function of
        // its inputs — the sensor REQUEST derives from the same predicate as
        // the sensor's USE — with hysteresis so a person stepping out of frame
        // (5 s sentinel decay) can't cycle `session.run` on the 400 ms tick.
        let plan = Self.perceptionPlan(
            tierAboveIdle: tier > .idle,
            fullTier: tier == .full,
            cameraVisible: cameraVisible,
            cameraRecentlyVisible: Self.visibilityTerm(
                cameraVisible: cameraVisible, now: Date(),
                lastVisible: lastCameraVisibleAt
            ),
            pedestrian: renderPath == .pedestrian,
            windowModeActive: windowModeActive,
            personLikely: personSentinel.personLikely,
            contentInViewRecently: Date().timeIntervalSince(lastContentInViewAt) < 30,
            midFieldServiceable: anyContentMidServiceable,
            thermalSerious: thermal == .serious || thermal == .critical,
            thermalCritical: thermal == .critical,
            supportsCustomPersonOcclusion: Self.supportsCustomPersonOcclusion,
            supportsSceneReconstruction: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
            supportsSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            midFieldEnabled: AppConfig.midFieldDepthEnabled
        )
        let person = applyPerceptionHysteresis(
            desired: plan.person, applied: appliedPerception.person,
            downSince: &personDownSince
        )
        let depth = applyPerceptionHysteresis(
            desired: plan.depth, applied: appliedPerception.depth,
            downSince: &depthDownSince
        )
        setPerception(reconstruction: plan.reconstruction, person: person, depth: depth)
        // Wave D (SWE-11 tail): the HUD chip reports what is ACTUALLY
        // configured this session — and the plan now carries the capability
        // terms, so this can never claim a stream the hardware lacks
        // (round 2, counsel ARPCFG-7/FLOW-8).
        occlusionActive = appliedPerception.reconstruction
        // Round 2 (counsel ARPCFG-3/STATE-2): the occlusion OPTION is derived
        // here every tick — transitions (window mode, render path) set only
        // their own flags and can no longer strand the option removed.
        if let arView {
            let wanted = Self.occlusionOptionDesired(
                capable: occlusionCapable,
                pedestrian: renderPath == .pedestrian,
                windowModeActive: windowModeActive
            )
            if wanted {
                arView.environment.sceneUnderstanding.options.insert(.occlusion)
            } else {
                arView.environment.sceneUnderstanding.options.remove(.occlusion)
            }
        }

        // ADR-035 range-based exclusivity: Google's semantic NN only exists for
        // the >60 m band (and transit, where it is the only occluder). With no
        // content out there, the model must not run at all.
        let needsSemantics = renderPath == .transit
            || (nearestRendered != nil && placedHolders.values.contains { holder in
                arView.map { simd_length(holder.position - $0.cameraTransform.translation) > 55 }
                    ?? false
            })
        geospatial.setSemanticsActive(needsSemantics && tier > .idle)

        // The Metal pass costs a full-screen copy per frame just by being
        // attached — attach only while some job has work; detach after 5 s idle.
        // Wave B review C7: on hardware without the custom person path the pass
        // was built with personOcclusionEnabled=false — person semantics alone
        // give it NO work there (RealityKit's built-in occlusion carries it),
        // so attaching would burn an offscreen render + blit for nothing.
        let passNeeded = (Self.supportsCustomPersonOcclusion && appliedPerception.person)
            || semanticMatteArmed || midDepthActive
        // Round 2 (counsel RENDER-1 step 1) re-derived in round 3 (counsel
        // RENDER-LENS-1): a DWELL FLOOR on the callback slots — their toggle
        // frequency IS the race surface. Both conjuncts BIND now: 5 s of no
        // work AND 10 s attached (the round-2 15 s idle term dominated the
        // attach term, making it dead code and tripling the idle-attached
        // heat window over ADR-035's measured 5 s). Step 2, the on-device
        // TSan run, is a field task.
        if passNeeded {
            passIdleSince = nil
            if !(semanticPass?.callbacksActive ?? false) {
                passAttachedAt = Date()
            }
            // Round 5 (counsel F-D4-DETACH): the attach/detach instrument
            // lives INSIDE setCallbacksActive's changed-region — the round-4
            // logs here covered 2 of 6 detach sites (disarmSemanticMatte's
            // four production paths were silent, so the FT-28/31 toggle
            // count and dwell histogram undercounted every interruption).
            semanticPass?.setCallbacksActive(true)
        } else if let since = passIdleSince {
            if semanticPass?.callbacksActive == true,
               Self.passShouldDetach(
                   idleFor: Date().timeIntervalSince(since),
                   attachedFor: Date().timeIntervalSince(passAttachedAt)
               ) {
                semanticPass?.setCallbacksActive(false)
            }
        } else {
            passIdleSince = Date()
        }
    }
    private var passIdleSince: Date?
    private var passAttachedAt = Date.distantPast
    private var personDownSince: Date?
    private var depthDownSince: Date?

    /// Wave D (counsel SWE-11/ARP-8 + ARP-13's testability ask): the perception
    /// request set as a PURE function — table-tested on device, no ARKit needed.
    /// Reconstruction is stateful (rebuilds leave multi-second occlusion holes)
    /// so it keys ONLY on stable session facts: camera visible, pedestrian
    /// path, not thermally critical. Person/depth are the fast semantics; each
    /// depth term carries its own preconditions so a request can never outlive
    /// its use (the transit-meshing and transit-depth leaks).
    nonisolated static func perceptionPlan(
        tierAboveIdle: Bool,
        fullTier: Bool,
        cameraVisible: Bool,
        cameraRecentlyVisible: Bool,
        pedestrian: Bool,
        windowModeActive: Bool,
        personLikely: Bool,
        contentInViewRecently: Bool,
        midFieldServiceable: Bool,
        thermalSerious: Bool,
        thermalCritical: Bool,
        supportsCustomPersonOcclusion: Bool,
        supportsSceneReconstruction: Bool,
        supportsSceneDepth: Bool,
        midFieldEnabled: Bool
    ) -> (reconstruction: Bool, person: Bool, depth: Bool) {
        // Round 2 (counsel ARPCFG-7/FLOW-8): CAPABILITY terms live in the plan
        // — appliedPerception must record what the configuration actually
        // requests, never a desire the hardware can't deliver (the LiDAR chip
        // lit on non-LiDAR phones and setPerception churned no-op runs).
        // Round 2 (counsel ARPCFG-4): reconstruction keys on RECENT visibility
        // (the pause-grace window) so a sub-5 s tab flip cannot destroy and
        // rebuild the mesh the app already decided to smooth over; the
        // per-frame ML keeps the hard visibility term.
        let reconstruction = reconstructionDesired(
            supportsSceneReconstruction: supportsSceneReconstruction,
            cameraRecentlyVisible: cameraRecentlyVisible,
            pedestrian: pedestrian,
            thermalCritical: thermalCritical
        )
        let person = cameraVisible
            && tierAboveIdle
            && contentInViewRecently
            && personLikely
            && !windowModeActive
        // Round 2 (counsel ARPCFG-1): the mid-field depth term is the
        // CONSUMER's real predicate — serviceable band (4–5 m), pedestrian,
        // full tier, not thermally serious — never the unbounded "anything
        // beyond 4 m" that ran the 60 Hz depth ML with zero consumer.
        let depth = supportsSceneDepth
            && cameraVisible
            && ((person && supportsCustomPersonOcclusion)
                || (midFieldEnabled && midFieldServiceable && fullTier
                    && pedestrian && !thermalSerious))
            && !windowModeActive
        return (reconstruction, person, depth)
    }

    /// Round 2 (counsel ARPCFG-1): the ONE predicate shared by the request
    /// side (perceptionPlan) and the use side (frameUpdate's mid-depth gate) —
    /// a drop is mid-field-serviceable only inside the band LiDAR can
    /// calibrate (4 m … 4 m × 1.25).
    nonisolated static func midFieldServiceable(distance: Float) -> Bool {
        distance > Float(AppConfig.midDepthMinContentDistance)
            && distance < Float(AppConfig.midDepthLiDARBandMax * AppConfig.midDepthSupportMargin)
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

    /// Wave D (counsel SWE-11): semantics engage IMMEDIATELY (occlusion
    /// correctness can't wait on a timer) but disengage only after the desire
    /// has been continuously absent for 10 s AND the stream is actually on —
    /// never re-raising a stream that is already off.
    private func applyPerceptionHysteresis(
        desired: Bool, applied: Bool, downSince: inout Date?
    ) -> Bool {
        if desired {
            downSince = nil
            return true
        }
        guard applied else {
            downSince = nil
            return false
        }
        if let since = downSince {
            if Date().timeIntervalSince(since) >= 10 {
                downSince = nil
                return false
            }
            return true
        }
        downSince = Date()
        return true
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

    /// §10 systems health: render fps (from the per-frame callback) + thermal state.
    private func updateHealthMetrics() {
        let now = Date()
        let window = now.timeIntervalSince(fpsWindowStart)
        if window >= 2 {
            renderFPS = Int((Double(frameCounter) / window).rounded())
            frameCounter = 0
            fpsWindowStart = now
        }
        let thermal = ProcessInfo.processInfo.thermalState
        thermalSerious = thermal == .serious || thermal == .critical

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

        // ADR-049 field truth: the visual angle the nearest content actually
        // subtends in the camera right now (bounds include the perceptual
        // factor), plus that factor when it is boosting.
        var sizeText = ""
        if let content = contentEntities[nearestID] {
            let distance = simd_length(offset)
            let height = content.visualBounds(relativeTo: holder).extents.y
            if distance > 0.5, height > 0.01 {
                let degrees = 2 * atan(Double(height) / (2 * Double(distance))) * 180 / .pi
                let factor = appliedCompensation[nearestID] ?? 1
                sizeText = factor > 1.01
                    ? String(format: " · %.1f° ×%.1f", degrees, factor)
                    : String(format: " · %.1f°", degrees)
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
        guard let arView else { return }
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
        appliedCompensation[id] = nil
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

        guard let fix = locationService.location, fix.horizontalAccuracy > 0 else {
            statusText = "Waiting for a GPS fix…"
            return
        }
        motionState = motion.update(speed: max(fix.speed, 0))
        guard let frame = arView.session.currentFrame else {
            statusText = "Starting camera…"
            return
        }

        // Transit trusts the compass more (VIO yaw may be corrupted by the moving
        // scene) — faster correction; pedestrian keeps the slow, stable estimate.
        updateHeadingCorrection(frame: frame, alpha: renderPath == .transit ? 0.2 : 0.08)

        if renderPath == .transit {
            tickTransit(drops: eligibleDrops, fix: fix)
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
            let gpsDelta = GeoMath.enuOffset(from: basis.coordinate, to: fix.coordinate)
            let correction = simd_length(SIMD2(gpsDelta.x - arEast, gpsDelta.y - arNorth))

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
            statusText = String(format: "Compass mode · GPS ±%.0f m", fix.horizontalAccuracy)
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
        for drop in drops {
            seen.insert(drop.id)
            placedDrops[drop.id] = drop

            // Drops owned by VPS are world-accurate already — never touch them here.
            // Ditto anything mid-live-edit: the sliders own it until release.
            if placedHolders[drop.id] != nil,
               vpsOwnedDrops.contains(drop.id) || liveEditingDrops.contains(drop.id) {
                continue
            }

            // Rotate the true east/north offset into the AR frame, compensating for
            // the session's measured compass error.
            let enu = GeoMath.enuOffset(from: fix.coordinate, to: drop.coordinate)
            let distance = simd_length(enu)
            let bearingAR = atan2(enu.x, enu.y) - headingCorrection
            let east = distance * sin(bearingAR)
            let north = distance * cos(bearingAR)
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
        if frame.camera.trackingState == .normal {
            placementBasis = fix
            basisCameraPosition = SIMD3(cam.x, cam.y, cam.z)
            appliedHeadingCorrection = headingCorrection
            lastRefinementSync = Date()
        }
        renderedDropCount = placedHolders.count

        recordTTFOIfNeeded()
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
        if !commit { lastLiveEditTickAt = Date() }
        if commit {
            // Round 5 (counsel F-D4-01): commit bookkeeping is PURE and lives
            // in the BINDING half — the shared capture survives until the
            // LAST finger lifts. It stays hoisted above the resolve (round 4,
            // F-D3-03: a failed resolve must not strand the count).
            (heldGestures, editingDropID) = Self.commitBookkeeping(
                heldGestures: heldGestures, capture: editingDropID, committed: id
            )
        }
        applyEdit(to: id, height: height, scale: scale, rotation: rotation, commit: commit)
    }

    /// Round 4 (counsel F-D3-01): the MUTATION, split from gesture binding —
    /// programmatic (authored) callers commit to an explicit target with no
    /// gesture state read or written. Round 5 (counsel F-D4-01): that
    /// contract is now actually TRUE — the round-4 body still cleared the
    /// shared `editingDropID` capture in two places, so the first commit of
    /// a two-thumb interaction (or an authored snap mid-drag) un-froze
    /// `updateNearest` under a still-held finger. Capture teardown lives in
    /// `adjustNearestDrop` via `commitBookkeeping`; the only gesture-adjacent
    /// state touched here is `liveEditingDrops`, which is per-DROP render
    /// state (governor pin + VPS never-fight-the-finger), not per-gesture.
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
            ?? demoDrops.first(where: { $0.id == id }) else {
            liveEditingDrops.remove(id)
            return
        }
        var drop = resolved
        let oldHeight = drop.heightAboveGround
        if let height { drop.heightAboveGround = height }
        if let scale { drop.scale = scale }
        if let rotation { drop.facingDegrees = rotation }
        placedDrops[id] = drop
        // An authored edit of a non-nearest target must not clobber nearest.
        if nearestDrop == nil || nearestDrop?.id == id { nearestDrop = drop }

        if !commit {
            liveEditingDrops.insert(id)
        }

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
            if let scale, let content = contentEntities[id] {
                // ADR-049: the rendered scale is always drop.scale × the
                // distance factor — the slider edits the true size only.
                let factor = max(appliedCompensation[id] ?? 1, 1)
                content.scale = SIMD3(repeating: Float(scale) * factor)
                if let marker = markers[id] {
                    let top = content.visualBounds(relativeTo: holder).max.y
                    marker.position.y = max(top, 0) + 2
                }
                // ADR-023: the ground anchors grow with the content so "giant"
                // keeps reading as far-away-giant, not approaching.
                if let disc = groundDiscs[id] {
                    let radius = Self.groundDiscRadius(for: content, relativeTo: holder)
                    disc.scale = [radius, 0.01, radius]
                }
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
            liveEditingDrops.remove(id)
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
            guard let holder = placedHolders[id] else { continue }
            contentEntities[id]?.removeFromParent()
            let fresh = DropEntityFactory.makeEntity(for: drop, fullBright: contentFullBright)
            holder.addChild(fresh)
            contentEntities[id] = fresh
            appliedCompensation[id] = nil // ADR-049: re-applied on the next frame
            DropEntityFactory.startAnimations(on: fresh)
            // Re-seat the marker and grounding disc for the real model's bounds.
            if let marker = markers[id] {
                let top = fresh.visualBounds(relativeTo: holder).max.y
                marker.position.y = max(top, 0) + 2
            }
            if let disc = groundDiscs[id] {
                let radius = Self.groundDiscRadius(for: fresh, relativeTo: holder)
                disc.scale = [radius, 0.01, radius]
            }
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
        if let geo = geospatial.geoCoordinate(of: worldPoint) {
            updated.latitude = geo.coordinate.latitude
            updated.longitude = geo.coordinate.longitude
            metricsLog.log("Relocate via VPS ±\(geo.horizontalAccuracy) m")
        } else if let fix = locationService?.location {
            let camPos = arView.cameraTransform.translation
            let offset = worldPoint - camPos
            let eastAR = Double(offset.x)
            let northAR = Double(-offset.z)
            let bearingTrue = atan2(eastAR, northAR) + headingCorrection
            let distance = (eastAR * eastAR + northAR * northAR).squareRoot()
            let coordinate = GeoMath.coordinate(
                from: fix.coordinate,
                bearingDegrees: bearingTrue * 180 / .pi,
                distanceMeters: distance
            )
            updated.latitude = coordinate.latitude
            updated.longitude = coordinate.longitude
            metricsLog.log("Relocate via GPS fallback (±\(fix.horizontalAccuracy) m)")
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
            appliedCompensation[id] = nil // fresh entity carries no factor yet
            DropEntityFactory.startAnimations(on: fresh)
        }
    }

    /// Killer-#1 metric: measure, then claim (BRIEF bar: median ≤ 400 ms).
    private func recordTTFOIfNeeded() {
        if timeToFirstObjectMs == nil, !placedHolders.isEmpty,
           let reference = cameraVisibleAt ?? attachedAt {
            let ms = Int(Date().timeIntervalSince(reference) * 1000)
            timeToFirstObjectMs = ms
            metricsLog.log("TTFO: \(ms) ms from camera visible to first rendered object")
        }
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
           Date().timeIntervalSince(sample.timestamp) < 1.5 {
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

        guard let compassHeading = locationService?.headingDegrees else { return }
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
        let isTrueNorth = locationService?.headingIsTrueNorth == true
        if headingSampleCount > 0,
           let accuracy = locationService?.headingAccuracy, accuracy < 0 || accuracy > 30 {
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
    private func tickTransit(drops: [GeoDrop], fix: CLLocation) {
        guard let arView else { return }
        let root = ensureWorldRoot(in: arView)
        var seen: Set<UUID> = []
        for drop in drops {
            seen.insert(drop.id)
            placedDrops[drop.id] = drop
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

        let fixAge = Date().timeIntervalSince(fix.timestamp)
        if fixAge > 8 {
            // §6.5 honest degradation: never fake a lock we don't have.
            statusText = "Transit — GPS stale (tunnel?), positions may lag"
        } else if placedHolders.isEmpty {
            statusText = "Transit mode — no drops within 2 km yet"
        } else {
            statusText = String(
                format: "Transit mode · %.0f km/h · GPS ±%.0f m",
                max(fix.speed, 0) * 3.6, fix.horizontalAccuracy
            )
        }
        recordTTFOIfNeeded()
    }

    /// Per render frame in transit: re-express every drop relative to the camera
    /// from the dead-reckoned geo-pose. VIO translation errors cancel out because
    /// positions are relative to whatever the camera pose is *this frame*; rotation
    /// rides on ARKit yaw continuously corrected against the compass.
    private func transitFrameUpdate(arView: ARView) {
        guard let fix = locationService?.location else { return }
        let camPos = arView.cameraTransform.translation
        let device = GeoMath.predicted(from: fix, at: Date())

        for (id, holder) in placedHolders {
            guard roomDrops[id] == nil else { continue } // AR-space anchored (ADR-025)
            guard let drop = placedDrops[id] else { continue }
            let enu = GeoMath.enuOffset(from: device, to: drop.coordinate)
            let distance = simd_length(enu)
            let bearingAR = atan2(enu.x, enu.y) - headingCorrection
            let x = camPos.x + Float(distance * sin(bearingAR))
            let z = camPos.z - Float(distance * cos(bearingAR))
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
        // RealityKit keeps rendering (and firing SceneEvents) on a frozen or
        // dead camera — render callbacks are NOT proof of session health, so
        // hold all per-frame work while interrupted/failed (Wave B review C19).
        guard mode == .gpsCompass, let arView, !isInterrupted, !sessionFailed
        else { return }
        if !sessionFrameReady,
           let frame = arView.session.currentFrame,
           frame.timestamp > sessionRunSince {
            // ADR-043 reveal signal: only a camera frame captured AFTER the
            // (re)run proves the session is live (final check F5).
            sessionFrameReady = true
        }
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

        // Feed VPS at the governor's cadence (ADR-033): every frame while
        // converging (full), maintenance rate when settled (cruise), keep-warm
        // when idle. The GARSession VPS+semantics inference is the single
        // biggest controllable heat source in the app.
        if let frame = arView.session.currentFrame {
            if now.timeIntervalSince(lastGARFeedAt) >= garFeedInterval {
                geospatial.update(with: frame)
                lastGARFeedAt = now
            }
            // ADR-037: 2 Hz person probe, only while occlusion could matter.
            if cameraVisible, !placedHolders.isEmpty {
                personSentinel.update(pixelBuffer: frame.capturedImage)
            }
        }

        // ADR-018: the matte gates per pixel on the content's metric depth, so near
        // drops protect themselves — the pass only needs to run at all when some
        // drop is far enough for any pixel to qualify. (The old all-or-nothing 40 m
        // gate disarmed occlusion entirely the moment anything came close — field
        // report 2026-07-07: content drew over every tree on the walk-up.)
        // ADR-031: run the mid-field depth model only when it can matter — some
        // drop beyond its minimum band, pedestrian world-lock (in transit the
        // LiDAR alignment sees the vehicle interior/glass), device not hot.
        if AppConfig.midFieldDepthEnabled, semanticPass != nil {
            let camPosition = arView.cameraTransform.translation
            // Neural depth is a full-tier luxury (ADR-033).
            // Wave B review C8: with the MATH-1 support bound, no fit can claim
            // beyond the LiDAR reference band × margin (~5 m today) — content
            // farther than that cannot be matted by this source, and running
            // the ANE for it is pure heat. ADR-031's 4–60 m ambition needs a
            // farther calibration reference first (Wave E: MATH-7).
            // Round 3 (counsel ARPCFG-R2-3/STATE-L4): the USE side shares the
            // SAME predicate the request side uses (`midFieldServiceable`),
            // and carries the capability term — without LiDAR scene depth no
            // fit can ever publish, so loading the ~50 MB model there was
            // pure memory and launch heat with a structurally-impossible
            // consumer.
            let useful = renderPath == .pedestrian && !thermalSerious
                && powerTier == .full
                && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
                && placedHolders.values.contains {
                    Self.midFieldServiceable(
                        distance: simd_length($0.position - camPosition)
                    )
                }
            if useful, let frame = arView.session.currentFrame {
                // Lazy first load (ADR-035): the CoreML/ANE compile is a launch
                // heat spike — pay it only when far content actually exists.
                midDepth.loadIfNeeded()
                midDepth.update(frame: frame, hz: AppConfig.midDepthHz)
            } else if !useful, midDepth.feed.hasSample {
                midDepth.feed.invalidate()
            }
        }

        // Wave C (counsel ARP-3): computed UNCONDITIONALLY so the flag can
        // fall. It used to be written only inside a `geospatial.semanticActive`
        // branch — when semantics switched off (drop closer than 55 m) with the
        // flag true, it latched forever: the Metal pass stayed attached every
        // frame (ADR-035's exact heat regression) and the SEM chip lied.
        // Derived state is computed from its inputs each tick, never written
        // inside the branch its own precondition guards.
        if semanticPass != nil {
            let camPosition = arView.cameraTransform.translation
            // Thermal guard (ADR-024) + governor gate (ADR-033): the matte's
            // compute pass runs only above idle and never while hot.
            let farMode = geospatial.semanticActive
                && !thermalSerious && powerTier > .idle
                && placedHolders.values.contains {
                    simd_length($0.position - camPosition) > AppConfig.semanticMatteTreeDistance
                }
            geospatial.semanticFeed.setEnabled(farMode)
            if farMode != semanticMatteArmed {
                semanticMatteArmed = farMode
            }
        }

        if renderPath == .transit {
            transitFrameUpdate(arView: arView)
        } else if !deferredTargets.isEmpty || !deferredVPSTransforms.isEmpty {
            drainDeferredCorrections(arView: arView)
        }

        guard !placedHolders.isEmpty else { return }
        let camPos = arView.cameraTransform.translation
        applyPerceptualCompensation(camPos: camPos)

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

    /// ADR-049 perceptual size compensation. True perspective (d⁻¹ angular decay)
    /// is geometrically exact but perceptually wrong on a phone: the optical
    /// chain — a ~50° camera field aspect-filled onto a display that subtends
    /// only ~12° at arm's length — shows *everything* at roughly a quarter of
    /// its naked-eye visual angle. The real street survives because the brain
    /// applies size constancy to familiar structure; an unfamiliar virtual
    /// object gets no such correction and reads as a miniature.
    ///
    /// Correction: content scale × clamp((d/d₀)^β, 1, cap). Apparent angle then
    /// decays as d^(β−1) — still strictly monotonic (farther is always smaller,
    /// walking closer always grows it), never billboarded, and exactly identity
    /// inside d₀, so near-field and room drops render untouched. The grounding
    /// disc tracks the compensated footprint so the size-vs-distance cue
    /// (ADR-023) stays coherent. Fireworks/beacon manage their own scale.
    /// The ADR-049 law, kept pure so the invariants (identity near, capped far,
    /// monotonic factor, and — critically — apparent angle still strictly
    /// shrinking with distance) are provable in unit tests.
    nonisolated static func perceptualFactor(atDistance distance: Float) -> Float {
        guard distance.isFinite, distance > 0 else { return 1 }
        return min(
            max(pow(distance / AppConfig.perceptualD0, AppConfig.perceptualBeta), 1),
            AppConfig.perceptualCap
        )
    }

    private func applyPerceptualCompensation(camPos: SIMD3<Float>) {
        guard AppConfig.perceptualCompensationEnabled else { return }
        for (id, content) in contentEntities {
            guard let holder = placedHolders[id], roomDrops[id] == nil,
                  let drop = placedDrops[id],
                  drop.content != .fireworks, drop.content != .beacon,
                  !liveEditingDrops.contains(id)
            else { continue }
            let distance = simd_length(holder.position - camPos)
            let factor = Self.perceptualFactor(atDistance: distance)
            let target = Float(drop.scale) * factor
            let current = content.scale.x
            // 2% hysteresis on the *rendered* scale: steps stay imperceptible
            // while avoiding per-frame transform churn, and the one check also
            // catches remote scale edits and freshly swapped entities. Exact
            // identity is always re-established inside d₀.
            guard abs(target - current) > max(current, 0.001) * 0.02
                || (factor == 1 && current != target) else { continue }
            appliedCompensation[id] = factor
            content.scale = SIMD3(repeating: target)
            if let marker = markers[id] {
                let top = content.visualBounds(relativeTo: holder).max.y
                marker.position.y = max(top, 0) + 2
            }
            if let disc = groundDiscs[id] {
                let radius = Self.groundDiscRadius(for: content, relativeTo: holder)
                disc.scale = [radius, 0.01, radius]
            }
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

            let anchorEntity = AnchorEntity(anchor: geoAnchor)
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
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.isInterrupted = true
            self.sessionFrameReady = false
            self.disarmSemanticMatte() // arui-4: the flag can't fall on its own here
            self.statusText = "Paused"
            self.metricsLog.log("ARSession interrupted (call / app switch)")
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.isInterrupted = false
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
                guard self.tickTask != nil else { return }
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
