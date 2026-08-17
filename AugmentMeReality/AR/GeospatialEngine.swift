import ARCore
import ARKit
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
    private var semanticSupported = false
    private var configuration: GARSessionConfiguration?

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

    /// (drop id, world transform, first resolution?) — fired on the main actor.
    var onDropTransform: ((UUID, simd_float4x4, Bool) -> Void)?

    private var garSession: GARSession?
    private weak var arView: ARView?

    private var anchorIDToDropID: [UUID: UUID] = [:]
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
        guard AppConfig.vpsEnabled else {
            state = .off
            return
        }
        self.arView = arView
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
            var error: NSError?
            session.setConfiguration(configuration, error: &error)
            if let error { throw error }
            self.configuration = configuration
            garSession = session
            state = .searching
        } catch {
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
        guard let garSession else { return }
        if let last = lastCoverageCheck {
            let moved = GeoMath.enuOffset(from: last, to: coordinate)
            guard simd_length(moved) > 300 else { return }
        }
        lastCoverageCheck = coordinate
        garSession.checkVPSAvailability(coordinate: coordinate) { [weak self] availability in
            self?.vpsCoverageAvailable = availability == .available
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
        guard let geo = try? garSession.geospatialTransform(transform: transform) else {
            return nil
        }
        return (geo.coordinate, max(h, geo.horizontalAccuracy))
    }

    /// ADR-035: toggle Google's semantic segmentation NN at runtime. GARSession
    /// accepts reconfiguration; when off the model simply doesn't run per feed.
    func setSemanticsActive(_ on: Bool) {
        guard on != semanticActive, semanticSupported,
              let garSession, let configuration else { return }
        configuration.semanticMode = on ? .enabled : .disabled
        var error: NSError?
        garSession.setConfiguration(configuration, error: &error)
        guard error == nil else { return }
        semanticActive = on
        if !on {
            semanticFeed.update(labels: nil, confidence: nil)
        }
    }

    func stop() {
        garSession = nil
        anchorIDToDropID.removeAll()
        requestedDrops.removeAll()
        resolvedDrops.removeAll()
        garAnchorsByDropID.removeAll()
        inFlightAnchorTokens.removeAll()
        if let occluderRoot {
            arView?.scene.removeAnchor(occluderRoot)
        }
        occluderRoot = nil
        occluders.removeAll()
        occluderCount = 0
        // Round 2 (counsel STATE-8): the build pipeline dies with the engine —
        // in-flight landings see an empty seen-set and self-discard.
        meshBuildsInFlight.removeAll()
        seenGeometry.replace([])
        headingErrorSample = nil
        semanticActive = false
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
        guard let garSession else { return }
        guard let garFrame = try? garSession.update(frame) else { return }

        if let earth = garFrame.earth {
            updateState(earth: earth)
            updateHeadingErrorSample(earth: earth, frame: frame)
        }

        for anchor in garFrame.updatedAnchors {
            guard let dropID = anchorIDToDropID[anchor.identifier],
                  anchor.hasValidTransform else { continue }
            deliver(dropID: dropID, transform: anchor.transform)
        }

        if let geometries = garFrame.streetscapeGeometries {
            syncOccluders(geometries)
        }

        if semanticActive {
            semanticFeed.update(
                labels: garFrame.semanticImage,
                confidence: garFrame.semanticConfidenceImage
            )
        }
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

    private func deliver(dropID: UUID, transform: simd_float4x4) {
        let isFirst = !resolvedDrops.contains(dropID)
        resolvedDrops.insert(dropID)
        onDropTransform?(dropID, transform, isFirst)
    }

    // MARK: - Anchors

    /// Pin a drop to the terrain at its exact coordinate; Google resolves the
    /// ground elevation, `heightAboveGround` rides on top of it.
    func requestAnchor(for drop: GeoDrop, viewer: CLLocation?) {
        guard let garSession, isAccuratelyLocalized,
              !requestedDrops.contains(drop.id) else { return }
        requestedDrops.insert(drop.id)
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
                        guard self.inFlightAnchorTokens[drop.id] == token else {
                            if let anchor { self.garSession?.remove(anchor) }
                            return
                        }
                        self.inFlightAnchorTokens[drop.id] = nil
                        guard rooftopState == .success, let anchor else {
                            self.requestedDrops.remove(drop.id) // retry later
                            return
                        }
                        self.anchorIDToDropID[anchor.identifier] = drop.id
                        self.garAnchorsByDropID[drop.id] = anchor
                        if anchor.hasValidTransform {
                            self.deliver(dropID: drop.id, transform: anchor.transform)
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
                        guard self.inFlightAnchorTokens[drop.id] == token else {
                            if let anchor { self.garSession?.remove(anchor) }
                            return
                        }
                        self.inFlightAnchorTokens[drop.id] = nil
                        guard terrainState == .success, let anchor else {
                            self.requestedDrops.remove(drop.id) // retry on a later tick
                            return
                        }
                        self.anchorIDToDropID[anchor.identifier] = drop.id
                        self.garAnchorsByDropID[drop.id] = anchor
                        if anchor.hasValidTransform {
                            self.deliver(dropID: drop.id, transform: anchor.transform)
                        }
                    }
                }
            }
        } catch {
            requestedDrops.remove(drop.id)
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
        for anchor in garAnchorsByDropID.values {
            anchorIDToDropID[anchor.identifier] = nil
            garSession?.remove(anchor)
        }
        garAnchorsByDropID.removeAll()
        requestedDrops.removeAll()
        resolvedDrops.removeAll()
        inFlightAnchorTokens.removeAll() // in-flight completions become stale
        headingErrorSample = nil
    }

    /// Forgets a drop's terrain anchor (removing it from the GARSession) so the next
    /// `requestAnchor` re-pins with fresh values — used when the creator live-edits
    /// `heightAboveGround`, which terrain anchors bake in at creation.
    func invalidateAnchor(for dropID: UUID) {
        requestedDrops.remove(dropID)
        resolvedDrops.remove(dropID)
        inFlightAnchorTokens[dropID] = nil // an in-flight completion is stale
        if let anchor = garAnchorsByDropID.removeValue(forKey: dropID) {
            anchorIDToDropID[anchor.identifier] = nil
            garSession?.remove(anchor)
        }
    }

    // MARK: - Streetscape building occluders

    /// Wave D (counsel ARP-7): mesh construction runs OFF the main actor. The
    /// old path copied every vertex/triangle in a scalar loop and called the
    /// synchronous `MeshResource.generate` inside the per-frame GAR update —
    /// a dozen streamed buildings on one corner turn = tens-to-hundreds of ms
    /// of main-thread stall exactly when far occlusion should engage (the
    /// main-thread class ADR-032 banned for USDZ, resurrected for buildings).
    private let meshQueue = DispatchQueue(label: "streetscape-mesh", qos: .userInitiated)
    private var meshBuildsInFlight: Set<UUID> = []
    /// Round 2 (counsel STATE-8): geometry ids present in the LATEST update,
    /// readable from the mesh queue — the relevance check runs BEFORE the
    /// expensive extraction, so a departed building costs nothing.
    private final class SeenGeometryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        func replace(_ new: Set<UUID>) { lock.lock(); ids = new; lock.unlock() }
        func contains(_ id: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return ids.contains(id)
        }
    }
    private let seenGeometry = SeenGeometryBox()
    /// Round 2 (counsel STATE-8): builds admitted per sync pass — a corner
    /// turn streaming a dense block queues the NEAREST few; the rest re-offer
    /// on later frames instead of pinning N vertex buffers in a backlog.
    private static let meshBuildBudgetPerPass = 8

    private func syncOccluders(_ geometries: [GARStreetscapeGeometry]) {
        guard let arView else { return }
        let camPos = arView.cameraTransform.translation
        var seen: Set<UUID> = []
        var pending: [(geometry: GARStreetscapeGeometry, id: UUID, distance: Float)] = []
        for geometry in geometries where geometry.type == .building {
            let id = geometry.identifier
            seen.insert(id)
            if let entity = occluders[id] {
                entity.setTransformMatrix(geometry.meshTransform, relativeTo: nil)
                continue
            }
            guard !meshBuildsInFlight.contains(id) else { continue }
            let t = geometry.meshTransform.columns.3
            pending.append((geometry, id, simd_length(SIMD3(t.x, t.y, t.z) - camPos)))
        }
        seenGeometry.replace(seen)
        // Nearest first — the buildings most likely to occlude content now.
        for build in pending.sorted(by: { $0.distance < $1.distance })
            .prefix(Self.meshBuildBudgetPerPass) {
            let id = build.id
            let geometry = build.geometry
            meshBuildsInFlight.insert(id)
            // The GARStreetscapeGeometry is retained by the closure, keeping
            // its vertex buffers valid for the background extraction.
            meshQueue.async { [weak self, seenGeometry] in
                // STATE-8: relevance BEFORE extraction — a building that
                // streamed out while queued costs zero mesh work.
                guard seenGeometry.contains(id) else {
                    Task { @MainActor [weak self] in
                        self?.meshBuildsInFlight.remove(id)
                    }
                    return
                }
                let descriptor = Self.makeMeshDescriptor(from: geometry.mesh)
                var mesh: MeshResource?
                if let descriptor {
                    // ARP-7: a malformed geometry is a DIAGNOSTIC (logged on
                    // the main hop below), never a silently missing occluder.
                    mesh = try? MeshResource.generate(from: [descriptor])
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.meshBuildsInFlight.remove(id)
                    guard let mesh else {
                        self.log.error("Streetscape mesh generate failed for \(id) — occluder skipped")
                        return
                    }
                    guard self.occluders[id] == nil,
                          self.seenGeometry.contains(id),
                          let arView = self.arView else { return }
                    let entity = ModelEntity(mesh: mesh, materials: [OcclusionMaterial()])
                    self.ensureOccluderRoot(in: arView).addChild(entity)
                    entity.setTransformMatrix(geometry.meshTransform, relativeTo: nil)
                    self.occluders[id] = entity
                    self.occluderCount = self.occluders.count
                }
            }
        }
        for (id, entity) in occluders where !seen.contains(id) {
            entity.removeFromParent()
            occluders[id] = nil
        }
        occluderCount = occluders.count
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

    /// Pure extraction — runs on `meshQueue`, never the main actor (ARP-7).
    private nonisolated static func makeMeshDescriptor(from mesh: GARMesh) -> MeshDescriptor? {
        let vertexCount = Int(mesh.vertexCount)
        guard vertexCount > 0 else { return nil }
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(vertexCount)
        for index in 0..<vertexCount {
            let vertex = mesh.vertices[index]
            positions.append(SIMD3(vertex.x, vertex.y, vertex.z))
        }

        let triangleCount = Int(mesh.triangleCount)
        var indices = [UInt32]()
        indices.reserveCapacity(triangleCount * 3)
        for index in 0..<triangleCount {
            let triangle = mesh.triangles[index]
            indices.append(triangle.indices.0)
            indices.append(triangle.indices.1)
            indices.append(triangle.indices.2)
        }

        var descriptor = MeshDescriptor(name: "streetscape-building")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }
}
