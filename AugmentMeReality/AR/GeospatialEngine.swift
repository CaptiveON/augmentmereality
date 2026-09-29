import ARCore
import ARKit
import Combine
import CoreLocation
import RealityKit
import UIKit
import os
import simd

/// Tier C — Google ARCore Geospatial (VPS).
///
/// The camera image is matched against Google's global Street View point cloud,
/// yielding ~1–5 m position and <5° orientation accuracy wherever Street View
/// exists. Drops are pinned with **terrain anchors** (Google resolves the exact
/// ground elevation at the pinned coordinate — no more guessing altitude), and
/// **Streetscape Geometry** streams real building meshes around the viewer which
/// we install as invisible occluders, so content disappears behind actual
/// buildings — far beyond LiDAR range.
///
/// The engine is deliberately passive: the compass tier places content instantly;
/// when VPS localizes well, resolved transforms surface through `onDropTransform`
/// and the session manager glides content to its exact spot ("instant first,
/// precise later").
@MainActor
final class GeospatialEngine {
    enum State: Equatable {
        case off
        case searching
        case localized(horizontalM: Double, yawDeg: Double)
        case failed(String)
    }

    private(set) var state: State = .off
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "geospatial")

    /// Latest Scene Semantics buffers for the SilhouetteRefiner (ADR-011).
    let semanticFeed = SemanticFeed()
    /// ADR-035: Google's semantic segmentation NN runs ONLY while some content
    /// actually needs the >60 m matte (or transit). Toggled via GARSession
    /// reconfiguration; costs nothing when off.
    private(set) var semanticActive = false
    private(set) var semanticRequested = false
    private(set) var semanticSupported = false
    private var configuration: GARSessionConfiguration?
    private var workAdmission = PerceptionWorkAdmission()
    private var captureSubmission = CaptureSubmissionGate()
    private enum RuntimeOperation: String {
        case update, transform, semantics
    }
    private var runtimeFailureCounts: [RuntimeOperation: UInt64] = [:]
    private var lastRuntimeFailureLog: [RuntimeOperation: TimeInterval] = [:]
    var isAvailable: Bool { garSession != nil }
    /// If ARCore refuses a semantic disable, stop feeding it until a later
    /// policy update successfully retries that configuration. Otherwise its
    /// unusable model would keep running as a side effect of localization.
    var canUpdate: Bool {
        workAdmission.allowed && !(semanticActive && !semanticRequested)
    }

    /// Suspend asynchronous publication while retaining the warm GAR session
    /// and already installed anchors/meshes within the same camera generation.
    /// A new generation has a new world frame, so its old meshes are removed.
    func setWorkAdmission(_ allowed: Bool, generation: UInt64) {
        let previousGeneration = workAdmission.sessionGeneration
        guard workAdmission.setAllowed(allowed, generation: generation) else { return }
        semanticFeed.setWorkAdmission(allowed, generation: generation)
        requestedDrops.subtract(inFlightAnchorTokens.keys)
        inFlightAnchorTokens.removeAll()
        cancelPendingMeshCaptures()
        meshBuildsInFlight.clear()
        latestMeshTransforms.removeAll()
        meshRetryGate.clear()
        seenGeometry.replace([], token: workAdmission.token)
        if previousGeneration != generation { removeAllOccluders() }
        // A pending coverage reply from before this edge is no longer valid.
        // Reset its coordinate gate so a fresh update can issue the check again.
        lastCoverageCheck = nil
        headingErrorSample = nil
        if !allowed { setSemanticsActive(false) }
        recordSemanticBlock()
    }

    /// ADR-017: session heading error measured by VPS — the yaw difference between
    /// the AR frame and true north, from `eastUpSouthQTarget`. Compass-free, so it
    /// is immune to magnetic interference, direction-dependent bias, and pan lag.
    /// Computed against the same ARFrame the GARSession consumed (no timing skew).
    struct HeadingErrorSample {
        let radians: Double
        let yawAccuracyDegrees: Double
        let timestamp: Date
    }
    private(set) var headingErrorSample: HeadingErrorSample?

    struct DropTransformSample {
        let dropID: UUID
        let transform: simd_float4x4
        let isFirst: Bool
        let version: VPSPoseVersion
    }

    /// Ordered pose with the world-frame and anchor generation it came from.
    var onDropTransform: ((DropTransformSample) -> Void)?

    private var garSession: GARSession?
    private weak var arView: ARView?

    private struct AnchorBinding {
        let dropID: UUID
        let sessionGeneration: UInt64
        let anchorGeneration: UInt64
    }
    private var anchorBindings: [UUID: AnchorBinding] = [:]
    private var activeAnchorGeneration: [UUID: UInt64] = [:]
    private var nextAnchorGeneration: UInt64 = 0
    private var poseGeneration: UInt64 = 0
    private var poseSequence: UInt64 = 0
    private var requestedDrops: Set<UUID> = []
    private var resolvedDrops: Set<UUID> = []
    /// Live GARAnchor per drop, so an edited drop's anchor can be removed/re-made.
    private var garAnchorsByDropID: [UUID: GARAnchor] = [:]
    /// Wave B review (C2/C4/C12): terrain/rooftop resolution is an async
    /// server round-trip, and a completion that lands AFTER its drop was
    /// invalidated (live-edit re-pin, or a tracking reset that made every
    /// old-frame transform garbage) must not resurrect its anchor. Each
    /// request gets a token; a completion whose token is no longer current
    /// discards its anchor instead of registering it.
    private var inFlightAnchorTokens: [UUID: Int] = [:]
    private var anchorRequestCounter = 0

    // Streetscape building occluders
    private var occluderRoot: AnchorEntity?
    private var occluders: [UUID: ModelEntity] = [:]
    private(set) var occluderCount = 0

    var isAccuratelyLocalized: Bool {
        if case let .localized(h, yaw) = state {
            return h <= AppConfig.vpsGoodHorizontalAccuracy
                && yaw <= AppConfig.vpsGoodYawAccuracyDegrees
        }
        return false
    }

    /// Still working toward an accurate lock (ADR-033: the governor holds full
    /// power while this is true — convergence is where frame rate matters).
    var isConverging: Bool {
        switch state {
        case .off, .failed: return false
        case .searching: return true
        case .localized: return !isAccuratelyLocalized
        }
    }

    var statusText: String? {
        switch state {
        case .off:
            return nil
        case .searching:
            return "VPS searching…"
        case .localized(let h, _):
            return String(format: "VPS ±%.1f m", h)
        case .failed(let message):
            return message
        }
    }

    // MARK: - Lifecycle

    func start(arView: ARView) {
        poseGeneration &+= 1
        anchorBindings.removeAll()
        activeAnchorGeneration.removeAll()
        guard AppConfig.vpsEnabled else {
            ARBaselineMetrics.shared.setWorkload("GAR session", enabled: false)
            ARBaselineMetrics.shared.setWorkload("GAR semantics", enabled: false)
            ARBaselineMetrics.shared.event("GAR unavailable", details: "configuration absent")
            state = .off
            return
        }
        self.arView = arView
        if memoryWarningObserver == nil {
            memoryWarningObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.releaseMeshesForMemoryPressure() }
            }
        }
        do {
            let session = try GARSession(
                apiKey: AppConfig.googleGeospatialAPIKey,
                bundleIdentifier: nil
            )
            let configuration = GARSessionConfiguration()
            configuration.geospatialMode = .enabled
            configuration.streetscapeGeometryMode = .enabled
            // ADR-035: semantics start OFF — the NN is enabled on demand by
            // `setSemanticsActive` when far content or transit needs the matte.
            configuration.semanticMode = .disabled
            semanticSupported = session.isSemanticModeSupported(.enabled)
            semanticActive = false
            semanticRequested = false
            var error: NSError?
            session.setConfiguration(configuration, error: &error)
            if let error { throw error }
            self.configuration = configuration
            garSession = session
            captureSubmission.reset()
            state = .searching
            ARBaselineMetrics.shared.setWorkload("GAR semantics", enabled: false)
            ARBaselineMetrics.shared.setWorkload("GAR session", enabled: true)
            ARBaselineMetrics.shared.event("GAR session ready")
        } catch {
            ARBaselineMetrics.shared.event("GAR session start failed")
            ARBaselineMetrics.shared.setWorkload("GAR session", enabled: false)
            ARBaselineMetrics.shared.setWorkload("GAR semantics", enabled: false)
            garSession = nil
            state = .failed("VPS unavailable: \(error.localizedDescription)")
        }
    }

    /// ADR-037: Google's own gate — VPS coverage at a coordinate. `nil` = unknown.
    /// Where coverage is absent (indoors, uncovered regions), convergence sprints
    /// are pointless heat and are skipped entirely.
    private(set) var vpsCoverageAvailable: Bool?
    private var lastCoverageCheck: CLLocationCoordinate2D?

    /// Queries coverage once per ~300 m of movement (Google's recommended
    /// pattern: check availability instead of running VPS blind).
    func checkCoverage(at coordinate: CLLocationCoordinate2D) {
        guard let token = workAdmission.token, let garSession else { return }
        if let last = lastCoverageCheck {
            if let moved = GeoMath.checkedENUOffset(from: last, to: coordinate),
               simd_length(moved) <= 300 { return }
        }
        lastCoverageCheck = coordinate
        garSession.checkVPSAvailability(coordinate: coordinate) { [weak self] availability in
            guard let self, self.workAdmission.accepts(token) else { return }
            self.vpsCoverageAvailable = availability == .available
        }
    }

    /// ADR-041 precision placement: convert an AR-frame world position to a
    /// WGS84 coordinate (the inverse of anchoring). Returns nil unless VPS is
    /// localized; the accuracy lets callers gate on quality.
    func geoCoordinate(
        of worldPosition: SIMD3<Float>
    ) -> (coordinate: CLLocationCoordinate2D, horizontalAccuracy: Double)? {
        guard let garSession, case .localized(let h, _) = state else { return nil }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        do {
            let geo = try garSession.geospatialTransform(transform: transform)
            return (geo.coordinate, max(h, geo.horizontalAccuracy))
        } catch {
            recordRuntimeFailure(.transform, error: error)
            return nil
        }
    }

    /// ADR-035: toggle Google's semantic segmentation NN at runtime. GARSession
    /// accepts reconfiguration; when off the model simply doesn't run per feed.
    func setSemanticsActive(_ on: Bool) {
        semanticRequested = on && workAdmission.allowed
        let on = semanticRequested
        defer { recordSemanticBlock() }
        if !on { semanticFeed.clear() }
        guard on != semanticActive, semanticSupported,
              let garSession, let configuration else { return }
        configuration.semanticMode = on ? .enabled : .disabled
        var error: NSError?
        garSession.setConfiguration(configuration, error: &error)
        if let error {
            recordRuntimeFailure(.semantics, error: error)
            return
        }
        semanticActive = on
        ARBaselineMetrics.shared.setWorkload("GAR semantics", enabled: on)
    }

    private func recordSemanticBlock() {
        ARBaselineMetrics.shared.setWorkload("GAR blocked by semantic disable", enabled:
            semanticActive && !semanticRequested)
    }

    func stop() {
        poseGeneration &+= 1
        setWorkAdmission(false, generation: workAdmission.sessionGeneration &+ 1)
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
            self.memoryWarningObserver = nil
        }
        ARBaselineMetrics.shared.setWorkload("GAR session", enabled: false)
        ARBaselineMetrics.shared.setWorkload("GAR semantics", enabled: false)
        garSession = nil
        captureSubmission.reset()
        anchorBindings.removeAll()
        activeAnchorGeneration.removeAll()
        requestedDrops.removeAll()
        resolvedDrops.removeAll()
        garAnchorsByDropID.removeAll()
        inFlightAnchorTokens.removeAll()
        removeAllOccluders()
        if let occluderRoot { arView?.scene.removeAnchor(occluderRoot) }
        occluderRoot = nil
        seenGeometry.replace([], token: nil)
        headingErrorSample = nil
        semanticActive = false
        semanticRequested = false
        recordSemanticBlock()
        semanticSupported = false
        configuration = nil
        vpsCoverageAvailable = nil
        lastCoverageCheck = nil
        state = .off
    }

    // MARK: - Per-frame update

    /// Feed every ARKit frame. Results surface via `state`, `onDropTransform`,
    /// and the occluder entities this engine maintains in the scene.
    func update(with frame: ARFrame) {
        guard canUpdate, let token = workAdmission.token, let garSession else { return }
        guard captureSubmission.admit(frame.timestamp) else { return }
        let metrics = ARBaselineMetrics.shared
        let updatedFrame: GARFrame?
        do {
            let trace = metrics.measure("GAR update")
            defer { metrics.end(trace) }
            metrics.observe("GAR update")
            updatedFrame = try garSession.update(frame)
        } catch {
            recordRuntimeFailure(.update, error: error)
            return
        }
        guard let garFrame = updatedFrame else {
            metrics.event("GAR update missing frame")
            return
        }

        if let earth = garFrame.earth {
            updateState(earth: earth)
            updateHeadingErrorSample(earth: earth, frame: frame)
        }

        for anchor in garFrame.updatedAnchors {
            guard let binding = anchorBindings[anchor.identifier],
                  anchor.hasValidTransform else { continue }
            deliver(binding: binding, transform: anchor.transform,
                    capturedAt: frame.timestamp)
        }

        if let geometries = garFrame.streetscapeGeometries {
            syncOccluders(geometries)
        }

        if semanticActive {
            semanticFeed.update(
                labels: garFrame.semanticImage,
                confidence: garFrame.semanticConfidenceImage,
                generation: token.sessionGeneration
            )
        }
    }

    /// Keep fixed-size counters and a rate-limited error identity. SDK domain and
    /// code are enough to diagnose failures without logging keys or scene data.
    private func recordRuntimeFailure(_ operation: RuntimeOperation, error: Error) {
        let count = (runtimeFailureCounts[operation] ?? 0) &+ 1
        runtimeFailureCounts[operation] = count
        let now = ProcessInfo.processInfo.systemUptime
        guard lastRuntimeFailureLog[operation].map({ now - $0 >= 10 }) ?? true else { return }
        lastRuntimeFailureLog[operation] = now
        let failure = error as NSError
        log.error("GAR \(operation.rawValue, privacy: .public) failed: \(failure.domain, privacy: .public) code=\(failure.code) count=\(count)")
        ARBaselineMetrics.shared.event("GAR runtime failure", details:
            "operation=\(operation.rawValue) domain=\(failure.domain) code=\(failure.code) count=\(count)")
    }

    private func updateState(earth: GAREarth) {
        switch earth.earthState {
        case .enabled:
            if earth.trackingState == .tracking,
               let transform = earth.cameraGeospatialTransform {
                state = .localized(
                    horizontalM: transform.horizontalAccuracy,
                    yawDeg: transform.orientationYawAccuracy
                )
            } else {
                state = .searching
            }
        case .errorNotAuthorized:
            state = .failed("VPS: API key not authorized")
        case .errorResourceExhausted:
            state = .failed("VPS: API quota exhausted")
        default:
            state = .failed("VPS: internal error")
        }
    }

    /// True heading of the camera per VPS vs its yaw in the AR session frame; the
    /// difference is the session's north error (same quantity the compass estimator
    /// approximates, measured optically instead). Guarded against steep pitch,
    /// where a ground-plane bearing is ill-defined.
    private func updateHeadingErrorSample(earth: GAREarth, frame: ARFrame) {
        guard earth.trackingState == .tracking,
              let transform = earth.cameraGeospatialTransform,
              transform.orientationYawAccuracy <= AppConfig.vpsHeadingMaxYawAccuracyDegrees
        else { return }

        // Camera forward (-Z) in the AR session frame, projected onto the ground.
        let forwardAR = -frame.camera.transform.columns.2
        guard simd_length(SIMD2(forwardAR.x, forwardAR.z)) > 0.5 else { return }
        let yawAR = atan2(Double(forwardAR.x), Double(-forwardAR.z))

        // Same forward in East-Up-South; heading = atan2(east, north), north = -south.
        let forwardEUS = transform.eastUpSouthQTarget.act(SIMD3<Float>(0, 0, -1))
        guard simd_length(SIMD2(forwardEUS.x, forwardEUS.z)) > 0.5 else { return }
        let headingTrue = atan2(Double(forwardEUS.x), Double(-forwardEUS.z))

        let delta = headingTrue - yawAR
        headingErrorSample = HeadingErrorSample(
            radians: atan2(sin(delta), cos(delta)),
            yawAccuracyDegrees: transform.orientationYawAccuracy,
            timestamp: Date()
        )
    }

    func accepts(_ sample: DropTransformSample) -> Bool {
        guard let anchorGeneration = activeAnchorGeneration[sample.dropID] else { return false }
        return sample.version.matches(sessionGeneration: poseGeneration,
                                      anchorGeneration: anchorGeneration)
    }

    private func deliver(binding: AnchorBinding, transform: simd_float4x4,
                         capturedAt: TimeInterval) {
        guard binding.sessionGeneration == poseGeneration,
              activeAnchorGeneration[binding.dropID] == binding.anchorGeneration,
              transformIsFinite(transform), capturedAt.isFinite
        else { return }
        let isFirst = !resolvedDrops.contains(binding.dropID)
        resolvedDrops.insert(binding.dropID)
        poseSequence &+= 1
        let sample = DropTransformSample(
            dropID: binding.dropID, transform: transform, isFirst: isFirst,
            version: VPSPoseVersion(
                sessionGeneration: binding.sessionGeneration,
                anchorGeneration: binding.anchorGeneration,
                capturedAt: capturedAt, sequence: poseSequence
            )
        )
        onDropTransform?(sample)
    }

    // MARK: - Anchors

    /// Pin a drop to the terrain at its exact coordinate; Google resolves the
    /// ground elevation, `heightAboveGround` rides on top of it.
    func requestAnchor(for drop: GeoDrop, viewer: CLLocation?) {
        guard let workToken = workAdmission.token, let garSession, isAccuratelyLocalized,
              !requestedDrops.contains(drop.id) else { return }
        requestedDrops.insert(drop.id)
        nextAnchorGeneration &+= 1
        let binding = AnchorBinding(
            dropID: drop.id, sessionGeneration: poseGeneration,
            anchorGeneration: nextAnchorGeneration
        )
        activeAnchorGeneration[drop.id] = binding.anchorGeneration
        anchorRequestCounter += 1
        let token = anchorRequestCounter
        inFlightAnchorTokens[drop.id] = token

        // EUS convention: +X east, +Y up, +Z south; content front is +Z, so a
        // facing bearing β needs yaw π−β. Creator-chosen facing wins; otherwise
        // face the viewer's side.
        var rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
        if let facing = drop.facingDegrees {
            rotation = simd_quatf(angle: Float((180 - facing) * .pi / 180), axis: [0, 1, 0])
        } else if let viewer {
            let bearing = GeoMath.bearing(from: drop.coordinate, to: viewer.coordinate)
            rotation = simd_quatf(angle: Float((180 - bearing) * .pi / 180), axis: [0, 1, 0])
        }

        do {
            if drop.isRooftop {
                // ADR-042: resolved against Google's 3D building model — the
                // anchor lands ON the roof at that coordinate.
                try garSession.createAnchorOnRooftop(
                    coordinate: drop.coordinate,
                    altitudeAboveRooftop: drop.heightAboveGround,
                    eastUpSouthQAnchor: rotation
                ) { [weak self] anchor, rooftopState in
                    Task { @MainActor in
                        guard let self else { return }
                        // Stale request (invalidated or superseded): discard.
                        guard self.workAdmission.accepts(workToken),
                              self.inFlightAnchorTokens[drop.id] == token,
                              self.poseGeneration == binding.sessionGeneration,
                              self.activeAnchorGeneration[drop.id] == binding.anchorGeneration else {
                            if let anchor { garSession.remove(anchor) }
                            return
                        }
                        self.inFlightAnchorTokens[drop.id] = nil
                        guard rooftopState == .success, let anchor else {
                            self.requestedDrops.remove(drop.id) // retry later
                            return
                        }
                        self.anchorBindings[anchor.identifier] = binding
                        self.garAnchorsByDropID[drop.id] = anchor
                        if anchor.hasValidTransform {
                            self.deliver(binding: binding, transform: anchor.transform,
                                         capturedAt: ProcessInfo.processInfo.systemUptime)
                        }
                    }
                }
            } else {
                try garSession.createAnchorOnTerrain(
                    coordinate: drop.coordinate,
                    altitudeAboveTerrain: drop.heightAboveGround,
                    eastUpSouthQAnchor: rotation
                ) { [weak self] anchor, terrainState in
                    Task { @MainActor in
                        guard let self else { return }
                        // Stale request (invalidated or superseded): discard.
                        guard self.workAdmission.accepts(workToken),
                              self.inFlightAnchorTokens[drop.id] == token,
                              self.poseGeneration == binding.sessionGeneration,
                              self.activeAnchorGeneration[drop.id] == binding.anchorGeneration else {
                            if let anchor { garSession.remove(anchor) }
                            return
                        }
                        self.inFlightAnchorTokens[drop.id] = nil
                        guard terrainState == .success, let anchor else {
                            self.requestedDrops.remove(drop.id) // retry on a later tick
                            return
                        }
                        self.anchorBindings[anchor.identifier] = binding
                        self.garAnchorsByDropID[drop.id] = anchor
                        if anchor.hasValidTransform {
                            self.deliver(binding: binding, transform: anchor.transform,
                                         capturedAt: ProcessInfo.processInfo.systemUptime)
                        }
                    }
                }
            }
        } catch {
            requestedDrops.remove(drop.id)
            if activeAnchorGeneration[drop.id] == binding.anchorGeneration {
                activeAnchorGeneration[drop.id] = nil
            }
        }
    }

    /// Counsel ARP-4: after an ARKit tracking RESET the session's world frame is
    /// brand new, and every GARAnchor transform (expressed in the old frame) is
    /// garbage — applying one as a refinement glides content to a position
    /// derived from a world that no longer exists. The GARSession itself
    /// survives resets (ARCore iOS ≥ 1.38, researcher-verified — do NOT tear the
    /// engine down), but all anchors must be dropped and re-requested so they
    /// resolve in the fresh frame. `requestedDrops` must clear too: it is the
    /// re-request gate, and a stale entry deadlocks re-pinning.
    func invalidateAllAnchors() {
        poseGeneration &+= 1
        for anchor in garAnchorsByDropID.values {
            anchorBindings[anchor.identifier] = nil
            garSession?.remove(anchor)
        }
        garAnchorsByDropID.removeAll()
        anchorBindings.removeAll()
        activeAnchorGeneration.removeAll()
        requestedDrops.removeAll()
        resolvedDrops.removeAll()
        inFlightAnchorTokens.removeAll() // in-flight completions become stale
        headingErrorSample = nil
    }

    /// Forgets a drop's terrain anchor (removing it from the GARSession) so the next
    /// `requestAnchor` re-pins with fresh values — used when the creator live-edits
    /// `heightAboveGround`, which terrain anchors bake in at creation.
    func invalidateAnchor(for dropID: UUID) {
        activeAnchorGeneration[dropID] = nil
        requestedDrops.remove(dropID)
        resolvedDrops.remove(dropID)
        inFlightAnchorTokens[dropID] = nil // an in-flight completion is stale
        if let anchor = garAnchorsByDropID.removeValue(forKey: dropID) {
            anchorBindings[anchor.identifier] = nil
            garSession?.remove(anchor)
        }
    }

    // MARK: - Streetscape building occluders

    /// GAR objects and raw pointers stay on this actor. Each update copies at
    /// most a small slice into owned values; validation runs on the serial
    /// queue; RealityKit's actor-isolated async generator does the mesh build.
    /// Tickets cover capture, queueing, validation AND generation, even after a
    /// scene generation is invalidated.
    private let meshQueue = DispatchQueue(label: "streetscape-mesh", qos: .userInitiated)
    private let meshLimits = StreetscapeMeshLimits.live
    private var meshBuildsInFlight = StreetscapeBuildRegistry()
    private var meshWorkBudget = OutstandingWorkBudget(limit: StreetscapeMeshLimits.live.outstandingBuilds)
    private var meshLedger = StreetscapeMeshLedger(limits: .live)
    private struct PendingMeshCapture {
        let ticket: UUID
        let token: PerceptionWorkAdmission.Token
        let capture: StreetscapeMeshCapture
    }
    private var pendingMeshCaptures: [UUID: PendingMeshCapture] = [:]
    private var meshCaptureOrder: [UUID] = []
    private var latestMeshTransforms: [UUID: simd_float4x4] = [:]
    private var installedMeshDistances: [UUID: Float] = [:]
    private var meshRetryGate = StreetscapeMeshRetryGate()
    private var meshFailureCount: UInt64 = 0
    private var lastMeshFailureLog: TimeInterval = -.infinity
    private var memoryWarningObserver: NSObjectProtocol?
    private var meshShedUntil: TimeInterval = 0

    /// The only unchecked handoff is this small locked relevance mailbox. It
    /// holds Sendable IDs and tokens, never geometry or RealityKit resources.
    private final class SeenGeometryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        private var token: PerceptionWorkAdmission.Token?
        func replace(_ new: Set<UUID>, token: PerceptionWorkAdmission.Token?) {
            lock.lock()
            ids = new
            self.token = token
            lock.unlock()
        }
        func contains(_ id: UUID, token: PerceptionWorkAdmission.Token) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return self.token == token && ids.contains(id)
        }
    }
    private let seenGeometry = SeenGeometryBox()

    private func syncOccluders(_ geometries: [GARStreetscapeGeometry]) {
        guard let token = workAdmission.token, let arView else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= meshShedUntil else { return }
        let camPos = arView.cameraTransform.translation
        var seen: Set<UUID> = []
        var candidates: [(id: UUID, mesh: GARMesh, transform: simd_float4x4,
                          distance: Float)] = []
        for geometry in geometries where geometry.type == .building
            && geometry.trackingState == .tracking {
            let id = geometry.identifier
            let transform = geometry.meshTransform
            guard transformIsFinite(transform) else { continue }
            seen.insert(id)
            let t = transform.columns.3
            let distance = simd_length(SIMD3(t.x, t.y, t.z) - camPos)
            if let entity = occluders[id] {
                entity.setTransformMatrix(transform, relativeTo: nil)
                installedMeshDistances[id] = distance
                continue
            }
            if meshBuildsInFlight[id] != nil {
                latestMeshTransforms[id] = transform
                continue
            }
            guard meshRetryGate.allows(id, at: now) else { continue }
            candidates.append((id, geometry.mesh, transform, distance))
        }
        seenGeometry.replace(seen, token: token)
        meshRetryGate.retainOnly(seen)
        for id in Array(occluders.keys) where !seen.contains(id) { removeOccluder(id) }
        for (id, pending) in Array(pendingMeshCaptures) where !seen.contains(id) {
            retireMeshTicket(pending.ticket, id: id, token: pending.token)
            pendingMeshCaptures[id] = nil
        }
        meshCaptureOrder.removeAll { pendingMeshCaptures[$0] == nil }
        latestMeshTransforms = latestMeshTransforms.filter { seen.contains($0.key) }

        // Nearest first. The total ticket and residency limits include all old
        // jobs, so repeated GAR updates cannot create an accumulating backlog.
        for build in candidates.sorted(by: { $0.distance < $1.distance }) {
            guard let ticket = meshWorkBudget.begin() else { break }
            let id = build.id
            let source = GARStreetscapeMeshSource(build.mesh)
            var rejection = meshLedger.reserve(ticket: ticket,
                                               vertices: source.vertexCount,
                                               triangles: source.triangleCount)
            if rejection == .residentLimit {
                // A newly nearer building may replace a farther installed one.
                for farthest in installedMeshDistances.sorted(by: { $0.value > $1.value })
                    where farthest.value > build.distance {
                    removeOccluder(farthest.key)
                    rejection = meshLedger.reserve(ticket: ticket,
                                                   vertices: source.vertexCount,
                                                   triangles: source.triangleCount)
                    if rejection == nil { break }
                }
            }
            if let rejection {
                meshWorkBudget.finish(ticket)
                if rejection != .residentLimit {
                    meshRetryGate.reject(id, at: now)
                    recordMeshFailure("admission=\(String(describing: rejection))")
                }
                continue
            }
            let buildKey = StreetscapeBuildRegistry.Key(token: token, ticket: ticket)
            guard meshBuildsInFlight.begin(id: id, key: buildKey) else {
                meshLedger.finish(ticket: ticket)
                meshWorkBudget.finish(ticket)
                continue
            }
            latestMeshTransforms[id] = build.transform
            pendingMeshCaptures[id] = PendingMeshCapture(
                ticket: ticket, token: token, capture: StreetscapeMeshCapture(source: source))
            meshCaptureOrder.append(id)
        }
        var vertexAllowance = meshLimits.verticesPerUpdate
        var triangleAllowance = meshLimits.trianglesPerUpdate
        for id in meshCaptureOrder {
            guard vertexAllowance > 0 || triangleAllowance > 0 else { break }
            guard let pending = pendingMeshCaptures[id] else { continue }
            pending.capture.advance(vertices: &vertexAllowance, triangles: &triangleAllowance)
            guard let snapshot = pending.capture.snapshot() else { continue }
            pendingMeshCaptures[id] = nil // releases the SDK object on this actor
            let ticket = pending.ticket
            let token = pending.token
            let relevance = seenGeometry
            meshQueue.async { [weak self, relevance] in
                // Obsolete queued work is retired before its linear validation.
                let invalid = relevance.contains(id, token: token)
                    ? snapshot.validate() : nil
                let relevant = relevance.contains(id, token: token)
                Task { @MainActor [weak self] in
                    self?.meshValidationFinished(snapshot: relevant ? snapshot : nil,
                                                 invalid: invalid, ticket: ticket,
                                                 id: id, token: token)
                }
            }
        }
        meshCaptureOrder.removeAll { pendingMeshCaptures[$0] == nil }
        occluderCount = occluders.count
    }

    private func meshValidationFinished(snapshot: StreetscapeMeshSnapshot?,
                                        invalid: StreetscapeMeshSnapshot.Invalid?,
                                        ticket: UUID, id: UUID,
                                        token: PerceptionWorkAdmission.Token) {
        let key = StreetscapeBuildRegistry.Key(token: token, ticket: ticket)
        guard workAdmission.accepts(token), meshBuildsInFlight.accepts(id: id, key: key),
              seenGeometry.contains(id, token: token), latestMeshTransforms[id] != nil else {
            retireMeshTicket(ticket, id: id, token: token)
            return
        }
        guard let snapshot else {
            retireMeshTicket(ticket, id: id, token: token)
            return
        }
        guard invalid == nil else {
            meshRetryGate.reject(id, at: ProcessInfo.processInfo.systemUptime)
            recordMeshFailure("invalid=\(String(describing: invalid))")
            retireMeshTicket(ticket, id: id, token: token)
            return
        }
        // The installed RealityKit API marks descriptor construction and mesh
        // generation MainActor. generateAsync performs the expensive generation
        // asynchronously; its request keeps this ticket until completion.
        var descriptor = MeshDescriptor(name: "streetscape-building")
        descriptor.positions = MeshBuffer(snapshot.positions)
        descriptor.primitives = .triangles(snapshot.indices)
        let request = StreetscapeMeshGenerationDeadline.applying(
            to: MeshResource.generateAsync(from: [descriptor]))
        Task { @MainActor [weak self] in
            do {
                for try await mesh in request.values {
                    self?.meshGenerationFinished(mesh, ticket: ticket, id: id, token: token)
                    return
                }
                self?.meshGenerationFinished(nil, ticket: ticket, id: id, token: token)
            } catch {
                self?.recordMeshFailure("RealityKit generation failed: \(error.localizedDescription)")
                self?.meshGenerationFinished(nil, ticket: ticket, id: id, token: token)
            }
        }
    }

    private func meshGenerationFinished(_ mesh: MeshResource?, ticket: UUID, id: UUID,
                                        token: PerceptionWorkAdmission.Token) {
        defer { retireMeshTicket(ticket, id: id, token: token) }
        let key = StreetscapeBuildRegistry.Key(token: token, ticket: ticket)
        guard let mesh, workAdmission.accepts(token),
              meshBuildsInFlight.accepts(id: id, key: key),
              seenGeometry.contains(id, token: token), occluders[id] == nil,
              let transform = latestMeshTransforms[id], let arView else { return }
        guard meshLedger.install(ticket: ticket, id: id) else { return }
        let entity = ModelEntity(mesh: mesh, materials: [OcclusionMaterial()])
        ensureOccluderRoot(in: arView).addChild(entity)
        entity.setTransformMatrix(transform, relativeTo: nil)
        occluders[id] = entity
        let t = transform.columns.3
        installedMeshDistances[id] = simd_length(SIMD3(t.x, t.y, t.z)
            - arView.cameraTransform.translation)
        occluderCount = occluders.count
    }

    private func retireMeshTicket(_ ticket: UUID, id: UUID,
                                  token: PerceptionWorkAdmission.Token) {
        meshWorkBudget.finish(ticket)
        meshLedger.finish(ticket: ticket)
        let key = StreetscapeBuildRegistry.Key(token: token, ticket: ticket)
        if meshBuildsInFlight.retire(id: id, key: key) {
            latestMeshTransforms[id] = nil
        }
    }

    private func cancelPendingMeshCaptures() {
        for (id, pending) in pendingMeshCaptures {
            retireMeshTicket(pending.ticket, id: id, token: pending.token)
        }
        pendingMeshCaptures.removeAll()
        meshCaptureOrder.removeAll()
    }

    private func removeOccluder(_ id: UUID) {
        occluders.removeValue(forKey: id)?.removeFromParent()
        installedMeshDistances[id] = nil
        meshLedger.remove(id: id)
        occluderCount = occluders.count
    }

    private func removeAllOccluders() {
        for entity in occluders.values { entity.removeFromParent() }
        occluders.removeAll()
        installedMeshDistances.removeAll()
        meshLedger.removeAllInstalled()
        occluderCount = 0
    }

    private func releaseMeshesForMemoryPressure() {
        // The cooldown prevents the next GAR frame from immediately repopulating
        // the released meshes. Old validation/generation tickets retire normally.
        meshShedUntil = ProcessInfo.processInfo.systemUptime + 30
        cancelPendingMeshCaptures()
        meshBuildsInFlight.clear()
        latestMeshTransforms.removeAll()
        seenGeometry.replace([], token: workAdmission.token)
        removeAllOccluders()
        ARBaselineMetrics.shared.event("Streetscape meshes shed for memory pressure")
    }

    private func transformIsFinite(_ transform: simd_float4x4) -> Bool {
        for column in 0..<4 {
            let value = transform[column]
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite else {
                return false
            }
        }
        return true
    }

    private func recordMeshFailure(_ reason: String) {
        meshFailureCount &+= 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMeshFailureLog >= 10 else { return }
        lastMeshFailureLog = now
        log.error("Streetscape mesh skipped: \(reason, privacy: .public); total=\(self.meshFailureCount)")
        ARBaselineMetrics.shared.event("Streetscape mesh skipped", details: reason)
    }

    /// Transit Mode (§6.3): streetscape occluders live in the VIO frame, which is
    /// untrusted in a moving vehicle — hide them rather than occlude wrongly.
    func setOccludersHidden(_ hidden: Bool) {
        occluderRoot?.isEnabled = !hidden
    }

    private func ensureOccluderRoot(in arView: ARView) -> AnchorEntity {
        if let occluderRoot { return occluderRoot }
        let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        arView.scene.addAnchor(root)
        occluderRoot = root
        return root
    }

}
