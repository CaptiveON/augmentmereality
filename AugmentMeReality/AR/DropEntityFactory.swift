import Combine
import RealityKit
import UIKit
import os

/// Builds RealityKit entities for each drop type, fully procedurally — no 3D asset
/// files needed. The returned entity's origin sits at ground level under the content;
/// the placement engine positions and orients it in the world.
enum DropEntityFactory {
    /// ADR-020: natural mode is pure lit PBR — ARKit's estimated environment light
    /// shades it like a real object (the depth cues that sell presence). Full-bright
    /// mode adds a strong emissive so content glows regardless of scene light
    /// (night, backlit) — chosen by the viewer via the HUD toggle.
    private static func contentMaterial(
        _ color: UIColor, fullBright: Bool
    ) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.4
        material.metallic = 0.0
        if fullBright {
            material.emissiveColor = .init(color: color)
            material.emissiveIntensity = 1.0
        }
        return material
    }

    // MARK: - Animated USDZ assets (ADR-021; loading architecture ADR-032)
    //
    // HARD RULE after the launch-hang audit (2026-07-08): USDZ decoding NEVER
    // happens on the main actor. ~130 MB of bundled scenes decoded there starved
    // the main thread for tens of seconds after launch — the app read as hung and
    // the user force-restarted it. All decodes run on a background thread
    // (RealityKit's synchronous loaders are callable from any thread; entities
    // only touch the scene on the main actor afterwards). Anything that needs a
    // not-yet-loaded model gets an instant placeholder and is swapped in place
    // via `onAssetLoaded` when the decode lands.

    /// Names (no extension) of every .usdz bundled with the app, cached — the
    /// bundle can't change at runtime, and this is read per HUD render.
    @MainActor static var bundledAnimatedAssets: [String] {
        if let cachedAssetNames { return cachedAssetNames }
        let names = (Bundle.main.urls(forResourcesWithExtension: "usdz", subdirectory: nil) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        cachedAssetNames = names
        return names
    }
    @MainActor private static var cachedAssetNames: [String]?

    /// Loaded template entities, cloned per placement. USDZ decode is 100s of ms
    /// to seconds — paid once, always off-main.
    @MainActor private static var animatedTemplates: [String: Entity] = [:]
    /// Assets currently decoding, so preload and on-demand requests never race.
    @MainActor private static var loadingAssets: Set<String> = []
    /// Counts running publishers, excluding assets that are only queued for preload.
    @MainActor private static var activeDecodes = 0
    /// Wave C (counsel SWE-6): assets whose decode FAILED. Without this
    /// negative cache, a corrupt USDZ spun forever: the load callback fired as
    /// if it succeeded, the manager rebuilt the entity, the rebuild re-requested
    /// the same failing decode — CPU pegged, placeholder flickering, no log.
    /// A failed name is never re-decoded this session; the bundle can't heal.
    @MainActor private static var failedAssets: Set<String> = []
    /// Fired on the main actor when a decode FINISHES; `success` tells the
    /// session manager whether there is a template worth swapping in (SWE-6:
    /// a callback that can't distinguish success from failure is not a
    /// usable contract).
    @MainActor static var onAssetLoaded: ((String, _ success: Bool) -> Void)?

    /// Round 4 (counsel arui-1): failure state is QUERYABLE at render time —
    /// a subscriber that arrives after the decode (the session manager
    /// attaches on camera intent; preload runs at launch) still sees truth.
    @MainActor static func isAssetFailed(_ name: String) -> Bool {
        failedAssets.contains(name)
    }
    @MainActor static func isAssetReady(_ name: String) -> Bool {
        animatedTemplates[name] != nil
    }

    private static let log = Logger(
        subsystem: "com.adnan.augmentmereality", category: "assets"
    )

    /// One asset decode, never blocking. ADR-047 (second hang field report):
    /// the iOS-18 async `Entity(named:)` initializer is itself @MainActor —
    /// its decode work can run in LONG main-actor slices, which was the
    /// residual hang. The Combine `loadAsync` pipeline is the one API whose
    /// decode genuinely runs on RealityKit's background queue, so it is now
    /// the ONLY path (deprecated on iOS 18+, deliberately — see ADR-047;
    /// stall-measured on device by `AssetLoadStallTests`).
    @MainActor static func decodeTemplate(_ name: String) async -> Entity? {
        let delay = ARBaselineExperiment.current.delay(for: name)
        if delay > 0 {
            ARBaselineMetrics.shared.event("Asset fixture delay", details: "asset=\(name) seconds=\(delay)")
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return nil }
        }
        let metrics = ARBaselineMetrics.shared
        // RealityKit owns the decode queue. This is publisher completion latency,
        // including suspension/queueing, rather than CPU execution time.
        let trace = metrics.measure("Asset decode latency")
        activeDecodes += 1
        metrics.setWorkload("Asset decode", enabled: true)
        metrics.event("Asset decode started", details: name)
        defer {
            metrics.end(trace)
            activeDecodes -= 1
            metrics.setWorkload("Asset decode", enabled: activeDecodes > 0)
        }
        return await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            var loaded: Entity?
            cancellable = Entity.loadAsync(named: name, in: .main)
                .sink(
                    receiveCompletion: { completion in
                        // Wave C SWE-6: the failure used to be dropped on the
                        // floor — the one diagnostic for a corrupt/unsupported
                        // asset never existed.
                        if case .failure(let error) = completion {
                            log.error("USDZ decode failed for \(name): \(error.localizedDescription)")
                            metrics.event("Asset decode failed", details: name)
                        }
                        if loaded != nil {
                            metrics.event("Asset decoded", details: name)
                        }
                        continuation.resume(returning: loaded)
                        cancellable?.cancel()
                        cancellable = nil
                    },
                    receiveValue: { entity in
                        loaded = entity
                    }
                )
        }
    }

    /// Warm the cache at app start: sequential (parallel decode of 100+ MB would
    /// spike memory), smallest files first so most models become available
    /// quickly. ADR-047: assets over the pipeline budget (heavy dev scans) are
    /// EXCLUDED from auto-preload — they decode on demand behind a placeholder,
    /// never as an ambush during the launch window.
    @MainActor static func preloadAnimatedAssets() {
        guard ARBaselineExperiment.current.allows(.assetPreload) else { return }
        let queue = bundledAnimatedAssets
            .filter { animatedTemplates[$0] == nil && !loadingAssets.contains($0) }
            .filter { assetFileSize($0) <= AppConfig.assetPreloadMaxBytes }
            .sorted { assetFileSize($0) < assetFileSize($1) }
        guard !queue.isEmpty else { return }
        loadingAssets.formUnion(queue)
        Task { @MainActor in
            for name in queue {
                let entity = await decodeTemplate(name)
                loadingAssets.remove(name)
                if let entity, animatedTemplates[name] == nil {
                    animatedTemplates[name] = entity
                    ARBaselineMetrics.shared.event("Asset cache ready", details: name)
                } else if entity == nil {
                    failedAssets.insert(name) // SWE-6: never re-decode a dud
                }
                onAssetLoaded?(name, entity != nil)
            }
        }
    }

    /// On-demand decode for one asset the user is actively waiting on (runs
    /// alongside the preload; `loadingAssets` prevents double decodes and
    /// `failedAssets` prevents the SWE-6 retry loop on a broken file).
    @MainActor static func requestAsset(_ name: String) {
        guard animatedTemplates[name] == nil,
              !loadingAssets.contains(name),
              !failedAssets.contains(name) else { return }
        loadingAssets.insert(name)
        Task { @MainActor in
            let entity = await decodeTemplate(name)
            loadingAssets.remove(name)
            if let entity, animatedTemplates[name] == nil {
                animatedTemplates[name] = entity
                ARBaselineMetrics.shared.event("Asset cache ready", details: name)
            } else if entity == nil {
                failedAssets.insert(name)
            }
            onAssetLoaded?(name, entity != nil)
        }
    }

    @MainActor private static func assetFileSize(_ name: String) -> Int {
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz") else {
            return .max
        }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
    }

    /// Recursively starts every animation the model ships with, looping forever.
    @MainActor static func startAnimations(on entity: Entity) {
        for animation in entity.availableAnimations {
            entity.playAnimation(animation.repeat())
        }
        for child in entity.children {
            startAnimations(on: child)
        }
    }

    @MainActor static func makeEntity(for drop: GeoDrop, fullBright: Bool) -> Entity {
        let color = drop.uiColor
        let root: Entity
        switch drop.content {
        case .text3D:
            root = text(
                drop.message.isEmpty ? "🎉" : drop.message,
                color: color,
                fullBright: fullBright
            )
        case .balloons:
            root = balloons(color: color, fullBright: fullBright)
        case .gift:
            root = gift(color: color, fullBright: fullBright)
        case .heart:
            root = heart(color: color, fullBright: fullBright)
        case .beacon:
            root = beacon(color: color)
        case .animated:
            root = animatedModel(named: drop.assetName, color: color, fullBright: fullBright)
        case .fireworks:
            root = fireworks(color: color)
        }

        // Caption floating above non-text content ("From Adnan ❤️").
        if drop.content != .text3D, !drop.message.isEmpty {
            let caption = text(drop.message, color: .white, fullBright: fullBright)
            caption.scale = SIMD3(repeating: 0.35)
            caption.position.y = 1.6
            root.addChild(caption)
        }

        root.scale *= SIMD3(repeating: Float(drop.scale))
        return root
    }

    // MARK: - Builders (all sized ~1 m at scale 1)

    /// Clones a bundled USDZ template, normalized to the app's ~1 m-at-scale-1
    /// convention with its base at y = 0. Materials stay as authored (the
    /// Natural/Bright toggle doesn't re-skin baked USDZ materials). If the
    /// template isn't decoded yet, this NEVER blocks (ADR-032 hang audit):
    /// it kicks a background decode and returns an instant placeholder orb;
    /// the session manager swaps in the real model via `onAssetLoaded`.
    @MainActor private static func animatedModel(
        named assetName: String?, color: UIColor, fullBright: Bool
    ) -> Entity {
        guard let assetName else {
            return text("3D?", color: color, fullBright: fullBright)
        }
        // Counsel round 2 (C19): a FAILED asset renders the explicit "3D?"
        // marker, not the loading orb — and must NOT re-request the decode
        // (that re-request was the SWE-6 infinite loop).
        guard !failedAssets.contains(assetName) else {
            return text("3D?", color: color, fullBright: fullBright)
        }
        guard let template = animatedTemplates[assetName] else {
            requestAsset(assetName)
            return loadingPlaceholder(color: color)
        }
        let model = template.clone(recursive: true)

        // Assets come in arbitrary units (cm/m/mm) — normalize the largest
        // dimension to 1 m so the composer's size slider means the same thing
        // for every drop type, then rest the base on the origin.
        let bounds = model.visualBounds(relativeTo: nil)
        let maxExtent = bounds.extents.max()
        if maxExtent > 0.0001 {
            model.scale *= SIMD3(repeating: 1.0 / maxExtent)
        }
        let scaled = model.visualBounds(relativeTo: nil)
        model.position = [-scaled.center.x, -scaled.min.y, -scaled.center.z]

        let root = Entity()
        root.addChild(model)
        return root
    }

    /// Extruded 3D text, origin centered horizontally with the baseline at y = 0.
    private static func text(_ string: String, color: UIColor, fullBright: Bool) -> Entity {
        func makeMesh(_ value: String) -> MeshResource {
            MeshResource.generateText(
                value,
                extrusionDepth: 0.12,
                font: .systemFont(ofSize: 0.6, weight: .heavy),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byWordWrapping
            )
        }
        var mesh = makeMesh(string)
        if mesh.bounds.extents.x < 0.001 {
            // Emoji are color bitmap glyphs with no vector outlines — an emoji-only
            // message extrudes to an empty (invisible) mesh. Show something instead.
            mesh = makeMesh("SURPRISE!")
        }
        let material = contentMaterial(color, fullBright: fullBright)
        let model = ModelEntity(mesh: mesh, materials: [material])
        let bounds = mesh.bounds
        model.position = [-bounds.center.x, -bounds.min.y, -bounds.center.z]
        let root = Entity()
        root.addChild(model)
        return root
    }

    /// Instant stand-in while a model decodes in the background: a small glowing
    /// orb at the drop's spot (never an empty spot — killer #1). Replaced in
    /// place the moment the decode lands.
    @MainActor private static func loadingPlaceholder(color: UIColor) -> Entity {
        let root = Entity()
        let orb = ModelEntity(
            mesh: .generateSphere(radius: 0.15),
            materials: [UnlitMaterial(color: color)]
        )
        orb.position = [0, 0.15, 0]
        root.addChild(orb)
        return root
    }

    private static func balloons(color: UIColor, fullBright: Bool) -> Entity {
        let root = Entity()
        let offsets: [SIMD3<Float>] = [
            [0, 0.95, 0],
            [-0.36, 0.78, 0.12],
            [0.36, 0.84, -0.10],
            [-0.18, 1.08, -0.16],
            [0.20, 1.12, 0.18],
        ]
        let balloonMesh = MeshResource.generateSphere(radius: 0.22)
        let balloonMaterial = contentMaterial(color, fullBright: fullBright)
        let stringMesh = MeshResource.generateBox(size: [0.008, 0.7, 0.008])
        let stringMaterial = UnlitMaterial(color: .white)

        for offset in offsets {
            let balloon = ModelEntity(mesh: balloonMesh, materials: [balloonMaterial])
            balloon.position = offset
            balloon.scale = [1, 1.2, 1]
            let string = ModelEntity(mesh: stringMesh, materials: [stringMaterial])
            string.position = [offset.x, offset.y - 0.6, offset.z]
            root.addChild(balloon)
            root.addChild(string)
        }
        return root
    }

    private static func gift(color: UIColor, fullBright: Bool) -> Entity {
        let root = Entity()
        let boxMaterial = contentMaterial(color, fullBright: fullBright)
        let ribbonMaterial = contentMaterial(
            UIColor(hex: "#FFD60A") ?? .yellow, fullBright: fullBright
        )

        let box = ModelEntity(
            mesh: .generateBox(size: [0.8, 0.55, 0.55], cornerRadius: 0.02),
            materials: [boxMaterial]
        )
        box.position = [0, 0.28, 0]

        let ribbonAcross = ModelEntity(
            mesh: .generateBox(size: [0.82, 0.57, 0.12]),
            materials: [ribbonMaterial]
        )
        ribbonAcross.position = [0, 0.28, 0]

        let ribbonAlong = ModelEntity(
            mesh: .generateBox(size: [0.12, 0.57, 0.57]),
            materials: [ribbonMaterial]
        )
        ribbonAlong.position = [0, 0.28, 0]

        let bowLeft = ModelEntity(mesh: .generateSphere(radius: 0.09), materials: [ribbonMaterial])
        bowLeft.position = [-0.08, 0.62, 0]
        let bowRight = ModelEntity(mesh: .generateSphere(radius: 0.09), materials: [ribbonMaterial])
        bowRight.position = [0.08, 0.62, 0]

        [box, ribbonAcross, ribbonAlong, bowLeft, bowRight].forEach { root.addChild($0) }
        return root
    }

    /// Valentine heart from a 45°-rotated box (the point) plus two sphere lobes.
    private static func heart(color: UIColor, fullBright: Bool) -> Entity {
        let root = Entity()
        let material = contentMaterial(color, fullBright: fullBright)

        let diamond = ModelEntity(
            mesh: .generateBox(size: [0.62, 0.62, 0.4], cornerRadius: 0.03),
            materials: [material]
        )
        diamond.orientation = simd_quatf(angle: .pi / 4, axis: [0, 0, 1])
        diamond.position = [0, 0.45, 0]

        let lobeMesh = MeshResource.generateSphere(radius: 0.23)
        let leftLobe = ModelEntity(mesh: lobeMesh, materials: [material])
        leftLobe.position = [-0.22, 0.68, 0]
        leftLobe.scale = [1, 1, 0.88]
        let rightLobe = ModelEntity(mesh: lobeMesh, materials: [material])
        rightLobe.position = [0.22, 0.68, 0]
        rightLobe.scale = [1, 1, 0.88]

        [diamond, leftLobe, rightLobe].forEach { root.addChild($0) }
        return root
    }

    /// ADR-046: fireworks show — a small dark mortar base (so there's something
    /// physical at the spot by day) with the particle choreography above it.
    /// Pre-iOS-18 devices get the glowing base only (particles unavailable).
    @MainActor private static func fireworks(color: UIColor) -> Entity {
        let root = Entity()
        var baseMaterial = PhysicallyBasedMaterial()
        baseMaterial.baseColor = .init(tint: UIColor(white: 0.12, alpha: 1))
        baseMaterial.roughness = 0.6
        let base = ModelEntity(
            mesh: .generateBox(size: [0.34, 0.16, 0.34], cornerRadius: 0.04),
            materials: [baseMaterial]
        )
        base.position = [0, 0.08, 0]
        root.addChild(base)
        let rim = ModelEntity(
            mesh: .generateBox(size: [0.36, 0.02, 0.36], cornerRadius: 0.01),
            materials: [UnlitMaterial(color: color)]
        )
        rim.position = [0, 0.17, 0]
        root.addChild(rim)
        if #available(iOS 18.0, *) {
            let show = DropEffects.fireworksShow(color: color)
            show.position = [0, 0.2, 0]
            root.addChild(show)
        }
        return root
    }

    /// Tall unlit column + orb, visible from far away regardless of lighting.
    private static func beacon(color: UIColor) -> Entity {
        let root = Entity()
        let material = UnlitMaterial(color: color)

        let column = ModelEntity(
            mesh: .generateBox(size: [0.09, 4, 0.09], cornerRadius: 0.02),
            materials: [material]
        )
        column.position = [0, 2, 0]

        let orb = ModelEntity(mesh: .generateSphere(radius: 0.35), materials: [material])
        orb.position = [0, 4.2, 0]

        [column, orb].forEach { root.addChild($0) }
        return root
    }
}
