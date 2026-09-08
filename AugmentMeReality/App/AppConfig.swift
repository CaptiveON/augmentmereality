import CoreLocation

enum AppConfig {
    /// Wave 3: flip to true AFTER enabling the iCloud → CloudKit capability in
    /// Signing & Capabilities (requires a paid Apple Developer team). See README.
    /// Superseded by Firebase (ADR-039) — kept only as a historical stopgap.
    static let cloudKitEnabled = false

    /// Wave 6.1 (ADR-039): Firebase lights up when its config file exists.
    /// `GoogleService-Info.plist` comes from the Firebase console (see README)
    /// and lives in `Support/` next to Secrets.plist, gitignored. Absent file =
    /// the app runs fully local, exactly as before.
    static let firebaseConfigured: Bool =
        Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil

    /// Must match the container chosen when enabling the iCloud capability.
    static let cloudKitContainerID = "iCloud.com.adnan.augmentmereality"

    /// Wave 4: re-enable Apple geo anchors only together with a localization-timeout
    /// fallback. Geo localization can fail indefinitely (e.g. at night), and switching
    /// to it must never blank the experience — compass placement is the reliable path.
    static let appleGeoAnchorsEnabled = false

    /// Wave 4 — Google ARCore Geospatial (VPS): street-accurate (~1–5 m) placement +
    /// building-mesh occlusion, worldwide where Street View exists.
    ///
    /// The key lives in `Support/Secrets.plist` (gitignored — copy
    /// `Secrets.sample.plist` and paste a key from a Google Cloud project with the
    /// "ARCore API" enabled; see README). Missing file/key = VPS disabled; the app
    /// runs pure compass mode.
    static let googleGeospatialAPIKey: String = {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let secrets = plist as? [String: Any]
        else { return "" }
        return secrets["GoogleGeospatialAPIKey"] as? String ?? ""
    }()

    static var vpsEnabled: Bool {
        !googleGeospatialAPIKey.isEmpty && ARBaselineExperiment.current.allows(.localization)
    }

    /// VPS localization must be at least this good before we trust it to own
    /// content placement (meters horizontal / degrees yaw). Yaw is the lateral
    /// killer: sin(σ)·distance is sideways error, so 8° already means ±14 m at
    /// 100 m — anchors created looser than this visibly slide as VPS refines.
    static let vpsGoodHorizontalAccuracy = 10.0
    static let vpsGoodYawAccuracyDegrees = 8.0

    /// ADR-017: VPS yaw (eastUpSouthQTarget) replaces the compass as heading
    /// authority when its accuracy is at or below this (degrees). The compass is
    /// direction-dependent and lags on pans; VPS yaw is neither.
    static let vpsHeadingMaxYawAccuracyDegrees = 20.0

    /// ADR-017: compass samples taken while the camera pans faster than this are
    /// rejected — CLHeading lags the physical rotation, so the compass-vs-AR-yaw
    /// delta measured mid-pan is garbage that used to drag placements sideways.
    static let compassMaxPanRateDegreesPerSecond = 15.0

    /// ADR-018 semantic matte v2 (per-pixel): a pixel labeled tree occludes
    /// content that is deeper than this at that pixel (meters). Trees rarely sit
    /// immediately behind pinned content, so this can be aggressive.
    static let semanticMatteTreeDistance: Float = 15

    /// ADR-018: buildings/structures occlude content deeper than this (meters).
    /// Kept conservative so the hero case — text floating in front of a friend's
    /// house — is never eaten by the facade behind it.
    static let semanticMatteBuildingDistance: Float = 35

    /// Renders the matte as a red tint instead of camera restore — field tool to
    /// verify the display-transform mapping and label alignment on device.
    static let semanticMatteDebugTint = false

    /// ADR-030: custom person occlusion. When true, the session requests the
    /// stencil-only `.personSegmentation` (which does NOT trigger RealityKit's
    /// blurry 256×192 auto people-occlusion) and the Metal pass composites people
    /// occlusion itself — the high-res stencil edge-snapped to the camera luma
    /// (guided filter), depth-tested against LiDAR scene depth, temporally
    /// stabilized and soft-feathered. False falls back to RealityKit's built-in
    /// `.personSegmentationWithDepth`.
    static let customPersonOcclusion = true

    /// ADR-030: cap AR capture+render to ~30 fps (nearest supported video format).
    /// Users don't perceive 30 vs 60 in AR, and it roughly halves per-frame
    /// CPU/GPU/ISP load — the biggest single lever on heat and fps drops.
    static let targetFrameRate = 30

    /// ADR-030 occlusion depth-test bias (m): a real surface must be at least this
    /// much nearer than content to hide it — absorbs LiDAR depth noise at edges.
    static let occlusionDepthBiasMeters: Float = 0.1

    /// ADR-030 guided-filter radius (px) for snapping the person matte edge to the
    /// camera luma. 0 disables edge refinement (raw stencil).
    static let personMatteRefineRadius: Int32 = 2

    /// ADR-030 addendum (FT-27: "gap between hand and object"): the refined person
    /// matte is remapped with smoothstep(inner, outer, m). ARKit's stencil is
    /// deliberately generous; coverage below `inner` collapses to 0, eroding the
    /// halo so the camera restore never eats object pixels *around* the occluder.
    /// Bias toward under-coverage: a sliver of object on the hand edge reads as a
    /// soft edge; background holes read as a broken object.
    static let personMatteEdgeInner: Float = 0.55
    static let personMatteEdgeOuter: Float = 0.85

    /// ADR-047: assets larger than this are excluded from launch preload (they
    /// decode on demand behind a placeholder). The shipping catalog budget is
    /// ≤5 MB (CONTENT-PIPELINE); this guard exists for oversized dev assets.
    static let assetPreloadMaxBytes = 16_000_000

    /// ADR-031 mid-field depth (Depth Anything V2 small, Neural Engine): dense
    /// metric-aligned depth for occlusion in the LiDAR-blind 4–60 m band.
    static let midFieldDepthEnabled = ARBaselineExperiment.current.allows(.neuralDepth)
    /// Inference rate (the model is ~17 ms on ANE; mid-field scenery changes
    /// slowly and the matte is EMA-smoothed — 5 Hz reads identically at half
    /// the ANE duty; ADR-035).
    static let midDepthHz: Double = 5
    /// Content nearer than this never gets mid-field-matted (LiDAR/mesh territory).
    static let midDepthMinContentDistance: Float = 4
    /// Aligned depth beyond this is not trusted (relative-depth models flatten far).
    static let midDepthMaxDistance: Float = 60
    /// Depth margin as a fraction of content distance: the real surface must be at
    /// least this much nearer (relative error grows with distance).
    static let midDepthRelativeBias: Float = 0.12
    /// Samples older than this (camera has rotated away) are discarded.
    static let midDepthMaxSampleAge: TimeInterval = 0.3
    /// Counsel MATH-1: the affine alignment is trusted only this factor past the
    /// farthest LiDAR reference sample. Everything beyond is extrapolation — the
    /// literature's verdict on affine-invariant depth is that validity ends at
    /// the reference interval, and the pre-fix behavior (evaluating a 0.4–4 m
    /// fit out to 60 m) produced either nothing or a hallucinated near wall.
    static let midDepthSupportMargin: Float = 1.25
    /// The LiDAR band the alignment accepts reference samples from (meters).
    /// Together with the margin this caps what any fit can claim (~5 m) — the
    /// honest ceiling of this occluder until a farther calibration reference
    /// exists (Wave E). The mid-field scheduler only runs the model for
    /// content inside that serviceable band.
    static let midDepthLiDARBandMax: Float = 4.0

    /// ADR-030 addendum: asymmetric temporal response. Attack = matte appearing
    /// (occluder arriving — fast, or content draws over the person); release =
    /// matte clearing (occluder leaving — faster still, or a trail of restored
    /// background follows a moving hand: the FT-27 gap).
    static let matteAttackAlpha: Float = 0.6
    static let matteReleaseAlpha: Float = 0.85

    /// ADR-043 (supersedes ADR-013's always-warm window): the camera NEVER runs
    /// without camera intent — no green dot on the map tab. After leaving the
    /// camera tab, the session stays warm only this long (tab-flip grace); the
    /// cold path is covered by launch-time warmup + the reveal transition.
    static let pauseGraceSeconds: TimeInterval = 5

    /// Cap on the reveal overlay: it dismisses on real readiness signals
    /// (first frame + placements) but never holds the user longer than this.
    static let revealMaxSeconds: TimeInterval = 1.6

    /// Drops within this range of the viewer get rendered in AR (meters).
    /// Far drops are shown scaled-up (see `minApparentAngleDegrees`) so pointing the
    /// camera in their direction always shows something.
    static let arVisibilityRadius: CLLocationDistance = 2_000

    /// Radius used when fetching shared drops around the user (meters).
    static let nearbyQueryRadius: CLLocationDistance = 3_000

    /// ADR-049 perceptual size compensation. The optical chain (camera FOV ≈50°
    /// compressed onto a screen subtending ≈12° at arm's length) makes every
    /// through-the-phone object ~4–5× smaller in visual angle than naked-eye
    /// reality; the scene survives via size constancy, unfamiliar virtual
    /// content does not. Correction: content scale × clamp((d/d0)^beta, 1, cap)
    /// — apparent angle then decays as d^(beta−1) instead of d^(−1). Sub-linear,
    /// capped, never billboarded (ADR-008's failure modes stay banned).
    static let perceptualCompensationEnabled = true
    static let perceptualD0: Float = 8
    static let perceptualBeta: Float = 0.35
    static let perceptualCap: Float = 12

    /// Minimum apparent size of a drop on screen, in degrees of visual angle.
    /// Content too small/far to reach this is scaled up so it stays visible; the
    /// boost fades out as you approach and true perspective takes over.
    static let minApparentAngleDegrees = 2.0

    /// Cap on the far-distance scale boost (keeps multi-km drops sane).
    static let maxDistanceBoost: Float = 80

    /// Re-anchor when a better GPS fix implies our placement is off by more than
    /// this many meters (small corrections slide smoothly; GPS noise is ignored).
    static let refinementCorrectionThreshold: CLLocationDistance = 6

    /// Re-anchor unconditionally past this error (accumulated drift on long walks).
    static let forcedCorrectionThreshold: CLLocationDistance = 30
}
