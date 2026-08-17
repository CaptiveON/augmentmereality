# DECISIONS.md — Architecture Decision Records

Law of the repo (per ENHANCEDMASTERPLAN §11 / BRIEF.md): every load-bearing choice gets an
ADR with sourced rationale. No silent re-litigation — supersede with a new ADR instead.

---

## ADR-001 — ARCore Geospatial (VPS) is the localization spine
**Date:** 2026-07-07 · **Status:** Accepted
**Decision:** Google ARCore Geospatial API is the precision layer for global placement.
Niantic Lightship is *not* the base layer; it stays on the Wave-7 research shelf as an
urban-core precision booster only.
**Rationale:** The product promise is coordinate-first, remote placement at "any friend's
house" — that requires global coverage keyed by lat/lon. VPS localizes against Street View
imagery in 87+ countries ([geospatial overview](https://developers.google.com/ar/develop/geospatial)),
~1–5 m / <5° typical. Lightship localizes against crowdsourced scanned Wayspots — dense only
where scanned ([Lightship VPS docs](https://lightship.dev/docs/ardk/features/lightship_vps/));
wrong coverage shape for our promise.
**Consequences:** Google Cloud API key required (free, quota 1,000 sessions/min); Street View
coverage bounds precision availability; compass tier must carry uncovered areas.

## ADR-002 — VPS is a correction layer; it never gates rendering
**Date:** 2026-07-07 · **Status:** Accepted (mandated by BRIEF Killer #1)
**Decision:** The render loop never waits for VPS (or any slow layer). Objects spawn from
L0 (GNSS+heading) at first opportunity; when VPS resolves, content glides (≤1.2 s,
critically damped) to the corrected pose. Implemented: `GeoARSessionManager` compass-first
placement + `applyVPSTransform` glide handoff.
**Rationale:** VPS convergence is 10–15 s typical, device-variant, sometimes never
(ENHANCEDMASTERPLAN §1 research basis; [checkVpsAvailability guidance](https://developers.google.com/ar/develop/unity-arf/geospatial/check-vps-availability)).
Gating render on it produced the field-fatal wait-then-pop-in.
**Consequences:** Users can briefly see coarse placement; the glide is the accepted cost —
it reads as "settling", never as "appearing".

## ADR-003 — L0 spawn path: seeded heading, no multi-sample gate
**Date:** 2026-07-07 · **Status:** Accepted
**Decision:** In `.gravity` alignment (VPS mode), the compass-vs-AR-yaw estimator seeds from
the **first** compass sample (accepting even a low-quality first sample) instead of EMA-ing
up from zero, and first placement is gated on ≥1 sample, not 8. Time-to-first-object (TTFO)
is instrumented (`timeToFirstObjectMs`, HUD + os_log) — bar: median ≤400 ms from AR attach.
**Rationale:** The prior 8-sample (~3 s) warm-up violated Killer #1. Heading updates stream
from app launch, so a usable sample exists at (or milliseconds after) camera open; a seeded
estimate + continuous EMA refinement + placement-hysteresis re-sync achieves instant spawn
with convergent accuracy.
**Consequences:** First seconds may carry larger heading error (content can start rotated
off-bearing and glide in); accepted per ADR-002 philosophy.

## ADR-004 — iOS occlusion stack (platform-verified capabilities)
**Date:** 2026-07-07 · **Status:** Accepted (semantics integration pending)
**Decision:** Occlusion composites near→far on iOS as:
`person segmentation → LiDAR scene depth + reconstruction mesh → Streetscape building
meshes → Scene Semantics building/sky matte (to integrate, Wave 4.5)`.
**Verified platform facts (primary sources, 2026-07-07):**
- Scene Semantics **is available on iOS** — `GARSessionConfiguration` semantic mode,
  `GARFrame.semanticImage`/`semanticConfidenceImage`
  ([iOS scene-semantics guide](https://developers.google.com/ar/develop/ios/scene-semantics)).
- Geospatial Depth (fused depth ≤65 m) **is Android-only**
  ([iOS geospatial developer guide](https://developers.google.com/ar/develop/ios/geospatial/developer-guide));
  the ENHANCEDMASTERPLAN §2.2 row listing it applies to Android builds. On iOS the
  LiDAR→building gap is bridged by Streetscape meshes + the semantic matte.
- Streetscape Geometry **is available on iOS** and usable for occlusion
  ([streetscape geometry iOS guide](https://developers.google.com/ar/develop/ios/geospatial/streetscape-geometry)).
**Consequences:** Silhouette-quality bar (<1° occlusion error) on iOS rides on semantics
integration + SilhouetteRefiner; mid-range (8–65 m) occlusion is geometry/semantics-based,
not depth-based, on iOS.

## ADR-005 — Apple ARGeoAnchor stays disabled until timeout+fallback exists
**Date:** 2026-07-06 · **Status:** Accepted
**Decision:** `AppConfig.appleGeoAnchorsEnabled = false`. Re-enable only together with a
localization timeout that falls back to the compass tier.
**Rationale:** Field-verified failure (2026-07-06 night test): geo localization can fail
indefinitely at night; the auto-upgrade re-anchored all content to anchors that never
resolved → total blackout with no fallback. Coverage is also ~25 US metros + London
([ARGeoTrackingConfiguration](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration)).
**Consequences:** iOS-native corroboration unused for now; VPS covers the precision role.

## ADR-006 — Backend must be cross-platform; CloudKit demoted to stopgap
**Date:** 2026-07-07 · **Status:** Accepted (successor backend selection = open ADR)
**Decision:** Per ENHANCEDMASTERPLAN §8, the Wave-3 backend must serve Android + iOS.
CloudKit (iOS-only) is demoted from "the sharing backend" to "iOS-only stopgap, flag-gated,
already built". Wave-3 hardening selects a cross-platform geo-query backend
(candidates: Firebase/Firestore + geohash, Supabase/PostGIS) in its own sourced ADR.
**Consequences:** `DropStore` protocol abstraction (already in place) is the seam; CloudKit
code remains but is not the growth path.

## ADR-007 — Transit Mode: geo-pose dead reckoning, VIO dropped as world-lock in vehicles
**Date:** 2026-07-07 · **Status:** Accepted (build = Wave 5)
**Decision:** At `MotionClassifier == vehicular`, far-field drops render from a synthetic
camera posed by GNSS + fused heading/gyro dead reckoning in geo-space; VIO is not trusted
for world-lock; occlusion comes from Streetscape meshes + semantic matte (never LiDAR
through glass). Hysteretic mode switching.
**Rationale:** VIO is built for pedestrian scenes and degrades in large dynamic scenes and
through glass at speed (ENHANCEDMASTERPLAN §1 Killer #3 research basis, arXiv 2010.01023 §6).
The correct model change, not parameter tuning.
**Consequences:** A second render path to maintain; the signature demo (train window)
depends on it.

## ADR-008 — Content is world-truth; only markers may be screen-space
**Date:** 2026-07-07 (formalizes v0.3 field lesson) · **Status:** Accepted
**Decision:** Drop content is placed once, true-scale, fixed orientation — never per-frame
billboarded or rescaled. Way-point orbs/pillars (explicit UI) are the only entities allowed
apparent-size compensation. Content materials are lit PBR with emissive (day shading, night
visibility); markers/pillars/beacons are unlit.
**Rationale:** Field test 2026-07-07: min-apparent-size boost + per-frame billboarding read
as "a sticker on the camera" — it cancels exactly the parallax/perspective cues that sell
presence.
**Consequences:** Far-visibility is the marker's job; giant content is visible far because
it is genuinely giant. *Material clause superseded by ADR-020 (2026-07-07): the always-on
emissive is replaced by a viewer-side Natural/Bright toggle.*

## ADR-009 — Altitude: store height-above-ground; resolve ground at view time; clamp
**Date:** 2026-07-06/07 · **Status:** Accepted
**Decision:** Drops store `heightAboveGround`. Ground resolves via: VPS terrain anchor
(authoritative) → sane-band LiDAR/plane estimate (only 0.5–4 m below camera) → camera−1.5 m;
final altitude clamped to [camera−5 m, camera+40 m].
**Rationale:** GPS altitude is unusable; remote pins can't know ground height. Field bug
2026-07-06: one night-time garbage plane sank all content underground — hence the band +
clamp (content must be physically unable to render outside the visible band).
**Consequences:** Terrain-anchor ground wins whenever VPS is localized.

## ADR-010 — Secrets: gitignored plist, restricted key
**Date:** 2026-07-07 · **Status:** Accepted
**Decision:** API keys live in `Support/Secrets.plist` (gitignored; `Secrets.sample.plist`
template committed), read at runtime, absent-tolerant. The Google key must be restricted in
Cloud Console to bundle `com.adnan.augmentmereality` + ARCore API only (user action).
**Consequences:** Fresh checkouts run compass-only until a key is added; no key in source
control or docs.

## ADR-011 — Semantic matte v1: depth-free, far-gated, feathered, EMA-stabilized
**Date:** 2026-07-07 · **Status:** Superseded in part by ADR-018 (the global far gate
is replaced by a per-pixel metric-depth gate; feather/EMA/label plumbing unchanged)
**Decision:** The SilhouetteRefiner is a RealityKit post-process (`SemanticOcclusionPass`
+ `SemanticMatte.metal`): wherever *virtual content* overlaps a pixel labeled
building/tree/structure by ARCore Scene Semantics, the camera image is restored,
weighted by the model's confidence (soft feather) and temporally EMA-smoothed (α=0.35).
**Far-mode gate:** the matte applies only when every rendered drop is > 40 m from the
camera (`AppConfig.semanticMatteFarThreshold`) — the semantic image has no depth, but a
real surface labeled building/tree at a pixel is almost certainly nearer than 40 m+
content, so matting is safe; with any near content on screen the pass disarms rather
than risk eating it.
**Sources:** [iOS Scene Semantics guide](https://developers.google.com/ar/develop/ios/scene-semantics);
[GARFrame(Semantics)](https://developers.google.com/ar/reference/ios/category/GARFrame(Semantics))
(OneComponent8 label + confidence images);
[GARSemanticLabel](https://developers.google.com/ar/reference/ios/group/GARSemanticLabel).
Label raw values are passed into the shader from the SDK enum at runtime — never hardcoded.
**Known risks to field-verify (honesty rule):** (a) YCbCr→RGB restore may mismatch
RealityKit's own camera compositing slightly — visible as a faint patch at matte
regions; (b) display-transform direction (view→capture) must be verified on device —
`AppConfig.semanticMatteDebugTint = true` renders the matte as red tint for exactly
this; (c) v2 replaces the far-gate with a true per-pixel depth threshold once the
RealityKit depth convention is verified on device. SPM note: semantics requires linking
the **`ARCoreSemantics`** package product (the `ARCoreGeospatial` product alone does not
export the GARFrame semantics category).

## ADR-012 — Systems-health metrics are part of the HUD, not a separate tool
**Date:** 2026-07-07 · **Status:** Accepted
**Decision:** §10 metrics ship inside the app: TTFO (ADR-003), render fps (2 s window
over the per-frame callback), thermal state (`ProcessInfo.thermalState`, HUD warning at
`.serious`+). Field reports = a screenshot of the HUD. Next: anchor-drift measurement
(stationary-hold test) and frame-time p95 via MetricKit.
**Rationale:** "If it isn't instrumented, it isn't done" (mandate §0.4); the user is the
field-test instrument, so the numbers must be on their screen.

## ADR-013 — AR session pre-warm from the map tab (bounded window)
**Date:** 2026-07-07 · **Status:** Accepted (v0.7)
**Decision:** `ARSessionHolder` owns the ARView + engine at app level. The session
starts when intent forms (map tab appears / app foregrounds) and keeps running for
`prewarmWindowSeconds = 75` after leaving camera contexts, then self-pauses. Camera-tab
entry cancels the pause; TTFO is measured from camera-visible and reads **0 ms when
pre-warmed** (content already placed). While the ARView is off-screen the render loop
idles, so the placement tick feeds GARSession at 2.5 Hz to keep VPS converging in the
background.
**Trade-off (stated, not hidden):** during the pre-warm window the system camera
indicator is on while the user is on the map. Bounded to 75 s per arming; suspended
immediately on app background. Battery cost to be measured in the field per §10.
**Rationale:** §5.1 — the ≤400 ms bar is unreachable with a cold camera/VIO/VPS bring-up
(~1–2 s+). Pre-warming is the only architecture that makes "already there" true.

## ADR-014 — Motion classification: GNSS-speed hysteresis, classifier-before-renderer
**Date:** 2026-07-07 · **Status:** Accepted (v0.7 ships the classifier; Transit render
path is Wave 5)
**Decision:** `MotionClassifier` derives still/walking/vehicular from GNSS speed with
asymmetric hysteresis: enter vehicular at sustained >7 m/s for 5 s; exit only after
sustained slower motion for 10 s (survives station stops); walking threshold 0.6 m/s.
Surfaced as a HUD chip ("VEHICLE") *before* any render-path change so thresholds are
validated against the user's real commutes first.
**Rationale:** §6 requires hysteretic, no-flap mode switching; shipping the classifier
as instrumentation first follows "measure, then claim" — the Transit render path will
switch on a classifier we have field evidence for. Thresholds are initial engineering
values, to be tuned from field data (explicitly not source-cited — there is no primary
source for our users' trains; the field is the source).

## ADR-015 — Transit render path: per-frame geo-relative re-expression
**Date:** 2026-07-07 · **Status:** Accepted (v0.8; field validation = FT-13…17)
**Decision:** When `MotionClassifier == vehicular`, the world-lock authority changes
(§6): every render frame, each drop's position is recomputed **relative to the current
camera pose** from the dead-reckoned geo-pose
(`GeoMath.predicted`: GNSS fix advanced along course × speed, capped at 8 s) and the
compass-corrected bearing. VIO translation errors cancel (positions are relative to
whatever the camera pose is this frame); rotation rides on ARKit yaw continuously
corrected against the compass with a faster EMA (α 0.2 vs 0.08). In transit: LiDAR/mesh
occlusion **off** (it would mesh the train window itself), streetscape occluders hidden
(they live in the untrusted VIO frame), VPS transforms ignored; **semantic matte +
person-seg carry occlusion**. Far-field yaw-billboarding is allowed in transit per
master plan §6.2 (explicit exemption from ADR-008). Exit → clean pedestrian re-sync.
**Honest limits (in the HUD):** GPS-stale >8 s reports "tunnel?" and stops
extrapolating; magnetometer inside a metal car can bias bearings — the compass-accuracy
hint stays visible; vertical uses a flat-earth assumption over ≤2 km.

## ADR-016 — Failure-mode audit v0.8: the app must never strand a field test
**Date:** 2026-07-07 · **Status:** Accepted
**Audit findings → fixes shipped:**
1. Location/camera permission denied → HUD used to spin on "Waiting for GPS…" forever
   → now states the exact problem and the fix (Settings).
2. Corrupt local cache (`drops.json`) → used to throw on every load, silently losing
   all drops → now quarantined to `drops.json.corrupt` and the store continues clean.
3. Demo button with no GPS fix → used to silently no-op → now disabled with an
   explanatory label.
4. Unknown future `content` type in synced data → decode throws (verified by test),
   merge skips it — no crash.
**Testability refactors:** `MotionClassifier.update(speed:at:)` (injectable clock),
`LocalDropStore(fileURL:)`, `DropLibrary(localStore:cloudStore:)`.
**Automated suite:** unit-test target `AugmentMeRealityTests` hosted in the app,
runnable on device — 21 tests: GeoMath (ENU round-trips, bearings, dead-reckoning cap),
MotionClassifier hysteresis (no-flap, sticky station stops, GPS-blip immunity),
GeoDrop codability + color/title fallbacks, LocalDropStore CRUD + corruption
quarantine, DropLibrary geo-radius filter. **v0.8 result: 21/21 passed on the target
iPhone (2026-07-07).** Ops note: after a plain `build` the products app loses the
embedded test plugin — always `build-for-testing` before `test-without-building`.
**Known remaining risks (accepted, tracked):** streetscape mesh generation happens on
the main thread (hitch possible when many buildings stream in — profile in FT-18);
GARSession is fed from `session.currentFrame` polling rather than a delegate; matte
color-restore may mismatch RealityKit's camera compositing slightly (FT-11 verifies).

## ADR-017 — Heading authority: VPS yaw > pan-gated compass (field-driven, v0.9)
**Date:** 2026-07-07 · **Status:** Accepted
**Field evidence (2026-07-07):** "Object appears at the right place, then moves to the
right or left and I have to face that way." Root cause analysis: the compass-vs-AR-yaw
estimator ingests `CLHeading`, which (a) carries direction-dependent magnetic bias of
±10–30° and (b) **lags the physical rotation during pans** while AR yaw is
instantaneous — mid-pan samples are fiction. The polluted EMA crossed the 15° re-sync
limit and rotated every drop around the viewer (15° at 100 m = 26 m sideways). A second
contributor: VPS terrain anchors were requested at yaw σ ≤15° (±26 m lateral at 100 m)
and post-glide refinements were applied with `setTransformMatrix` (visible snaps).
**Decision:**
1. When GAREarth is tracking with `orientationYawAccuracy ≤ 20°`, the session heading
   error is measured **optically from VPS** (`eastUpSouthQTarget` vs the same ARFrame's
   camera yaw — computed in `GeospatialEngine.updateHeadingErrorSample`, zero timing
   skew) and the compass is not consulted. Compass resumes only after VPS is silent 5 s.
2. Compass samples taken while the camera yaw rate exceeds 15°/s are rejected
   (`AppConfig.compassMaxPanRateDegreesPerSecond`) — CLHeading lag makes them invalid.
3. Re-sync hysteresis: 3° when VPS-driven (degree-accurate source ⇒ small disagreements
   are real; corrections read as settle), unchanged 5°/15° ladder for compass.
4. `vpsGoodYawAccuracyDegrees` 15 → 8 (anchor creation gate; sin σ·d is lateral error).
5. Post-glide VPS anchor refinements > 0.3 m glide over 0.5 s instead of snapping.
**Sources:** [GARGeospatialTransform.h](https://developers.google.com/ar/reference/ios/interface/GARGeospatialTransform)
(`eastUpSouthQTarget`, `orientationYawAccuracy`; header verified in SPM artifact
2026-07-07); CLHeading lag/deviation is field-measured behavior (the field is the source).
**Consequences:** Wherever VPS earth-tracks (even before anchor-grade localization),
placement bearing no longer depends on the magnetometer at all; compass tier remains the
no-coverage fallback. FT-24 validates.

## ADR-018 — Semantic matte v2: per-pixel metric-depth gate (supersedes ADR-011 far gate)
**Date:** 2026-07-07 · **Status:** Accepted (v0.9; field verification FT-11/FT-25)
**Field evidence (2026-07-07):** drop >100 m behind trees drew over them, and kept
drawing over everything on the walk-up. Two causes: (1) the ADR-011 far gate armed the
matte only when **every** placed drop was >40 m — any near drop (demo text 15 m ahead, a
second pin, or simply approaching within 40 m) disarmed occlusion globally; (2) below
40 m nothing occludes trees at all (LiDAR reaches ~5 m; Streetscape meshes are
buildings-only; Geospatial Depth is Android-only per ADR-004).
**Decision:** The matte gates **per pixel** on the virtual content's metric depth,
decoded in-shader from RealityKit's depth buffer using the frame's actual projection
matrix (`ARView.PostProcessContext.projection` — verified in the iOS 26.5 SDK
swiftinterface 2026-07-07): `d = projZW / (projZZ − depth·projWSign)`, convention-proof
for forward/reverse, finite/infinite Z. Class-dependent thresholds
(`AppConfig`): **tree ≥15 m** (trees rarely sit immediately behind pinned content),
**building/structure ≥35 m** (protects the hero case — text floating in front of a
friend's house must never be eaten by the facade behind it). A bad depth decode fails
toward matte-off (draw-over), never toward eating near content. The pass arms when any
drop is beyond 15 m (`semanticFeed.setEnabled`), instead of all-beyond-40 m.
**Honest limits:** a 5–15 m tree band and 5–35 m building band remain depth-blind on
iOS (bridged only where LiDAR mesh/Streetscape exist); content pinned 
immediately in front of a tree and viewed from >15 m can be feather-matted by the canopy
behind it — accepted trade against the dominant field failure. Thresholds are field-tunable.
**Consequences:** near drops protect themselves pixel-by-pixel; far drops occlude even
while other drops are close; walking toward a drop keeps tree occlusion until 15 m out.

## ADR-019 — Pin clarity + creator-chosen facing
**Date:** 2026-07-07 · **Status:** Accepted (v0.9)
**Field evidence (2026-07-07):** confusion between the user's own blue dot and the pin
while composing ("if I pin the location it also shows my location as well"), and a
request to control the content's direction.
**Decision:** (1) While the composer sheet is up, the map shows a red "New drop" marker
at the tapped coordinate, and the composer footer states the pin's offset from the user
("Pinned at … — 132 m NE of you" / "right where you are standing"). (2) `GeoDrop` gains
optional `facingDegrees` (compass bearing the content front faces; `nil` = auto, face
the first viewer — previous behavior). Honored in the compass tier (AR-frame yaw
π − (facing − headingCorrection)) and VPS terrain anchors (EUS yaw π − facing); transit
far-field yaw-billboarding still overrides per ADR-015's explicit exemption. Optional
field is back- and forward-compatible (synthesized Codable `decodeIfPresent`; CloudKit
mapping updated behind the flag).

## ADR-020 — Content lighting: natural scene-lit PBR default, viewer Bright toggle
**Date:** 2026-07-07 · **Status:** Accepted (v0.9; supersedes ADR-008's material clause)
**Field evidence (2026-07-07):** the always-on emissive (intensity 0.55, added after the
night-blackout field test) washed out real-light shading by day — content read as a
uniformly bright object instead of a lit 3D thing ("used to have the light effects from
lights in surrounding").
**Decision:** Content materials default to **pure lit PBR** (no emissive) so ARKit's
estimated environment light shades them like real objects. A persisted viewer-side HUD
toggle ("Natural light" ⇄ "Bright") switches to emissive intensity 1.0 for night/backlit
conditions — the need is a property of the *viewing conditions*, so it belongs to the
viewer, not the drop. Flipping re-skins placed content in place
(`rebuildContentEntities`): only the model swaps; holder pose, pillar, marker, VPS
ownership are untouched. Markers/pillars/beacons stay unlit per ADR-008.
**Consequences:** night visibility is one tap instead of automatic — FT-12 (window at
night) should be run with Bright on; if field tests show people forget the toggle, a
light-sensor auto mode becomes a follow-up ADR.

## ADR-021 — Animated 3D content: bundled USDZ, folder-driven catalog
**Date:** 2026-07-07 · **Status:** Accepted (v0.9)
**Decision:** New `GeoDrop.Content.animated` + `assetName`. Any `.usdz` dropped into
`AugmentMeReality/Assets3D/` is bundled by the synchronized project group and appears in
the composer's Model picker automatically (`DropEntityFactory.bundledAnimatedAssets` =
runtime bundle scan — no registry to maintain). Templates are decoded once at app start
(`preloadAnimatedAssets`; async `Entity(named:in:)` on iOS 18+, availability-gated sync
`Entity.load` on iOS 17 — the async initializer is 18-only) and **cloned per placement**
(clones share mesh/texture resources and keep `availableAnimations`). Models are
normalized to the app's ~1 m-at-scale-1 convention (largest dimension → 1 m, base at
y = 0) so the size slider means the same thing for every content type. All animations
auto-play looping, started **after scene insertion** (playback controllers created
before parenting don't reliably survive). Missing asset ⇒ visible placeholder text,
never an empty spot (killer #1).
**Format choice:** USDZ only. It is RealityKit's native runtime format with skeletal
animation support; glTF/FBX are not runtime-loadable on iOS — convert with Apple's
Reality Converter (or `usdzconvert`) in the content pipeline, not at runtime.
**Materials:** authored USDZ materials render as-is under ARKit's environment lighting;
the ADR-020 Natural/Bright toggle does not re-skin them (baked materials).
**Test assets:** `toy_drummer.usdz`, `hummingbird.usdz` from Apple's AR Quick Look
gallery (https://developer.apple.com/augmented-reality/quick-look/) — **development/demo
use; replace with licensed/owned assets before any commercial release.** Third-party
sources need license checks (CC-BY requires in-app attribution).
**Consequences:** app size grows with each bundled model (drummer 14 MB, hummingbird
20 MB); a remote asset CDN + download cache is the Wave-6+ follow-up when content ships
from the backend (pairs with ADR-006).

## ADR-022 — Live in-AR editing (height/size sliders) + tap-for-clean-view
**Date:** 2026-07-07 · **Status:** Accepted (v0.9)
**Decision:** (1) The HUD gains a live adjust panel for the **nearest rendered drop**:
a height slider (−2…+20 m — negative allowed so content can be pushed down onto the
*real* ground when the ground estimate is off) and a size slider (0.5–50×, matching the
composer's new "mega" range). Drag ticks apply visually + in-memory only
(`adjustNearestDrop(commit: false)`); slider release persists via
`DropLibrary.update(persist: true)` and — because terrain anchors bake
altitude-above-terrain at creation — removes and re-requests the VPS anchor
(`GeospatialEngine.invalidateAnchor`, `GARSession removeAnchor:` verified in SDK
header). While a drop is in `liveEditingDrops`, every automatic positioner (compass
re-sync, VPS `applyVPSTransform`) keeps its hands off it: the object must never fight
the user's finger. The pillar re-meshes to keep its base on the ground; the way-point
orb re-seats above the rescaled content. (2) Tapping the camera view toggles the entire
HUD (status card, chips, guidance, sliders, demo button) for a clean view; taps on HUD
controls are unaffected (only taps reaching the ARView toggle).
**Consequences:** "size" and "height" are now creator-editable in the field with the
object in view — placement tuning no longer requires round-trips to the map composer.

## ADR-023 — Grounding cues: shadow disc + scale-proportional pillar
**Date:** 2026-07-07 · **Status:** Accepted (v0.9)
**Field evidence (2026-07-07):** live-scaling a far drop "appeared like it's getting
closer" instead of bigger-at-the-same-spot. Root cause is perceptual, not geometric
(scaling is base-anchored at the fixed world position): with no ground-contact cue,
angular growth is ambiguous between "bigger" and "closer", and familiar-size priors
(letters are small) resolve it as *looming*. This is the classic size–distance
invariance ambiguity; every grounded-AR guideline resolves it with a contact shadow.
**Decision:** each drop gets a translucent dark grounding disc (unlit black, opacity
0.35, flattened sphere) planted just above the estimated ground under the content,
footprint-sized (≥0.5 m radius, ~1.1× content footprint) — it grows **laterally only**
as content scales, staying planted at the same ground spot, which disambiguates scaling
as "giant far away". The pillar's cross-section now also grows with content scale
(0.02·scale, clamped 0.06–0.5 m) so the vertical anchor stays visible at range. Both
update live with the ADR-022 sliders (disc follows height edits; disc + pillar re-size
on scale edits). Discs/pillars are explicit UI per ADR-008.
**Known physics limit (not a bug):** wide content at medium range genuinely gets closer
at its near edge when scaled (a 50× "HAPPY BIRTHDAY" is ~60 m wide); the disc keeps the
*anchor point* reading correctly.

## ADR-024 — Field polish: raycast ground snap, far-only pillar, thermal duty cycle
**Date:** 2026-07-07 · **Status:** Accepted (v0.9)
**Field evidence (2026-07-07):** (a) height slider at minimum still left content
hovering — the ground *estimate* (lowest sane plane, else camera−1.5 m) sits above the
real surface by 10–20 cm routinely; (b) sustained camera use heats the phone; (c) the
pillar "looks weird with the object" up close.
**Decisions:**
1. **"Place on ground"** button (adjust panel): `ARRaycastQuery` straight down from the
   drop (`.estimatedPlane`, horizontal) — real LiDAR/plane geometry beats the estimate;
   base lands at hit + 1 cm via the ADR-022 commit path (persists, re-pins VPS anchor).
   Fallback with no geometry in range: height ≈ 0 against the estimate.
2. **Pillar is far-findability UI**: hidden within 25 m (same rule as the way-point
   orb); the grounding disc (ADR-023) carries near-range ground contact.
3. **Thermal duty cycle**: at `.serious`+ thermal state, the GARSession feed drops from
   every render frame to 10 Hz (VPS localization tolerates it) and the semantic matte
   pass disarms — the two biggest controllable heat sources. HUD already warns
   (ADR-012); FT-18/19 measure the effect. Heat itself is expected physics: camera ISP +
   VIO + LiDAR + GPS + VPS network + Metal every frame is the heaviest sustained
   workload a phone runs.

## ADR-025 — Room Test mode: AR-space drops for indoor iteration
**Date:** 2026-07-07 · **Status:** Accepted (v0.9)
**Field constraint (2026-07-07):** the user can't go outside for every check; indoors,
geo placement is meters-off *by physics* (GPS ±20–65 m indoors, VPS needs street
imagery, compass biased by structure) — no amount of tuning fixes that, so indoor
testing needs a placement path that bypasses geo entirely.
**Decision:** HUD "Room test" menu spawns any content type (3D text or any bundled
USDZ) as a **session-scoped, AR-space-anchored drop**: placed by raycast onto the real
surface under the screen-center crosshair (`ARView.raycast`, `.estimatedPlane`, any
alignment — floor OR tabletop; fallback 2.5 m ahead at standing height). Room drops
live in `roomDrops`, are exempt from every geo positioner (compass re-sync cleanup,
transit re-expression, VPS anchors), are never persisted, win `nearestDrop` by AR-space
distance (so the ADR-022 sliders, ground snap, lighting toggle, LiDAR occlusion, and
grounding disc all work on them), and clear via the same menu or session reset.
**Scope note:** Room Test validates *object* features (content, animation, scale,
height, occlusion, cues). Geo features (walk-to accuracy, VPS glide, semantic matte at
range, transit) still require the field — the mode does not pretend otherwise.

## ADR-026 — Live rotation slider + clean screenshot
**Date:** 2026-07-07 · **Status:** Accepted (v0.9)
**Decision:** (1) Third adjust-panel slider rotates the nearest drop's yaw (0–360°
compass bearing). It writes `facingDegrees` (ADR-019's field), so the rotation is the
same quantity placement uses — it survives re-syncs, and a commit re-pins the VPS
terrain anchor (rotation is baked into `eastUpSouthQAnchor` at creation, same rule as
height). Slider seeds from stored facing, else from the holder's current yaw
(`nearestDropFacingDegrees`), so first touch never snaps the object. (2) Shutter button
saves a clean capture via `ARView.snapshot` — the SwiftUI HUD is a separate layer and
is structurally absent from ARView renders, so no hide/show dance is needed; saved via
`UIImageWriteToSavedPhotosAlbum` (add-only photo permission,
`INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` in both app configs), with haptic +
flash confirmation. Tap-to-hide (ADR-022) remains for *composing* the shot by eye.

## ADR-027 — Pillar removed; ground snap gets a truth chain + ground lock
**Date:** 2026-07-07 · **Status:** Accepted (v0.9; supersedes ADR-024.2 and the v0.3
pillar)
**Field evidence (2026-07-07):** (a) the 25 m-gated pillar was "still there most of the
times" — outdoor drops sit beyond 25 m most of the session, so the gate didn't deliver
what the user asked for; (b) "Place on ground" still left content floating.
**Analysis of (b):** two failure paths. The snap raycast (`.estimatedPlane` from the
drop's position) finds nothing when the drop is beyond plane-mapping range → fell back
to the same too-high estimate. Worse, when VPS owned the drop, the post-snap anchor
re-pin resolved against **Google's terrain model**, which differs from the locally
measured ground by up to ±0.5 m — the anchor glide visibly re-floated content the user
had just grounded.
**Decisions:**
1. **Pillar deleted.** Findability = way-point orb (≥25 m) + grounding disc + HUD
   guidance arrow. Field verdict beats the v0.3 rationale; revisit only with evidence.
2. **Ground measurement truth chain:** ARKit plane raycast → LiDAR mesh raycast
   (`.collision` scene-understanding now enabled; `scene.raycast` mask
   `.sceneUnderstanding`) → sane-band plane estimate → camera−1.65 m (standing eye
   height; the old 1.5 m assumption hovered content).
3. **Ground lock:** a successful snap records the measured base world-Y
   (`groundLockBaseY`); compass re-syncs use it verbatim and VPS transforms get their
   Y overridden with it — a real local measurement outranks both GPS altitude noise
   and Google's terrain model. Cleared by a deliberate height-slider commit (user
   override), holder removal, or session reset.

## ADR-028 — In-view stability: corrections apply only off-screen
**Date:** 2026-07-07 · **Status:** Accepted (v0.9)
**Field evidence (2026-07-07):** "it moved to right again while testing multiple
times" — after ADR-017, the remaining movers are the *legitimate* correction paths
(compass-fallback heading drift, GPS refinement slides, VPS post-glide re-localization),
all of which were applied while the drop was on screen. Each individual correction is
justified; watching any of them happen violates killer #2 ("the user witnesses
presence, never placement").
**Decision:** a placed drop that is **in view** (projected inside screen bounds +80 pt
margin, in front of the camera) never moves for a sub-forced correction. Instead the
corrected target is queued (`deferredTargets` / `deferredVPSTransforms`) and applied
with the normal glide the moment the drop leaves the view — or immediately if the error
crosses the forced bar (30 m for GPS/heading, 5 m for VPS: a genuinely misplaced object
gets fixed even while watched, because a wrong spot is worse than a visible settle).
The VPS **first** localization glide still applies in view (that is the designed
"settle to truth" moment); live-edit drops are excluded (the sliders own them).
Deferred applications are os_logged (`metrics`) with magnitude for field forensics.
**Trade-off (stated):** while the user stares at a drop, its residual bearing/position
error persists up to the forced bar; accepted — stability while watched is the product.
**Next diagnostic if it still moves:** HUD screenshot immediately after movement — the
`vps corrections Σ cm` line and VPS chip state distinguish which authority moved it.

## ADR-030 — Custom person occlusion (guided-filter edge refine) + 30 fps cap
**Date:** 2026-07-08 · **Status:** Accepted (v0.9; on-device threshold tuning pending)
**Implements ADR-029 items 1+2** (edge refinement path chosen first).
**Problem:** ARKit People Occlusion mattes a 256×192 person-depth up to screen res →
blurry, flickering silhouette when someone walks between camera and content ("feels
unprofessional", launch-blocking).
**Key enabler:** on a LiDAR device `frame.sceneDepth` already contains the person's real
depth, so we don't need ARKit's coarse `estimatedDepthData`. We request the **stencil-
only** `.personSegmentation` (verified: does NOT trigger RealityKit's built-in people
occlusion, unlike `.personSegmentationWithDepth`) to get the **high-res** person buffer,
and composite occlusion ourselves in the existing `SemanticOcclusionPass` Metal pass:
1. **Guided-filter / joint-bilateral edge refine** — snap the stencil edge onto the true
   silhouette using the sharp camera luma as guide (window ±`personMatteRefineRadius`,
   luma-range × spatial weights). This is the blur fix.
2. **Depth test** — occlude only where LiDAR `sceneDepth` < content eye-depth −
   `occlusionDepthBiasMeters` (bias absorbs depth noise).
3. **Temporal EMA** (α 0.35, existing ping-pong matte textures) — kills flicker.
4. **Soft feather** — matte is continuous [0,1], composited as a mix (ADR-029 item 2 /
   ARCore soft-edge guidance).
RealityKit's sharp **mesh** occlusion (walls/furniture) is untouched. The pass now
installs whenever person occlusion is possible (works indoors, no VPS) OR VPS semantics
are active; one kernel composites `max(semanticMatte, personMatte)`.
**Flags (on-device tunable, `AppConfig`):** `customPersonOcclusion` (false → revert to
RealityKit built-in), `personMatteRefineRadius` (0 = raw stencil), `occlusionDepthBias`,
plus the existing `semanticMatteDebugTint` now visualizes the combined matte in red.
**30 fps cap:** `config.videoFormat` set to the supported format nearest
`targetFrameRate` (30) — halves per-frame CPU/GPU/ISP load (heat, fps drops); users don't
perceive 30 vs 60 in AR (Apple/field guidance).
**Honesty:** person-through occlusion is never pixel-perfect on any platform; this targets
professional-grade (edge-snapped, stable, soft). Thresholds need one on-device tuning pass
via debug tint + Room Test (FT-27) — same workflow that tuned the semantic matte.
**Addendum (2026-07-08, FT-27 round 1):** field result "better, glitches less, but leaves
gaps between my hand and the object showing background — object looks broken." Two causes,
two fixes: (a) ARKit's stencil is deliberately generous → every over-covered pixel restores
*background* where object pixels should be → matte now remapped with
`smoothstep(edgeInner 0.55, edgeOuter 0.85)` — erode + sharpen; deliberate bias toward
under-coverage (object sliver on the hand edge reads as soft edge; background holes read
as broken object); (b) symmetric EMA α 0.35 trailed a moving hand by ~10 frames of
restored background → asymmetric temporal response (`matteAttackAlpha` 0.6 /
`matteReleaseAlpha` 0.85) — matte clears in ~2 frames, single-frame stencil noise still
damped. All four knobs in AppConfig for FT-27 round 2.
**Addendum 2 (2026-07-08, FT-27 round 2):** "open my fingers a little → I see background
through the gaps, like holes in the object." Physics: a ~1 cm finger gap at arm's length
spans several texels of the 256×192 LiDAR depth map, so depth *can* resolve it — but
bilinear sampling blended gap pixels toward finger depth, passing the person-in-front
test and restoring background where the object should show through. Fixes: (a) the depth
test now takes the **max (farthest) of the 4 surrounding depth texels** — if any texel
sees the background through the gap, the object stays (consistent under-coverage bias:
worst case is now a few-px object sliver on the finger rim, not a hole); (b) request
`.sceneDepth` frameSemantics explicitly — raw depth is guaranteed populated and sharper
than smoothed around a moving hand (smoothing smears thin gaps). Remaining limit: gaps
smaller than one depth texel (fingers barely parted) stay bridged — sub-texel matting is
beyond current mobile hardware; the stencil model also bridges those.

## ADR-038 — The Moment loop: commercial product shape (closes ADR-006: Firebase)
**Date:** 2026-07-08 · **Status:** Accepted (product direction; Wave 6)
**Decision (user-ratified):** the app pivots from dev-tool surface to a staged
commercial loop — **share → receive → watch → react → close** ("Moments"). Sessions
are short *by design*: the reaction triggers a finale animation, a memory card, and a
FULL AR teardown. This is simultaneously the thermal strategy (ADR-033/037): the heavy
stack simply never runs long enough to heat the phone — the Pokémon-GO product shape.
**Stage machine:** `arriving → revealing → watching → reacting → closing` drives the
UI, the power governor, and session lifecycle. The dev HUD (chips, sliders, metrics)
moves behind a developer toggle; FIELDTESTS keep working through it.
**Reactions v1 (user-specified):** emoji tray → AR-native particle burst at the object
(world-space, procedural) → reaction event to the sender **live** (push + realtime map
pulse). Recipient can additionally record **video with voice** of the moment — saved
LOCALLY (Photos) for the recipient to share on social media; photo/video *sending*
ships post-launch. Clean screenshot path (ADR-026) reused for the memory card.
**Backend: Firebase** (closes ADR-006) — Firestore (drops, reactions; geohash
geoqueries), FCM push, realtime listeners; Android path preserved; App Clip-friendly.
Full sourced implementation ADR at build start (research is a build step). CloudKit
code retires.
**App Clip:** designed-for, shipped later (v1.1) — moment flow stays decoupled from
the main app; bundled models move to on-demand download before the Clip ships (the
<10 MB Clip bar; asset CDN was already flagged in ADR-021).
**UI identity:** driven from the user's design-service MCP (tokens, stage screens,
reaction tray, memory card); UX architecture and states are ours; implementation is
faithful to the service's specs.
**Honest prerequisites (user-side):** Firebase project + `GoogleService-Info.plist`
(gitignored, like Secrets.plist); **FCM push requires an APNs key = paid Apple
Developer Program** — until enrollment, "live" reactions ride Firestore realtime
listeners (sender sees them with the app open) and push activates later without
rearchitecture.

## ADR-050 — UI revamp slice 2: the create ritual (What → Where → Wrap)
**Date:** 2026-07-17 · **Status:** Accepted
**Shipped:** `CreateWizard` (full-screen Night cover) replaces `DropComposerSheet`
(deleted — the settings-form composer was the concept's core complaint). Three
steps with push transitions + progress dots:
- **What** — toy-shop grid: 6 procedural surprises (message/fireworks/balloons/
  gift/heart/beacon, each with an emotional caption) + every bundled animated
  model as its own card. `SurpriseChoice.locked` is the Wave-8 marketplace
  affordance; all launch items ship unlocked.
- **Where** — purpose-framed map ("Where will they find it? Their doorstep, a
  bench, the spot you met"): search, tap-to-pin, satellite default ON (ADR-041
  imagery), "where I'm standing" tool, nudge arrows 1 m/25 cm, ground/rooftop —
  and the pin line always says where the pin is relative to YOU (the 2026-07-07
  confusion fix carried forward).
- **Wrap** — recipient name (tag), message (display type for text3D), color,
  size with human meters; height/facing/sender behind "More options".
**Flow absorption:** place → `ShareDropSheet` opens inside the wizard (recipient
pre-filled from Wrap) → on close, land on the Sent tab. Entry points: + orb
(finally its real destination), Home hero, Explore map tap / "Place here"
(pre-pinned via `router.beginCreate(at:)`), Memory's "send one back".
**Retired:** MapScreen's composer/share sheets + pendingPin annotation; the
orb's interim route to Explore (ADR-048 note closed).

## ADR-049 — Apparent size vs distance: the optical chain, and perceptual compensation
**Date:** 2026-07-13 · **Status:** Accepted (supersedes ADR-008's "never rescale content" — the ban now applies to *constant-apparent-size* and *billboarding*, not to bounded sub-linear compensation)
**Field evidence:** owner: objects at distance "don't look natural — the math behind is broken."
**Finding: the projection math was exact, and exact is what looks wrong.** The full
optical chain from world to eye, derived and measured:
1. **World → eye (reality):** an object of height h at distance d subtends
   θ_real = 2·atan(h/2d). Scale-3 text (h≈1.8 m) at 50 m: **2.06°**.
2. **World → camera pixels (pinhole):** p = f_px·h/d with ARKit intrinsics
   f_px ≈ 1455 at 1920×1440. Same text at 50 m: ≈52 px.
3. **Camera → glass:** aspect-fill to the 1290-px-wide portrait panel (k≈0.90),
   460 ppi ⇒ **≈2.6 mm** of physical glass.
4. **Glass → eye:** viewed from ≈0.35 m ⇒ θ_perceived = 2·atan(0.0026/0.7) ≈ **0.42°**.
So **θ_perceived/θ_real ≈ 0.20–0.25 at every distance**: a ~50° camera field
aspect-filled onto a screen that subtends only ~12° at arm's length minifies the
whole world ~4–5×. The real street still reads correctly because the visual system
applies size constancy to familiar structure; an unfamiliar virtual object gets no
constancy correction and reads as a miniature — the felt "broken math." This is why
Live View pins, AR games, and flight-sim labels all compensate distant content.
**Decision — capped power-law compensation, true perspective as the backbone:**
`rendered scale = drop.scale × clamp((d/d₀)^β, 1, cap)` with **d₀=8 m, β=0.35,
cap=12** (`AppConfig.perceptual*`). Apparent angle then decays as d^(β−1)=d^(−0.65)
instead of d^(−1) — matched to size-constancy psychophysics (compensation exponents
≈0.2–0.4 under reduced cues). Worked values: ×1.9 @50 m, ×3.1 @200 m, ×6.9 @2 km;
**identity inside 8 m and for all room/Playground drops.** Properties that keep
ADR-008's spirit: strictly monotonic (farther is always smaller; walking closer
always grows), no billboarding, grounding disc scales with the compensated
footprint so the ADR-023 size-vs-distance cue stays coherent, fireworks/beacon
(self-scaling) exempt.
**Implementation:** per-frame in `GeoARSessionManager.applyPerceptualCompensation`
— 2 % hysteresis on the *rendered* scale (imperceptible steps, no transform churn;
the same check catches remote scale edits and freshly swapped asset entities),
marker orb re-seated above the compensated bounds, live scale slider composes
(`drop.scale × factor` — persisted scale stays TRUE size), factor invalidated on
content swaps. **Field truth in the HUD:** diagnostics line now appends the
rendered angular size and active factor ("· 1.9° ×2.3") so FT-33 can verify the
model against perception instead of arguing taste.
**FT-33 (new):** stand at 15/50/150 m from a known drop; readout must match
2·atan(h/2d) within 10 %; verdict question is only "does giant read as giant, and
does approach still feel like approach?" Tune β (0.25–0.45) before touching anything else.

## ADR-048 — UI revamp wave 1: "The Gift, not the Map" (slice 1 shipped)
**Date:** 2026-07-11 · **Status:** Accepted (concept approved by owner; artifact 933664b9…)
**Shipped this slice:**
- **Navigation truth (`AppRouter`):** tabs Home · Explore · [orb +] · Sent · You via a
  custom floating Night tab bar with the breathing create-orb. **The camera is no
  longer a tab** — it's a presented moment (`fullScreenCover`) opened by: Home's
  for-you/Playground cards, Explore's viewfinder button, the receive flow, and
  onboarding's demo. Camera gets a persistent dismiss chevron.
- **HomeScreen (the new front door):** greeting header → You; state cards from real
  data (🎁 waiting-for-you = received drops w/ live distance; ⏳ not-opened-yet = my
  link-shares w/ relative time → Sent); empty-state hero sells the first drop;
  Playground card. Honest gaps: memories strip & occasion cards wait on memory
  persistence + occasion engine (next slices).
- **Onboarding (3 beats, skippable):** promise → **live fireworks on the user's own
  floor** (Playground + procedural show, camera permission lands in-context, drop
  auto-placed once `sessionFrameReady`) → name-only identity (writes profile). Gated
  by `hasOnboarded`; AR chrome hidden during the demo; a "Magical — continue" chip
  returns to the story.
- Renames: Room test → Playground, My Drops → Sent (title-level).
**Interim (disclosed):** the + orb routes to Explore (map-tap compose) until the
create-wizard slice lands. Remaining slices: create ritual → tune dock → Sent
timelines → You/trophy restyle → Figma mirror.

## ADR-047 — Asset hang, round 2: measured fix (supersedes ADR-032's loader choice)
**Date:** 2026-07-11 · **Status:** Accepted (stall now MEASURED on device, not assumed)
**Field evidence:** the launch hang recurred "while loading the assets" despite ADR-032.
**Root cause revision:** ADR-032 assumed the iOS-18 async `Entity(named:)` initializer
decodes off-main between suspensions. It is `@MainActor`-annotated — its decode work can
run in long main-actor slices, which is exactly a hang under a 100+ MB catalog. The
Combine `Entity.loadAsync` pipeline (previously only the iOS-17 fallback) is the API
whose decode genuinely runs on RealityKit's background queue.
**Decisions:**
1. `decodeTemplate` uses **loadAsync on every OS version** (deprecated on 18+ —
   deliberately; revisit only when Apple ships a nonisolated async loader).
2. **Measurement is the regression gate:** `AssetLoadStallTests` runs a 10 ms
   main-actor ticker while the HEAVIEST bundled asset decodes; bars: no main gap
   >250 ms during decode, placement clone <800 ms. First run (31 MB Castle,
   iPhone 15 Pro Max): passed in 0.44 s total. Any future loader change must keep
   this green — hypotheses no longer accepted for this bug class.
3. **Preload size guard:** assets >16 MB (`assetPreloadMaxBytes`) never auto-preload —
   on-demand only, behind the placeholder (shipping catalog budget is ≤5 MB anyway;
   the guard exists for oversized dev scans).

## ADR-046 — Content strategy: effects layer + four-tier sourcing (CONTENT-PIPELINE.md)
**Date:** 2026-07-10 · **Status:** Accepted (effects layer shipped; catalog ops = user)
**Problem:** launch needs unique, lightweight, animated objects — and "unique" can't
come from free marketplaces by definition.
**Shipped — the "alive" layer (`DropEffects.swift`):** runtime effects at zero file
size: sparkle aura around every drop (ParticleEmitterComponent, iOS 18+, SDK-verified;
tinted per drop, sized to content bounds), a celebration reveal burst on first
close-range arrival (per-drop once, `revealedDrops`), and idle motion (bob for text,
bob+slow-spin for objects) for any model WITHOUT its own rigged animations — so static
lightweight models read as premium animated content. Older-than-iOS-18 devices skip
particles gracefully.
**Sourcing doctrine (CONTENT-PIPELINE.md):** Tier 1 procedural+effects (ours, 0 MB) →
Tier 2 AI-generated (HiggsField MCP `generate_3d`, Meshy/Tripo w/ auto-rig) → Tier 3
commissioned heroes (rights buyout, brief template in doc) → Tier 4 curated CC0/CC-BY
filler, restyle mandatory. Hard budgets: ≤5 MB/≤50k tris/2k textures, pivot at base,
front +Z, GLB→USDZ via Reality Converter, QA in Room Test. Launch catalog target
12–16 (6–8 free, 6–8 premium heroes/packs); Apple sample models must be replaced
before submission (dev license).

## ADR-045 — Full-project audit: P0 fixes shipped, launch-gap register opened
**Date:** 2026-07-09 · **Status:** Accepted (P0s fixed same-sitting; register below is law)
**P0 defects found & FIXED (41/41 device tests):**
1. **Update = data loss:** synthesized `Decodable` requires keys even with property
   defaults — adding `visibility`/`anchorMode` made every pre-6.2 drops.json (and old
   cloud docs) throw → corrupt-quarantine silently emptied libraries. Fixed: resilient
   `init(from:)` (every field `decodeIfPresent` + default) + 3-test compatibility pin
   (legacy JSON, minimal skeleton, current round-trip). RULE: any future GeoDrop field
   must keep `GeoDropCompatibilityTests` green.
2. **Sender toasts watched the wrong drops:** drops sort newest-first; `.suffix(10)`
   listened to the ten OLDEST shares — the drop just sent was unwatched. → `.prefix`.
3. **CVMetalTexture lifetime:** matte pass released CV wrappers while the GPU still
   sampled them (classic intermittent corruption). → retained per frame, released in
   `addCompletedHandler`; bail-out frames drained at next encode.
**Launch-gap register (owner-visible, ordered):**
- **Submission blockers:** account deletion UI+backend (App Store 5.1.1(v) — we have
  accounts now); app privacy manifest (PrivacyInfo.xcprivacy, required-reason APIs);
  Google API key restriction confirmation; paid membership (SIWA, push, TestFlight).
- **Robustness (P1):** ARSession interruption/error delegates (call/lock recovery is
  untested code, FT-20 predates 6.x); Crashlytics (BRIEF's 99.5% crash-free bar is
  currently unmeasurable); received-drop edit gating (viewer can locally "move" the
  sender's drop); location accuracy downgrade off-camera (battery).
- **Product debt (P2):** PRODUCT-ROUTE §4 K-loop analytics NOT instrumented (invites
  sent/opened/installed/reacted/shared-out — the route's own gate metrics); AR Quick
  Look on invite page; consent-gated reaction clip; localization (EN-only);
  accessibility (VoiceOver on HUD/reactions); GeoARSessionManager split (~1500-line
  god object); CloudKitDropStore deletion; USDZ polygon budget for A12-class devices.

## ADR-044 — Glass Mode: the stationary sibling of Transit's occlusion posture
**Date:** 2026-07-09 · **Status:** Accepted (field: FT-32 — view a far drop through a window)
**Field evidence:** "issue when watching outside through the glass." Physics: LiDAR
reflects off the pane → scene reconstruction meshes an invisible wall ~1 m away that
OCCLUDES the outdoor drop; window reflections misfire person segmentation (matte cuts
holes); the mid-field model's LiDAR alignment band is all pane/interior (bad metric
fit). Transit Mode (ADR-015) already sheds these through VEHICLE glass but only when
moving; stationary-at-a-window had no handling.
**Decision:** auto-detected **Glass Mode**: per tick, if the nearest drop is >15 m,
deliberately in view, and a scene-mesh raycast toward it hits real-mesh geometry at
<3.5 m (mesh-vs-geo conflict), accumulate evidence (~1.2 s to enter, ~2.4 s
counter-evidence to exit). Active ⇒ mesh occlusion OFF, person segmentation and neural
depth shed, **semantic matte stays** (image-based, glass-proof — same posture as
Transit). HUD chip `GLASS`; transitions os_logged.
**Stated ambiguity:** a true wall produces the same signature — but then the user
couldn't see the spot at all, and BRIEF's law is visibility-first; the chip keeps it
honest. Tracking wobble from reflection parallax is physics and remains.

## ADR-043 — Camera on intent only; the reveal replaces the prewarm (supersedes ADR-013)
**Date:** 2026-07-09 · **Status:** Accepted (field: FT-1/2/3 re-run under new semantics)
**User requirement:** no camera activation while on the map (green-dot privacy optics +
battery), but no perceptible lag on camera open either.
**Research (sources in field report):** Snap's own metric is time-to-camera-ready and
their method is a **startup dependency DAG — at open, initialize ONLY what the
viewfinder needs** ([Snap Engineering](https://eng.snap.com/time_to_camera_ready));
Apple's [WWDC26 "Build a responsive camera app that launches quickly"](https://developer.apple.com/videos/play/wwdc2026/303/)
codifies preview-first + deferred expensive outputs; ARKit VIO inherently needs ~a
second of frames to reach `.normal` tracking
([session-lifecycle docs](https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality)) —
the cost nobody skips, which encounter-based AR apps hide behind a THEMED TRANSITION,
not a spinner.
**Decision (three parts):**
1. **Cold-warm split:** at launch/foreground, warm everything camera-independent —
   ARView allocation, model decodes, location/heading, Firebase — via
   `warmWithoutCamera()`. The capture session cannot start from the map tab at all.
2. **Intent triggers:** camera tab selection starts the session; opening a drop link
   is also intent — the invitation screen (`ReceiveScreen`) starts the session behind
   itself so "Reveal in AR" lands in a live camera. Tab-flip grace shrinks 75 s → 5 s
   (`pauseGraceSeconds`) — the long window existed only to fake instant-open.
3. **The reveal:** a Night-language viewfinder-opening moment (brand ring, "Finding
   what's around you…", live drop count) masks bring-up; dismissed by the REAL
   readiness signal (`sessionFrameReady`, first rendered frame; ≥0.45 s so it reads as
   intentional, ≤`revealMaxSeconds` 1.6 s hard cap). Killer #1 reframed: the user never
   sees an empty viewfinder — content is placed before the curtain lifts.
**Metric change:** TTFO's "0 ms pre-warmed" era ends; the bar is now reveal-covered
cold start ≤1.6 s and zero empty-viewfinder frames. FT-1/2/3 re-baselined.

## ADR-042 — Rooftop anchors: content on real building tops
**Date:** 2026-07-09 · **Status:** Accepted (field: pin on a building across the street)
**User intuition, corrected to the real API:** Apple Maps' 3D buildings are display-only
(MapKit exposes no rooftop heights). The productized version of the idea is
**ARCore Rooftop anchors** — `createAnchorOnRooftop(coordinate:altitudeAboveRooftop:…)`
(SDK-verified) resolves the anchor against Google's 3D building model, the same
infrastructure as our Streetscape occluders; coverage = where Street View exists.
**Decision:** `GeoDrop.anchorMode` ("ground" | "rooftop"); composer "Anchors to" picker
(height caption becomes "above the rooftop"); `GeospatialEngine.requestAnchor` branches
to the rooftop future; live-edit re-pins keep the mode. **Instant-render fallback
(killer #1):** before the rooftop anchor resolves (or without VPS coverage), rooftop
drops render at ground + a nominal 8 m building height (compass tier AND transit), then
glide onto the real roof when the anchor lands — honest approximation over blank screen.
Shares the existing 100-anchor session cap with terrain anchors.

## ADR-041 — Precision placement: pin-to-spot in AR, sub-meter composer nudge, real imagery
**Date:** 2026-07-09 · **Status:** Accepted (field verification: FT-6 re-run)
**Field evidence:** "when I place the object at a certain location, it's not exactly
there." The error is a CHAIN: finger on a generalized basemap (±5–20 m) + view-time
localization (VPS ±1–5 m / GPS ±5–15 m). Both ends addressed:
1. **Pin to a spot (in AR — the precision king):** adjust panel → "Pin to a spot" →
   tap the real-world point in the camera → ARKit raycast → the drop re-homes there.
   Coordinate written back via **`GARSession.geospatialTransform(transform:)`** (AR pose →
   WGS84) when VPS is localized (~1–5 m absolute for other viewers; SDK-verified API),
   GPS+heading inverse-ENU fallback otherwise. Height recomputed at the tapped point
   (snap-to-0 within 30 cm); tapped Y ground-locked (ADR-027) so THIS session shows it
   exactly where tapped regardless of coordinate accuracy; VPS terrain anchor
   invalidated and re-pinned at the new coordinate; persisted through the library.
2. **Composer fine-tune:** "Fine-tune the spot" section — hybrid (satellite) mini-map
   + N/S/E/W nudge arrows at 1 m / 25 cm steps + undo; `place()` uses the adjusted
   coordinate. Map tab gets a standard⇄hybrid imagery toggle (pin on the actual gate,
   not the abstract street).
**Honest floor:** cross-device absolute accuracy is bounded by VPS (~1–5 m where
covered); pin-to-spot with VPS lock is the best achievable placement anywhere. For the
sender's own session the ground-lock makes placement exact.

## ADR-040 — Wave 6.2 loop v1: magic links, live reactions, Memory (the designed flow, in the app)
**Date:** 2026-07-09 · **Status:** Accepted (built; E2E field pass pending — the 6.2 gate is
10 real sender→receiver moments)
**Shipped:**
- **Night design language in SwiftUI** (`NightTheme.swift`) — 1:1 with the Figma "Night"
  variables (file vgZ4zrJmznuDoQFRkI8HMY); Bricolage Grotesque bundled (OFL, variable TTF)
  via supplemental `Config/Info.plist` (INFOPLIST_FILE merges with the generated plist —
  array keys like UIAppFonts/CFBundleURLTypes have no INFOPLIST_KEY_* form; the plist must
  live OUTSIDE the synchronized group or it double-produces Info.plist).
- **Share (01):** `ShareDropSheet` after compose + swipe/context on My Drops — recipient
  name, live map pin card, sets `visibility: "link"`, shares
  `augmentme://drop/<uuid>` with an invitation message (App-download invitation per the
  user's decision; AR-Quick-Look web page is 6.2b with Firebase Hosting).
- **Receive (02):** custom URL scheme → `ReceiveScreen` (invitation: sender ring-avatar,
  distance chip) → saves drop locally (`receivedViaLink`, viewer never re-uploads) →
  camera tab.
- **Watch/React (03/04):** `ReactionSession` state machine (watching → wrapping(15 s,
  hold-to-extend 30 s) → memory) + `ReactionOverlay` (LIVE presence pill, 4-emoji glass
  bar, sent toast). Reactions = docs in `drops/{id}/reactions` via `ReactionService`;
  sender listens on up to 10 of their link-drops (snapshot listeners — sub-second without
  push; FCM at paid membership) → in-app toast.
- **Memory (05):** wrap end captures ARView snapshot → polaroid keepsake screen (recap
  from the reactions subcollection, watched-seconds, Save to Photos, "Send one back" →
  map). Consent posture v1: AR-scene snapshot only, NO front-camera capture (clip consent
  UX is its own 6.2b item per PRODUCT-ROUTE §3D).
- **Model:** GeoDrop + `visibility`/`ownerUid`/`recipientName`/`receivedViaLink`
  (local-only, stripped on upload). **Firestore rules v2 required** (README): link/public
  readable by signed-in users; reactions creatable by their author. **User must paste the
  new rules — the receive flow fails without them.**
**Verification:** 38/38 on device; plist merge verified (scheme + font in built app).
Single-device loop test works via own link (fetch marks `receivedViaLink`; sender toast
suppresses self-reactions by design — cross-account test needs a second device/TestFlight).

## ADR-039 — Backend: Firebase (closes ADR-006); Wave 6.1 foundations shipped
**Date:** 2026-07-09 · **Status:** Accepted (user confirmed Firebase)
**Stack:** firebase-ios-sdk via SPM — **pinned 11.x** (ARCore 1.5x itself depends on
Firebase 11, so 12.x is unresolvable in this graph; revisit when ARCore bumps). Products:
FirebaseAuth + FirebaseFirestore. Config is **absent-tolerant**: `AppConfig.firebaseConfigured`
= `GoogleService-Info.plist` present in the bundle (gitignored, Support/, same pattern as
Secrets.plist); without it the app runs fully local exactly as before.
**Identity:** anonymous-first auth — every install gets a stable UID with zero friction;
Sign in with Apple upgrades the SAME account later via credential linking (blocked on paid
Apple Developer membership, which shipping needs anyway). Profile = trophy shelf
(`users/{uid}`: handle, displayName, momentsDelivered, reactionsReceived); seeded on first
run; edited from the new Profile tab.
**Drops:** `FirebaseDropStore` behind the existing `DropStore` seam (local JSON remains
offline truth). Schema: `drops/{dropId}` = GeoDrop fields + ownerUid + geohash(9) +
visibility(private|link|public) — recipients/public discovery ride the same schema in
Waves 6.2/7. Geo-queries: self-contained GeoHash utility (encode/decode/neighbors/
queryBounds, GeoFire prefix-range pattern) — 4 unit tests incl. the canonical
u4pruydqqvj vector and cover/exclude bounds checks. CloudKit store demoted to dead code.
**Verification:** 37/37 on device; app builds and runs with AND without the Firebase plist.
**User actions required:** create Firebase project + iOS app (bundle
com.adnan.augmentmereality), download GoogleService-Info.plist → `AugmentMeReality/Support/`,
enable Anonymous auth + Firestore in console (README steps added).

## ADR-038 — Commercial route accepted; PRODUCT-ROUTE.md governs Waves 6–10
**Date:** 2026-07-09 · **Status:** Accepted (route doc: PRODUCT-ROUTE.md, researched, sources inline)
**User decisions locked:** App Clip deferred to Wave 10 — invite link is an app-download
invitation; receiver reacts from the full app. In scope: profiles, public drops, premium
objects, auto-capture profile moments.
**Key researched calls:** (1) invite page uses **AR Quick Look** (USDZ from Safari, no app)
so the wow precedes the download wall; (2) the **reaction capture is the product's viral
asset** — share-out engine is the top growth feature; (3) premium objects are
occasion-emotional non-consumables (TikTok gifting economics), never coins/loot/NFTs;
(4) public drops ship only WITH the full App Store 1.2 safety kit + exclusion zones +
default expiry (WallaMe/Yik Yak graveyard lesson: density and abuse kill this class);
(5) reaction recording is consent-first, receiver-owned; (6) backend goes cross-platform
now — Firebase recommended, formalize as ADR-039 after a spike (closes ADR-006).
**Route:** 6.1 foundations → 6.2 the loop (5-screen design → SwiftUI) → 6.3 growth arrows
(share-out, widget, occasions) → 7 public layer → 8 marketplace → 9 trails/capsules/creator
beta → 10 App Clip + Android.

## ADR-037 — Ecosystem-verified heat ledger: person-seg sentinel, depth-on-demand, VPS coverage gate
**Date:** 2026-07-08 · **Status:** Accepted (v0.9)
**Method:** targeted research on the SAME stack/scenario (sources in the field report +
ADR-029): (a) community A17-class measurement — `.personSegmentation` costs **14–29
ms/frame** and continuous use triggers **thermal throttling in ~92 s**, matching our
"warning in ~2 min with content in view"; (b) **Apple's own doc**: disable people
occlusion at serious/critical thermal — i.e., even Apple treats it as the shed-first
heavy stream; (c) **Apple WWDC**: the sceneDepth ML fusion runs at a fixed **60 Hz**
internally whenever requested, regardless of consumer rate; (d) **Google's design
pattern**: ARCore features are disabled-by-default to save resources, and
`checkVPSAvailability` exists precisely so apps don't run VPS where there is no
coverage; (e) GitHub ARCore threads show the identical complaint for years with the
same resolutions: quality tiers, lower rates, enable-on-demand.
**Decisions:**
1. **Person-presence sentinel:** Vision `VNDetectHumanRectanglesRequest` at 2 Hz (tiny
   model) gates the ARKit person-segmentation stream — requested only while content is
   in view AND a human is actually in frame (5 s linger). Cost of the trade (stated):
   someone entering frame is drawn over for up to ~1 s before occlusion engages.
2. **sceneDepth on demand:** requested only for its real consumers — person depth-test
   active, or mid-field alignment with far content in full tier. No consumer ⇒ Apple's
   60 Hz fusion doesn't run.
3. **VPS coverage gate (Google's own pattern):** `checkVPSAvailability(coordinate:)`
   per ~300 m of movement; where coverage is absent (indoors), convergence sprints are
   skipped outright — 1 Hz retry only.
**Verification:** 33/33 device suite; acceptance remains FT-28 (10-min engaged indoor,
no person in frame → expect near-cool) and FT-31.

## ADR-036 — VPS convergence sprint is time-boxed
**Date:** 2026-07-08 · **Status:** Accepted (v0.9)
**Field evidence (decisive):** "worked till I did not place the object; once I placed
it, warning in 2 minutes." Idle tier (no content) was cool — the governor works. The
burner was the full-tier rule `isConverging ? every-frame : 15 Hz` (ADR-034):
**indoors VPS can never converge** (no street imagery), so placing content unleashed
GARSession feature extraction on every camera frame, 30 Hz, indefinitely — chasing an
impossible lock.
**Decision:** convergence full-rate is a **time-boxed sprint**: every frame for the
first 20 s of an attempt, 5 Hz to the one-minute mark, then a 1 Hz retry until the
convergence state actually changes (a new attempt gets a fresh sprint). Once locked:
15 Hz full / 10 Hz cruise as before. The capture format is now also os_logged so the
5-minute battery/tier/thermal log lines carry complete evidence.
**Consequence (stated):** stepping outside after a long indoor stretch, VPS lock can
take up to ~1 s longer to begin sprinting (the 1 Hz retry detects trackability, the
state change resets the sprint). Negligible against ADR-002's glide-in design.

## ADR-035 — Power ledger audit: range-based exclusivity for every neural net
**Date:** 2026-07-08 · **Status:** Accepted (v0.9; the FT-28 acceptance build)
**Field evidence:** heat persisted after ADR-034. Full-ledger audit concluded the defect
is the SUM: during any engaged session the app ran **three neural networks
simultaneously** (ARKit person seg 30 Hz; **Google Scene Semantics on every GAR feed —
enabled unconditionally at session start since v0.6**, though ADR-031 made it redundant
below 60 m; Depth Anything 10 Hz) plus TWO ARKit depth streams (`.smoothedSceneDepth`
requested and never consumed by any code path), LiDAR meshing, VPS matching, and a
full-screen post-process copy even with zero work. Each individually "justified"; the
architecture lacked **range-based exclusivity**.
**Decision — each occluder runs only when content exists in ITS band:**
- 0–5 m: ARKit person seg (only while content in view, ADR-034) + LiDAR mesh.
- 4–60 m: Depth Anything — now **5 Hz** (EMA'd matte reads identically), model
  **lazy-loaded on first actual need** (the ANE compile was a launch heat spike),
  `VNCoreMLRequest` reused.
- >60 m + transit: Google semantics — **off by default**, toggled at runtime via
  GARSession reconfiguration only while a drop is beyond 55 m or transit is active.
  In the common session (drops <55 m) Google's NN never runs at all.
- `.smoothedSceneDepth` request deleted (person pass/ground-snap/alignment all use raw
  `sceneDepth`; RealityKit's occlusion manages its own depth).
- The Metal pass **detaches its render callbacks** after 5 s with no job (idle pass ≠
  free: it forces offscreen render + full-screen copy per frame); pipeline cached,
  re-attach seamless.
- Asset preload delayed 10 s past launch (cold start already pays camera+VIO+VPS).
**Result on the ledger (engaged, content <55 m):** ARKit person+depth+mesh + VPS at
15 Hz *without* its semantics NN + DA at 5 Hz only when >4 m content — one NN steady
plus one at low duty, versus three at high duty before.
**Verification:** 33/33 device suite; field FT-28 (10 min engaged: fps + thermal) and
FT-31 (60 min mixed) are the acceptance gates.

## ADR-034 — Heat root-cause pass: video format bug, per-pixel waste, ML gating
**Date:** 2026-07-08 · **Status:** Accepted (v0.9; re-verify FT-28/31)
**Field evidence:** 3 minutes to `Device is hot` on iPhone 15 Pro Max, and the FT-27
finger-gap fix regressed at the same time. The regression is diagnostic, not separate:
at `.serious`, ARKit internally degrades its segmentation/depth quality — the gap
returned because the device was hot. Fix the watts, the edge quality returns.
**Root causes found and fixed:**
1. **Video-format selection bug (mine, ADR-030):** "nearest 30 fps" could select a
   4K@30 capture format — 4× the pixels through the ISP and through every ARKit ML
   model vs the 1440p default. *Hotter* than the 60 fps it replaced. Now: target-fps
   formats only, smallest resolution ≥720p, else keep ARKit's default. The active
   format is instrumented in the HUD metrics line and os_log — every future heat
   report carries the evidence.
2. **Guided filter ran 50 texture taps/pixel over ALL content pixels** — with
   screen-filling scaled content, billions of samples/s sustained on the GPU. Now an
   early-out resolves interior/exterior pixels from 1–5 taps; only the silhouette
   band pays full cost (~95% of the pass's work gone in typical scenes).
3. **Person-segmentation ML ran every frame whenever perception was active**, even
   against an empty viewfinder. Now requested only while content is in view (30 s
   linger so glance-away/back doesn't churn session reconfigs).
4. **GARSession (VPS+semantics+streetscape) fed every frame in full tier.** Every
   frame is only needed while *converging*; a locked scene now feeds at 15 Hz even
   during full engagement (anchor updates + matte labels are EMA'd; no visible cost).
5. **Thermal policy inverted (supersedes ADR-033's `.serious`→cruise clamp):**
   `.serious` no longer demotes the tier — it sheds by subsystem priority (GAR
   cadence → neural depth → semantic matte) so person occlusion and mesh survive
   while the user is engaged; `.critical` still forces idle. Rationale: dropping
   person occlusion mid-engagement is a visible quality failure; the shed order
   drops the least-visible watts first.
**Honesty (Pokémon GO comparison):** conceded in substance — 3 min to `.serious` on a
15 Pro Max was our defect, not physics. (PoGo's map mode is not camera-AR and its AR+
moments are short bursts; but the standard "engaged AR should not hit `.serious` in
minutes on a mild day" is correct and is the FT-31 bar.)
**Verification:** 33/33 device suite (governor thermal test updated to the new policy);
FT-28/FT-31 re-run pending — the HUD line now shows `fps · p95 · WxH@fps` so the
field report itself proves which format ran.

## ADR-033 — Power governor: heat is prevented, not reacted to
**Date:** 2026-07-08 · **Status:** Accepted (v0.9; field bar FT-31)
**Mandate trigger:** the user's launch bar — "users will keep it open for hours; with a
heating issue nobody will." Correct diagnosis of our failure: everything ran always
(VPS+semantics inference per frame, person segmentation per frame with nothing in view,
continuous LiDAR meshing, neural depth, full stack for 75 s of pre-warm on the map tab).
Prior thermal work (ADR-024) was *reactive* — shed after `.serious`. Sustained-cool AR
(the Pokémon-GO pattern) is *proactive duty cycling*: run each subsystem only in the
moments it earns its draw.
**Decision:** `PowerGovernor` (pure, unit-tested policy; injectable clock) computes a
tier from scene demand every tick:
- **idle** — camera hidden (pre-warm/tabs) or nothing rendered: camera+VIO+planes only;
  **no LiDAR mesh, no scene depth, no person segmentation** (config swapped via plain
  `session.run(config)` — no reset, anchors/world survive); GAR feed 2.5 Hz keep-warm;
  no neural depth; no matte.
- **cruise** — content exists but not engaged (out of view / settled): perception ML on
  (occlusion must be ready for the walk-by), GAR at 10 Hz maintenance, neural depth off.
- **full** — content in view <60 m, live editing, or VPS converging: everything, every
  frame.
Hysteresis: upgrades instant (quality first), downgrades wait 6 s (no flapping — pinned
by test). Thermal clamps the ceiling: `.serious` → ≤cruise, `.critical` → ≤idle. Battery
%, tier, and thermal state are os_logged every 5 min (`metrics`) — FT-31's instrument.
HUD chips `ECO`/`IDLE` make the tier visible in the field.
**Explicit non-goal (honesty):** full tier on a hot day will still warm the phone —
physics. The bar is: warmth only while the user is actively *in the moment* with
content, cool cruise/idle the rest of the session, and never `.serious` on a mild-day
1-hour walk (FT-31).
**Tests:** 9 PowerGovernor cases (tier rules, instant-up/slow-down hysteresis,
flap-immunity, thermal caps) — 33/33 suite on device 2026-07-08.

## ADR-032 — Launch-hang audit: no synchronous asset decode, ever
**Date:** 2026-07-08 · **Status:** Accepted (v0.9)
**Field evidence:** twice, pre-ADR-031 build: open app → camera → tap Room test → hard
hang (no back, no close, force-restart required), before the asset list appeared.
**Audit findings (SDK-verified):**
1. `Entity.load(named:)` (sync) is `@MainActor` + `noasync` in the SDK — Apple's own
   annotation: *"Synchronous Entity loading APIs block the main actor."* The
   ADR-021 on-tap fallback called it for any not-yet-cached model: a 31 MB scanned
   scene (Castle) decoding ON the main thread, additionally queued behind the
   in-flight preload's internal executor → effective multi-minute freeze. **Smoking
   gun.**
2. The launch preload (`Task { await preloadAnimatedAssets() }` from a MainActor
   context) serialized ~130 MB of decodes with main-actor assembly chunks right at
   launch — stutter/starvation exactly when the user first taps.
3. `bundledAnimatedAssets` re-scanned the bundle directory on every HUD render
   (Menu content evaluation).
**Decisions (all shipped):**
- **Zero synchronous loads.** All decodes via async `Entity(named:in:)` (iOS 18+;
  decode on RealityKit's internal background executor, awaits suspend) or Combine
  `Entity.loadAsync` (iOS 17). Grep-verified: no other loader calls exist.
- **Placement never waits:** a not-yet-decoded model gets an instant placeholder orb
  (killer #1: never an empty spot, never a blocked tap) + `requestAsset` kicks its
  decode; `onAssetLoaded` swaps the real model in place (pose/world-lock untouched,
  marker + grounding disc re-seated).
- Preload: sequential (memory-bounded), smallest-file-first, `loadingAssets` set
  dedupes preload vs on-demand.
- Asset catalog cached (bundle is immutable at runtime).
**Audit of other main-thread blockers:** AppConfig plist read (once, tiny — OK);
LocalDropStore JSON IO (small, async contexts — OK); streetscape mesh build on main
(known, ADR-016, profile in FT-18); Metal matte (GPU); mid-depth inference (own queue).
**Regression test:** FT-30.

## ADR-031 — Mid-field neural depth: Depth Anything V2, LiDAR-aligned (implements ADR-029 item 3)
**Date:** 2026-07-08 · **Status:** Accepted (v0.9; field verification FT-29)
**Problem:** the 4–60 m band has no depth on iOS (LiDAR ~5 m; Geospatial Depth is
Android-only per ADR-004), so occlusion there was class heuristics (ADR-018 semantic
thresholds) — trees/cars/fences either drew over or needed distance guesses.
**Decision:** bundle `apple/coreml-depth-anything-v2-small` (float16, 49 MB, in
`AugmentMeReality/ML/`, auto-compiled by the synchronized group to .mlmodelc — verified
in bundle). `MidFieldDepthEstimator` runs it via Vision on the Neural Engine at ≤10 Hz
(`midDepthHz`), never overlapping itself, off the render thread. The model's RELATIVE
depth is aligned to metric per run with a least-squares fit `1/lidar ≈ a·rel + b` over a
28×20 grid where LiDAR is trustworthy (0.4–4 m); the fit must be well-conditioned with
R² ≥ 0.6 or the sample is discarded — **failure falls toward draw-over, never toward
hallucinated occluders.** The shader (slot 11) reconstructs metric depth per pixel and
occludes content >4 m (`midDepthMinContentDistance`) when the surface is nearer by a
distance-proportional margin (`midRelBias` 12% — monocular error grows with range),
feathered across the margin; trusted only to 60 m (`midDepthMaxDistance`). Samples older
than 0.3 s (camera rotated away) are discarded. Gates: pedestrian only (in transit the
LiDAR alignment would fit the vehicle interior), thermal-shed at `.serious` (ADR-024),
armed only when some drop is beyond 4 m. HUD chip `DPT` when a live aligned sample
exists.
**On-device verification (2026-07-08):** 24/24 tests — model loads + predicts on the
ANE (518×392 Grayscale16Half out, ~7.4 s first-run ANE warm-up, ~17 ms steady per
ADR-029 source), alignment fit recovers synthetic (a,b) to ±0.02 and rejects
zero-variance data.
**Costs (stated):** +49 MB app size; ANE duty at 10 Hz (thermal-shed under load);
alignment requires LiDAR (non-LiDAR devices keep ADR-018 heuristics only).

## ADR-029 — Occlusion-quality research: edge refinement + monocular depth (PROPOSED)
**Date:** 2026-07-08 · **Status:** Proposed (research complete; build scope pending user)
**Trigger:** field verdict "blurs the edges and glitches when someone comes between the
object and the camera — feels unprofessional"; launch-blocking.
**Root cause (sourced):** ARKit People Occlusion ships a **256×192** person-depth buffer
matted up to a 1920×1440 stencil — the upsample IS the blurry edge, and frame-to-frame
segmentation instability IS the glitch/flicker. This is a platform limit, not our bug
([CoreML-in-ARKit occlusion writeup](https://rozengain.medium.com/using-coreml-in-arkit-for-object-segmentation-and-occlusion-988a6c7e18dd),
[Apple sceneDepth docs](https://developer.apple.com/documentation/arkit/arframe/scenedepth)).
**Researched fixes (primary sources, 2026-07-08):**
1. **Guided-filter / joint-bilateral edge refinement** — use the high-res camera luma
   as a guidance image to snap the low-res depth/matte to true object edges; linear-time,
   GPU-friendly, edge-preserving ([He et al. Guided Image Filtering](https://people.csail.mit.edu/kaiming/publications/eccv10guidedfilter.pdf);
   Kopf et al. Joint Bilateral Upsampling; [ACM Dynamic Occlusion Handling / edge-snapping depth](https://dl.acm.org/doi/fullHtml/10.1145/3359997.3365700)).
   We already own the Metal post-process pipeline (`SemanticOcclusionPass`) to host this.
2. **Boundary soft-blur** — Google's own ARCore guidance: feather the occlusion test at
   the silhouette so imperfect depth reads as a soft edge, not a glitchy hard one
   ([ARCore depth: "add blur to the occlusion test"](https://developers.google.com/ar/develop/depth)).
3. **On-device monocular depth (Depth Anything V2 Small, CoreML)** — dense sharp depth
   for the mid-field where LiDAR dies (>5 m) and for non-person objects (the 5–15 m
   tree / 5–35 m building draw-over gap in ADR-018): **17.4 ms/frame on iPhone 15 Pro
   Max**, Neural Engine, 49.8 MB float16, ~518×396 **relative** depth (needs scale
   alignment to LiDAR/geo) ([apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small);
   [Depth Pro (heavier metric alternative)](https://learnopencv.com/depth-pro-monocular-metric-depth/)).
4. **Niantic Lightship ARDK depth** — turnkey neural depth+occlusion beyond LiDAR range
   with built-in edge smoothing, any device, free tier, ARDK 3.13 Apr 2025
   ([Lightship occlusions](https://lightship.dev/docs/ardk/context_awareness/depth/occlusions.html)).
   Rejected as *localization* spine in ADR-001 (Wayspot coverage); depth is separable but
   it's a heavy second SDK duplicating capability we mostly have.
**Honesty bar:** no shipping AR makes person-through occlusion "perfect" — Apple and
Google both ship soft/feathered edges by design. Target is **professional-grade**
(clean, temporally stable, edge-snapped), reachable with (1)+(2); (3) closes the
mid-field draw-over. Recommend **(1)+(2) first on the existing Metal pass** (no new
deps, no extra heat), then **(3)** for the tree/building gap. Skip (4) unless (1)+(2)+(3)
prove insufficient.
**Thermal/fps context (same research):** cap render to 30 fps (Apple + field guidance:
users don't perceive 30 vs 60, halves CPU/GPU heat), duty-cycle heavy passes under
`.serious` (already ADR-024), long stress-test for throttling
([RealityKit performance](https://developer.apple.com/documentation/realitykit/improving-the-performance-of-a-realitykit-app)).

---

## Gap audit vs ENHANCEDMASTERPLAN (2026-07-07, v0.8 baseline)

| Mandate item | Status |
|---|---|
| L0 instant spawn, no gates | ✅ after ADR-003 fix (TTFO instrumented; field number pending) |
| Glide-only hand-offs | ✅ built (VPS glide 1.2 s; refinement slides) — field-verify |
| AR session pre-warm from map tab (§5.1) | ✅ built v0.7 (ADR-013, 75 s window) — TTFO field numbers pending |
| PrefetchEngine predictive spatial prefetch (§5.4) | ◐ local store is warm; cloud prefetch TBD with ADR-006 backend |
| LiDAR + person occlusion | ✅ built (v0.3) |
| Streetscape building occluders | ✅ built (v0.4) — field-verify with key |
| Scene Semantics matte + sky/building gating | ◐ v2 built v0.9 (ADR-018: per-pixel depth gate, class thresholds) — field-verify FT-11/FT-25 |
| Heading authority (VPS yaw > compass) | ✅ built v0.9 (ADR-017) — field-verify FT-24 |
| SilhouetteRefiner (feather + temporal EMA) | ◐ built v0.6 (confidence feather + EMA α=0.35) — shimmer measurement pending |
| Geospatial Depth | N/A on iOS (ADR-004) — Android build item |
| MotionClassifier + Transit Mode | ✅ built v0.8 (ADR-015: geo-relative frame loop, semantic-only occlusion, tunnel honesty) — field validation FT-13…17 |
| Metrics: TTFO ✅ (0 ms when pre-warmed), fps ✅, thermal ✅, frame-time p95 ✅, VPS-correction drift proxy ✅ | ✅ instrumented; field numbers pending |
| Cross-platform backend | ❌ open ADR (ADR-006) |
| Retention loop / moderation | ❌ Wave 6 (next) |
| Failure-mode hardening + automated tests | ✅ v0.8 (ADR-016): 21/21 on device; FIELDTESTS.md protocol FT-1…23 |

## ADR-051 — Wave B: the counsel's "dead headline features" fixes, implemented and adversarially re-reviewed (2026-08-12)

**Context.** The 2026-08-11 engineering counsel (COUNSEL-REVIEW-2026-08-11.md, raw in COUNSEL-RAW-OUTPUT-2026-08-11.md) found two headline features structurally off for most users and the session lifecycle unhandled. Owner approved Wave B (implement end to end, then re-convene the counsel on the diff). Wave A (security/compliance) is deliberately parked as the pre-launch gate.

**Implemented (finding → change):**
- **ARP-2** — `PersonSentinel` now passes `orientation: .right` to `VNImageRequestHandler` (portrait-locked rear camera; Vision defaults to `.up` and misses sideways people). The person-occlusion gate can actually open now.
- **ARP-1** — `GeoARSessionManager.supportsCustomPersonOcclusion` requires `.personSegmentation` AND `.sceneDepth`. Non-LiDAR devices fall through to `.personSegmentationWithDepth` (RealityKit built-in people occlusion — present, blurrier), and never pay for a stencil the Metal pass can't composite. `passNeeded` likewise excludes the pass on that hardware (review C7).
- **MATH-1** — `fitInverseDepth` returns an `InverseDepthFit` carrying its own support (`relMin/relMax`, `maxTrustedDepth` = farthest LiDAR reference × `midDepthSupportMargin` 1.25) and REFUSES fits whose band cannot reach `midDepthMinContentDistance`. The shader only decodes model outputs inside the rel support and inside the per-fit depth ceiling. **Consequence, accepted knowingly (review C8): ADR-031's "4–60 m" band is re-scoped to ~4–5 m — the honest ceiling of a 0.4–4 m LiDAR reference.** The scheduler only runs the ANE when content sits inside the serviceable band (`midDepthLiDARBandMax × margin`); reaching farther needs a farther calibration reference (Wave E, MATH-7: confidenceMap + robust fit ± mesh/geospatial references). A refused fit no longer blanks a still-fresh sample (`invalidateIfStale`, review C15).
- **MATH-2** — the shader's content-presence test is metric: decode first, then `0.02 m < d < contentFarPlane`, where `contentFarPlane` is derived per frame from the projection's own boundary decodes (cleared pixels decode to the far plane or non-finite, both conventions covered; no NDC epsilon). **RealityKit ARView exposes NO public AR-mode far-plane override (verified against the iOS 26.5 SDK swiftinterface)** — the >1 km frustum question is instrumented instead: the decoded far boundary is os_logged (`matte` category) so FT-15 field evidence shows whether far drops are inside the frustum. If it proves capped at 1 km, far-content re-projection is a Wave E design item.
- **MATH-3** — `LocationService` publishes `headingIsTrueNorth`; magnetic-only samples may seed (ADR-003 instant spawn) but never refine; the first true-north sample replaces the seed at alpha 1 and frees the re-sync refractory. Per review C1/C14 the magnetic bail-out sits AFTER the pan-gate bookkeeping so ADR-017's pan rejection still guards the re-seed. WMM declination model = Wave E.
- **PBS-3** — the sender reaction subscription is keyed on the IDENTITY of the watched set (`ReactionService.listenKey`, shared predicate `watchedDrops`), not the drop count; sharing (an in-place mutation) now restarts the listener. `startedAt` stamps once at service creation (final check F6). Cross-account field test added (FT-36) — ADR-040's untested gap.
- **SWE-1/ARP-5** — scene-phase `.active` resumes a session suspended with the cover up (`ARSessionHolder.appDidBecomeActive`, which also restores `markCameraVisible` — review C10/C16 or the governor pins idle). `GeoARSessionManager` is the `ARSessionDelegate` (NSObject-based now): interruption/end, `didFailWithError` (camera-unauthorized = terminal; else recover, rate-limited with a DEFERRED retry consumed by tick — review C6/C13/C18, F3: never while the surface is hidden), `sessionShouldAttemptRelocalization` = true, tracking-state → relocalization-stall bookkeeping. `isInterrupted`/`sessionFailed` hold the tick, frame updates, GAR feeding and status writes (C9/C19, F2). The reveal signal only trusts frames captured after the (re)run (F5).
- **ARP-4/SWE-2** — `resumeSession` re-runs the SAME configuration with no options (world map, placements, ground locks, heading survive; ADR-013/043 honored); reserved reset lives only in the cold paths, which now call `GeospatialEngine.invalidateAllAnchors()` (GARSession survives resets — ARCore iOS ≥ 1.38, researcher-verified — anchors do not). Per-request `inFlightAnchorTokens` make stale terrain/rooftop completions discard their anchor instead of resurrecting it (review C2/C4/C12). Relocalization stalls > 10 s fall back to a cold restart; a failed session always cold-restarts on resume (F1). Placement basis latches only from `.normal` tracking, never destroys an existing basis, and limited-tracking ticks don't churn placements (ARP-5 + review C3/C5/C11/C17).

**Verification.** Two counsel rounds on the diff: round 1 — 4 reviewer lenses (math, AR platform, regressions, spec-completeness; the Swift-systems agent died on an API error), 19 findings each adversarially verified by an independent skeptic, ALL confirmed, deduped to 7 clusters, all fixed; round 2 — a fresh Swift-systems lens over the amended code: 6 findings (F1–F6), all fixed; it explicitly verified sound: delegate-hop Sendability, NSObject+@MainActor conformance, flag-pair clearing, interruption-ordering, churn-guard case table, anchor tokens, listenKey cost. Build + **55/55 unit tests on Muhammad's iPhone (2026-08-12)** — 7 new tests (MATH-1 support band ×3 incl. the "0.4–4 m fit must never claim street range" regression; PBS-3 listener key ×5 minus overlap). New field tests FT-34–FT-37 (person occlusion engages; interruption resume with placements intact; cross-account reaction toast; cold-start heading honesty). Ops note: Xcode 26.6 required re-downloading the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).

**Not done here (deliberate):** Wave A parked for pre-launch; declination model, GNSS filter, robust depth fit, terrain altitude = Wave E; listener pruning, cover collapse, render-thread lock = Wave D; state-machine extraction + lifecycle tests = Wave F. MATH-9's report row still says "4× ProMotion" — researcher corrected to 2×; carry that into Wave E.

## ADR-052 — Wave C "make failure visible": iterative counsel-driven hardening, rounds 1–7 (2026-08-15 → 2026-08-17, IN PROGRESS)

**Context.** Wave C implements the counsel's silent-failure findings (ARP-3, SWE-3/6/8/9/14, PBS-4/7). Owner mandated a permanent counsel format: exactly 5 agents on Opus (4 staff Swift/AR reviewers who also write industrial test cases + 1 industry researcher), supervised by the senior staff engineer who builds fixes in rounds, with an owner gate after every counsel round. **`COUNSEL-WAVE-C-LOG.md` (repo root) is the authoritative state + round-8 backlog; `counsel-archives/` holds the full verdicts.**

**Built through round 6 (all on device, 76/76 tests):** LocalDropStore actor + per-row failable decode + digest-deduped sidecars + durable incident journal + `LocalLoadOutcome` diagnostics protocol; DropLibrary pending-acknowledged sync pipeline (per-drop generations, durable pending/terminal/tombstone/unresolved sets in injected UserDefaults, refresh generations, outcome-gated reaps, tombstone retirement, account-change revalidation); `FirestoreAcked` single write seam v2 (bounded 10 s, cancellable, three-valued acked/queuedLocally/rejected) used by drops, deletes, profile, reactions; reaction ritual/receipt split (wrap on tap; delivery pill sending/delivered/queued/failed with per-send tokens); seed single-flight; CTA/banner honesty surfaces (create alert, share refusal, Profile ladder, Sent banners + per-row badge, AR persistError channel with severity, global backstop banner); ARP-3 unconditional farMode + transition-site disarm; SWE-6 negative cache + render-time announcements; **`web/firestore.rules` v3 committed + wired into firebase.json — DRAFT, must NOT deploy until B5 corrections + emulator tests (Wave A gate)**; test harness rebuilt (injected defaults suites, gated actor doubles that park mid-flight, reaction-session token tests).

**Verified closed by counsel round 7 (code-traced):** the round-5 criticals — reaction-session stranding (closed redundantly: ritual is network-independent AND the seam is bounded) and the immortal delete tombstone (retirement + unresolved quarantine + redemption, non-vacuously tested). Registry/generation machinery survived all constructed interleavings.

**Open (round 8, owner-gated):** blockers B1–B6 per the log — headline: the terminal-verdict producer cannot fire on real server refusals until Firestore error codes are classified and the server-stamped ownerUid is persisted locally (B1, single highest-leverage change); MemoryScreen fabricates delivery receipts (B2); tombstone retirement trusts cache-served reads (B3 → per-document server-sourced check); "Synced" as fallthrough (B4); rules-v3 drift vs shipping client (B5); share-retry uploads unshared mutation (B6).

**Counsel-established engineering rules now binding on this repo:** defaults resolve to UNKNOWN (good states need positive evidence); negative facts need per-object positive checks; nothing destructive keys on cache-satisfiable reads; verdicts revoked only by their issuing authority; ritual vs receipt; test doubles reproduce production isolation/suspension; durable sets ship only with producer test + retirement test + surface + user control + Synced-precondition.

**Round 8 BUILT (2026-08-17, 90/90 device tests + 28/28 emulator rules assertions):** all six blockers plus the scheduled seams, in the researcher's order. **B1** — `DropStoreError.refusedByServer(reason:)` produced by `DropStoreError.terminalRefusalReason` (Firestore domain, gRPC 3/5/7/9/16 terminal; 4/8/10/13/14 stay retryable; foreign domains never); `DropStore.save` returns the canonical stored drop and `performCloudSync` persists the server-stamped `ownerUid` through `local.save` after every ack (the pre-check's field is no longer nil on disk); `fetchSharedDrop` no longer marks the owner's own link-open as `receivedViaLink` (state-6 interim). **B2** — MemoryScreen takes the live `delivery` outcome; my-reaction line renders SENT/QUEUED/NOT SENT/SENDING distinctly; the fabricated-DropReaction fallback is deleted. **B3** — `DropAbsenceVerifying.serverConfirmsAbsent(id)` (per-document `getDocument(source: .server)` → `!exists`; any throw = no proof) is now the ONLY tombstone/unresolved retirement evidence; the uid-scoped set-difference is deleted; `CloudDrop` decodes leniently (envelope `decodeIfPresent`) and propagates envelope ownerUid; the dead `notFound` delete branch is removed (Firestore deletes are idempotent). The "never-tombstone-a-never-acked-drop" sub-item was deliberately NOT implemented as a skip-guard: with Firestore's durable local write queue a staged create can flush after the skip decision and resurrect server-side; the per-document retirement self-cleans never-existed tombstones in one refresh instead. **B4** — `hasCompletedCleanRefresh` positive-evidence latch (clean local load — or absent file with NO journaled incident, i.e. a brand-new store — AND an answered cloud read); Profile ladder order: terminal → unresolved deletes (new surface) → local-read warning → un-pushable pending count (new problem count) → sync error → uploading → "Checking sync status…" → "Synced" earned last. The brand-new-install case was caught by this round's own test (absent file initially earned nothing → first-launch users would never see "Synced"); fixed via the incident-journal distinction. **B5** — rules emoji list = `ReactionSession.reactions` verbatim; `get` answers on absent docs (fetchSharedDrop + retirement probe need it); reaction create drops the parent-visibility `get()` (capability model: unguessable UUID + author stamp + fixed keys + emoji list; structural relocation stays a residual); NEW `web/rules-tests/` npm harness — `drift-check.mjs` parses both sources and fails on emoji drift, `rules.test.mjs` = 28 emulator assertions (get-on-missing, hijack denial, ownerUid immutability, absent-delete ack, every UI emoji writable, forged-author/extra-keys/out-of-list denials, moderation deletes, list-enumeration denial) — RUN GREEN locally (OpenJDK via Homebrew); re-running it is the Wave A deploy gate. **B6** — `retrySync(drop)` (persisted form), never `sharedDrop`. **Seams:** FirestoreAcked `race` is internal and cancellation resolves `.queuedLocally` (iterator-nil ambiguity closed) with a 4-outcome Firebase-free test suite; AccountService retires the queued-offline statusText on a server-sourced snapshot; ReactionService sender toast uses a per-listener primed-set watermark over `documentChanges` (client-clock cutoff deleted — queued reactions flushing after a sender relaunch now toast); `acknowledgeReadIncident` owns a generation; the delete pipeline carries the save pipeline's generation discipline (`deleteGenerations`; redemption bumps + cancels so a stale refusal can't suppress a redeemed drop). **Counsel round 9** launched on the diff (5× Opus, run `wf_86508b10-ef7`, closure verdicts per blocker required) — verdict pending at the owner gate.

**Counsel round 9 verdict (2026-08-17, 5× Opus run `wf_86508b10-ef7`, archived `counsel-archives/wave-c-round9-*`):** closure audit — B2, B6, seam-1, seam-4, ux-6 and the delete-generation discipline **unanimously CLOSED with code traces**; B1/B3/B4/B5/flows-4 PARTIAL. 28 findings + 3 researcher own-finds; 4 CRITICALs; ship verdict **NOT as-is** with a five-change minimum-to-ship: (1) read PROVENANCE (`snapshot.metadata.isFromCache`) gates every positive claim — B4's evidence latch is currently cache-satisfiable; (2) explicit `redeem(_:)` entry point — the state-6 interim fix lets a fetched pre-edit copy overwrite an unsynced local edit and killed tombstone redemption for stable accounts; (3) deployed-rules honesty — under live v2 rules `serverConfirmsAbsent` can never answer true, so offline deletes become a permanent alarming ladder claim; fix = v3 deploy as release gate + durable `ackedCloudIDs` + never-acked deletes resolve to done + startup capability probe; (4) Memory recap provenance + own-uid exclusion; (5) `retrySync(by id)` resolving live rows. Round-10 backlog recorded in COUNSEL-WAVE-C-LOG.md; owner gate open.

**Round 10 BUILT (2026-08-17, 96/96 device tests + 30 v3-draft + 5 deployed-v2 emulator assertions + drift lock):** the round-9 minimum-to-ship five, plus the schedulable findings. (1) **Provenance** — `CloudRead`/`ProvenancedDropStore`: `snapshot.metadata.isFromCache` travels with every cloud read; the B4 evidence latch is earned only by SERVER-served reads (cache rows still merge for display); (2) **`redeem()`** — the receive flow's single entry point: always retires the delete blacklist (link-receipt = redemption, ownership-independent), never overwrites a pending local edit in memory or on disk, never re-uploads a viewed drop; `update()` is editor-only again; pending/tombstone mutual-exclusion invariant asserted in the mutators; the reap skips tombstone-suppressed ids; (3) **deployed-rules honesty** — the LIVE v2 ruleset checked in as `web/firestore.rules.deployed` with its own emulator suite pinning the denials the client must survive (and v2's hijack defect, so a silent redeploy is noticed); durable `ackedCloudIDs` ("server has seen this id") sourced from save acks + server-served refresh rows; bounded delete refusals now resolve NEVER-ACKED ids as done (no false cloud-copy alarm) while acked ids still go unresolved-visible; `probeAbsenceCapability` (random-UUID server get → answers/denied/inconclusive) latches per session, retirement probes skip under denied, cap at 5/pass, and run AFTER reconcileCloud; (4) **Memory recap truth** — `ReactionRecap` with server-answered provenance, pending-write filtering, own-uid exclusion; offline renders as UNKNOWN copy, never zero; (5) **`retrySync(id:)`** — retry resolves the live row; ShareDropSheet reads `liveDrop` and its refusal caption dies with its verdict. Also landed: incident journal is acknowledge-only (own-1 partial); checked backup-claim copy (lens-6); two-phase refresh publish (own-2); acknowledge kicks a refresh (ux-3); evidence resets on account change (lens-4); EncodingError → terminal refusal (seams-2); no-yield stream ends never fabricate `.acked` (seams-6); lenient + server-sourced `fetchSharedDrop` (seams-7/lens-7/flows-6) with ReceiveScreen gone-vs-unreachable + retry; dead reaction listeners re-attachable + watched-set pruning (flows-5); un-pushable rung gated on known state (ux-4); honest seed-failure copy (ux-7); reactions-LIST + users-absent-get emulator assertions (seams-8). Deferred with recorded reasons: serverTimestamp toast watermark (seams-5/flows-4 — rules key-list must move first), merge field-mask (seams-3), single-field ownerUid stamp (lens-5), reap-on-deleted-ids-record (own-1 full), probe backoff (own-3), sender reaction surface (ux-5), journal second medium (lens-2). **Counsel round 11** launched on the diff (5× Opus, run `wf_369b307d-597`) — verdict pending at the owner gate.

**Counsel round 11 verdict (2026-08-17, 5× Opus run `wf_369b307d-597`, archived `counsel-archives/wave-c-round11-*`):** closure audit — ux-1 (provenance latch), ux-2/flows-2 (ReactionRecap), flows-3 (retrySync-by-id), seams-2/6/7/8, ux-3, ux-7 and the deployed-rules pin **verified CLOSED**, several with the counsel executing the proofs themselves (emulator runs, npm test). 25 findings + 2 researcher own-finds; ship verdict **NOT as-is**, but explicitly "the mechanisms are largely right; what fails is where they are WIRED — short, surgical, one more round rather than a redesign." Four blockers: (1) receive-flow verdicts inverted against the live v2 rules — absent/private docs DENY, so "you're offline, try again" renders for genuinely-gone drops while "expired" is only producible client-side; fix = three-valued SharedDropFetch (.found/.absent/.unknown) + auth-gated initial load; (2) researcher own-A CRITICAL — redeem() cannot recall a delete already staged in Firestore's durable mutation queue: delete offline → reopen own link → local restore + cloud copy destroyed on reconnect; fix = post-redemption re-upload for own drops (queue serializes save after delete); (3) RootView's auth-ready pass wipes the evidence latch it just earned (three reviewers converged) — ladder pinned at "Checking…", the ux-4 rung unreachable; fix = composed authDidBecomeReady(uid:) resetting only on a real uid change; (4) redeem()'s pending-edit guard is structurally empty (received drops are never pending) and its mirror discards the drop when the pending id has no row; fix = one predicate: row exists → keep, no row → insert+save. Same-pass recommendations: additive phase-1 publish (cloud rows currently blink out every refresh, tearing AR entities), per-row acked provenance (markAcked currently fabricable from latency-compensated rows — REPRODUCED on the emulator: fromCache=false with 397/401 rows hasPendingWrites), cloudProvenIDs at tombstone time, quarantine-Dismiss-earns-Synced closure. Round-12 backlog recorded in COUNSEL-WAVE-C-LOG.md; owner gate open.

**Round 12 BUILT (2026-08-17, 107/107 device tests + 30 v3 + 5 deployed-v2 emulator assertions + emoji AND reaction-key drift locks):** all four round-11 wiring blockers plus the same-pass set. (1) **`SharedDropFetch` tri-state** — `.absent` claimable only from a server-served `exists == false`; permission-denied/unauthenticated/unconfigured/decode-failure are all `.unknown` with non-causal, retryable copy; the receive fetch waits for anonymous sign-in. (2) **staged-delete recall** — redeeming one's own deleted drop re-enqueues its upload; Firestore's serialized mutation queue recreates the document behind any staged delete, and pendingSyncIDs covers the window. (3) **`authDidBecomeReady(uid:)`** — evidence resets only on a REAL uid change (tracked in `evidenceUid`); the composed pass ends with the evidence its refresh earned; scene-active refresh added. (4) **redeem's one predicate** — an existing local row is authoritative (the old pending-guard was structurally empty); no row → the fetched copy is the last copy and is restored to memory and disk. Same-pass: additive phase-1 publish with phase-2 gated on a COMPLETED cloud read (no more blinking cloud rows / stranded empty library); per-row `serverConfirmedIDs` so latency-compensated rows can't earn the acked fact (the emulator-reproduced hole); durable `cloudProvenIDs` captured at tombstone time (proven → visible unresolved alarm, unproven → resolved done); delete-refusal taxonomy (transient failures spend no attempt budget); durable incident memory independent of the journal file (dismissing a quarantine can no longer launder the library into "Synced"); `lastSyncError` revocable only by a server-served read; acknowledge-accepts-the-loss store rewrite for skipped rows; honest Memory offline copy; listener pruning keyed on the full shared set; FIRST-IN badge timed over all confirmed reactions; live share preview; `remove()` post-await generation re-check; ladder copy corrected. **Counsel round 13** launched on the diff (5× Opus, run `wf_2b9f2ac5-0c2`) with a WAVE EXIT assessment requested — verdict pending at the owner gate.

**Counsel round 13 verdict (2026-08-17, 5× Opus run `wf_2b9f2ac5-0c2`, archived `counsel-archives/wave-c-round13-*`):** 12 of 17 audited round-12 items **fully CLOSED with non-vacuous tests** — including the staged-delete recall (verified against real SDK semantics: merge-set upserts recreate the doc behind the serialized delete), the redeem predicate, additive phase-1, per-row acked provenance ("exactly the right latency-compensation guard"), and the delete taxonomy ("strictly safer"). 18 findings + 3 researcher own-finds reduce to **four wiring defects inside round-12's own additions** (~40 lines): remove()'s post-await guard keys on the GLOBAL generation so any concurrent refresh silently abandons a delete after the disk row is gone (CRITICAL); the cloudProven predicate counts a REFUSED write as proof the server holds the doc (permanent false alarm) and leaks entries for received drops; the receive flow's uid gate became an unbounded spinner when sign-in stalls; and Dismiss now irreversibly deletes unreadable rows without consent while the reap+memory launder the loss into "Synced" — fix = non-destructive dismiss + a durable `lostRowIDs` ledger with a rung above "Synced" (the charter's last live hole: a loss that leaves no record). The researcher names the recurrence pattern ("the fix contains the next defect", two rounds running) a COVERAGE problem: the test doubles reproduce production's isolation but not its FAILURE MODES — FlakyLocalStore gains a save-failure knob and a delete gate, and the three unreachable branches must each have a test that enters them, as a non-optional ship condition. **WAVE EXIT ASSESSMENT: "Wave C can close after one more build round; a seventh review round is not warranted"** — the wave's structural work (provenance-gated claims, durable per-object verdicts, ritual/receipt, reachable honest-unknown, pinned deployed rules) is done. Launch-gates regardless of the wave: the v3 rules deploy (a SECURITY gate — production today lets any signed-in stranger overwrite any drop, pinned by the deployed suite), encoder-shape drift protection before that deploy, day-after re-verification of `.gone` and retirement un-latching, the "One-time link" copy, the SIWA migration decision, and version control + an enforced test gate. Round-14 backlog recorded in COUNSEL-WAVE-C-LOG.md; owner gate open.

**Round 14 BUILT — the wave-exit round (2026-08-17, 112/112 device tests + 30 v3 + 6 deployed-v2 emulator assertions + both drift locks; initial git commit `5bb6ea5`):** every round-13 exit condition executed. The four blockers: (1) a refused write no longer counts as proof the server holds a document — the terminal clause left the cloudProven predicate and the capture moved below the received-drop guard, killing the permanent false delete alarm and the ledger leak; (2) per-row mutation epochs (`rowGenerations`) replace the global-counter guard — a concurrent refresh can no longer silently abandon a delete after the disk row is gone, and only a genuine same-row mutator (e.g. a redeem) supersedes it; (3) the receive flow's sign-in wait is bounded at 10 seconds and falls through to the honest retryable state — no more unbounded spinner on the acquisition path — and "Connecting…" can no longer mask real problems on the ladder; (4) Dismiss is NON-destructive (content-digest suppression; the unreadable rows stay on disk) and the new durable **loss ledger** (`lostRowIDs`) records destroyed rows BY ID at the moment of destruction, immune to dismissal, reaps and evidence latches, surfaced as its own Clear-able rung above "Synced" — closing the charter's last hole: a loss that leaves no record. Also: redeem persists disk-first with the staged-delete recall above the rethrow; the drift protection is fail-closed with the emulator payload derived from the app's own struct and an on-device encoder-shape lock; terminal verdicts revalidate on every session's first auth pass (caller-less accountDidChange deleted); the listen key follows the full shared set; the "One-time link" overclaim is gone. The counsel's coverage mandate is met: FlakyLocalStore now reproduces FAILURE MODES (save-failure knob, delete gate) and the three previously-unreachable branches are each entered by a test. **Process:** the repo is under version control with the drift locks as a pre-commit hook and no secrets tracked. **Counsel round 15** (owner-ordered) is auditing the exit conditions now — its wave-close ruling lands at the gate.

**WAVE C CLOSED (2026-08-17, counsel round-15 ruling — run `wf_a3fe46ce-6de`, archived `counsel-archives/wave-c-round15-*`):** the closure audit verified every round-13 exit condition met (the sole exception was the documentation restatement, completed in the closing commit as the counsel prescribed). Ship verdict, verbatim substance: **SHIP the round-14 build** — all four round-13 blockers (two CRITICAL) genuinely fixed at the mechanism level with non-vacuous, branch-entering tests; no constructible data-loss or fabricated-success path through any of the six priority items; **zero CRITICAL and zero HIGH findings survived verification**; the highest confirmed defect is a MEDIUM UI-honesty pair (inert ledger Clear; loss rung below a progress rung) carried as pre-listing residuals with ten others, none re-opening a settled mechanism. Over seven counsel rounds Wave C delivered its charter: read/write provenance gates every positive claim; verdicts are durable, per-object, revoked only by their issuing authority; ritual and receipt are separate; the honest-unknown state is reachable on every surface; destroyed data leaves a durable, user-controlled record; the deployed ruleset is pinned in-repo with its client dependencies asserted; and the test harness reproduces production's isolation, suspension points and failure modes. Final state: 112/112 device tests; 30 v3 + 6 deployed-v2 emulator assertions; two drift locks wired as a pre-commit hook (`scripts/install-hooks.sh` bootstraps fresh clones); repository under git. **The Wave A v3 rules deploy remains THE security gate before launch** (production today allows cross-user drop overwrite, pinned as passing by the deployed suite). Next wave on the owner's word: Wave D (concurrency + heat), per the original counsel ordering.

## ADR-053 — Wave D: concurrency & frame-budget, counsel-supervised (2026-08-17, IN PROGRESS)

**Context.** Wave C closed (ADR-052). Wave D takes the original counsel's concurrency/heat cluster — the intermittent, timing-dependent class that survives field testing: ARP-11/SWE-4 (render-thread races in the post-process pass), ARP-6 (format-picker heat), ARP-7 (main-thread mesh stalls), ARP-12 (capture-pool pressure; researcher-corrected fix direction — copy-out, never retain frames), SWE-11 (stateful mesh discarded every tier cycle), ARP-8 (transit meshing with no consumer), SWE-5 (mid-drag identity + governor pin), SWE-7 (stacked covers dropping presentations), SWE-10/PBS-9 remainder (listener teardown).

**Round 1 build (130/130 device tests, 18 new):** SemanticOcclusionPass under one lock (`@unchecked Sendable`, detach kept as the heat fix per ADR-035 with the lock making it safe) + per-frame `CVMetalTextureCacheFlush` + bail-path wrapper release; `pickVideoFormat` pure double-bounded policy (fps ≤ target, 720p…1920×1440, loud UNCAPPED marker) with the 4K@30 refusal table-tested; streetscape mesh extraction+generation on a background queue with stale-landing guards and logged failures; depth-estimator copy-out into app-owned buffers (frame never retained; PersonSentinel's brief bounded hold deliberately kept — for counsel judgment); `perceptionPlan` pure function — reconstruction is a stable axis (camera-visible ∧ pedestrian ∧ ¬thermal-critical), requests derive from uses (transit sheds meshing + mid-field depth; non-custom hardware never requests sceneDepth for person), 10 s downgrade hysteresis, `occlusionActive` now live state; `editingDropID` gesture identity + frozen nearest + `removePerDropState` single cleanup helper; single `fullScreenCover(item:)` Destination enum with compat accessors, one-change onboarding hand-off, queued deep links; reaction listeners torn down on scene background. The camera-hidden totality test CAUGHT a plan hole during the build (mid-field depth without camera visibility) — the plan was hardened, not the test. Counsel round 1 (5× Opus, run `wf_2e45cb82-519`) reviewing; verdict pending at the owner gate.

**Wave D counsel round 1 verdict (2026-08-17, 5× Opus run `wf_2e45cb82-519`, archived `counsel-archives/wave-d-round1-*`):** verified genuinely closed — ARP-7 ("correct and complete"), the researcher-corrected ARP-12 direction (copy-out + per-frame flush, with the flush PROVEN safe against the retained-wrapper array), ARP-8's transit legs, SWE-5's gesture-identity half, SWE-10's mechanism, and the pure-function extractions ("the right industrial shape"). 35 findings + 2 researcher own-finds; ship verdict NOT-as-is. **Four blockers, three introduced by Wave D's own fixes:** (1) the occlusionActive live-state migration reached one consumer but not window-mode's re-insert guard — a window exit during a momentary reconstruction shed drops `.occlusion` permanently while paying full meshing watts (deterministic hard-bar breach); (2) both matte history textures are `.private` and never initialized — a NaN/Inf EMA seed is absorbing under mix(): permanent per-pixel occlusion death, ~1/32 of random 16-bit patterns; (3) heat re-attacked: `.sceneDepth` requested from an unbounded distance predicate for a consumer serviceable only at 4–5 m (the exact request≠use shape the fix claims retired), and an unfinished slider gesture (cover torn down mid-drag) still pins the governor to `.full` forever; (4) 100%-reproducible first-run break: the single-cover model destroys OnboardingView's @State on the beat-2 hand-off — beat 3 unreachable, each loop leaking a fireworks emitter (researcher's own find). Plus RENDER-1: the renderCallbacks closure slots remain the one UNlocked cross-thread mutation actually live in production (the lock hardened a dead path) — needs the detach dwell floor + a TSan device run before the 99.5% crash bar is signable. Round-2 backlog = researcher's priority order (29 items, minimum-to-ship named); FT-28/FT-31 must re-run after, because three findings produce heat/fps signatures indistinguishable from thermal throttling under current instrumentation. Owner gate open.

**Wave D round 2 BUILT (2026-08-17, 140/140 device tests, 10 new):** all four round-1 blockers plus twenty scheduled findings. The blockers: the occlusion option is now DERIVED every tick from a pure predicate (transitions set only their own flags — the window-exit permanent-occlusion-loss interleaving is unrepresentable); the matte history is gated by a `historyValid` uniform (fast-math-proof; the undefined-memory NaN seed can never be read); the perception plan uses the mid-field CONSUMER's real predicate (serviceable 4–5 m band + thermal-serious term, shared static with the use side) plus capability terms (the plan can only desire what hardware delivers — the non-LiDAR chip lie is gone); abandoned slider gestures terminate (1.5 s tick expiry + explicit cancel on camera-hidden/suspend); and the onboarding beat lives on the router (beat 3 reachable; the demo is idempotent via clearRoomDrops). Also: suspend resets the perception scheduler and resume computes ONE fresh plan; visibility grace keeps the mesh across sub-5 s tab flips; strict edit-target resolution makes the vanish-guard live code; per-drop removal invalidates engine-side anchors; ground snap declines honestly without a real surface; the pass has a detach dwell floor; every encode exit and detach releases capture wrappers; Metal state builds outside the lock; buffer copies run off-main into pools and release ARKit's buffers before inference; the reaction watermark is durable (missed-while-backgrounded reactions surface); mesh builds are budgeted nearest-first with pre-extraction relevance; the deep-link machine promotes from every stage-clear; the camera cover is escapable in every render branch; toasts render inside covers; Home's card starts the watch session. Counsel round 2 (5× Opus, run `wf_8714e9bf-0ef`) auditing closure with a wave-exit assessment; verdict pending at the owner gate.

**Wave D counsel round 2 verdict (2026-08-17, 5× Opus run `wf_8714e9bf-0ef`, archived `counsel-archives/wave-d-round2-*`):** closure audit — **69 CLOSED / 16 PARTIAL** across the round-1 ids; all four hard round-1 blockers verified closed with the proofs recomputed (historyValid layout parity offset-by-offset; ping-pong pairing; SourceBox releasing strictly pre-inference; lock order honored in practice). 13 new findings, ZERO critical; ship verdict NOT-this-build with **round 3 scoped to exactly six surgical items**: STATE-L1 (the 1.5 s gesture terminator fires on a stationary-finger drag and the still-live gesture re-binds to a DIFFERENT drop — a wrong-drop persist to disk and Firestore, reachable from the panel's own designed interaction); ARPCFG-R2-1 (the visibility grace expires just BEFORE the 5 s pause it exists to cover — half of tab flips still destroy the mesh; fix = true-edge stamp AND grace > pauseGrace + one tick); UX-3 (the ground-snap decline was wired into the CRITICAL persist-error slot, evicting real data-loss messages — one-word fix today, advisory channel later); UX-1 (the cover-scoped toast makes an unguarded cancellation-clear reachable); RENDER-LENS-1 (the dwell floor's min-attach conjunct is provably dead — idle-only 15 s; re-derive as idle 5 s + min-attach 10 s, table-tested); ARPCFG-R2-2 (resume omits the camera-visibility term — warm-up resumes fire two session.runs). Root-cause note the counsel nailed: every slipped defect is a time-quantized clock/timer/predicate coupling whose tests supplied the quantized input as a LITERAL — round-3 tests must drive the CALLER's clock. Six non-gating items carry to the Wave E backlog (capability term on the depth-model USE side chief among them) with their false invariant comments corrected in round 3. **Wave-exit ruling: Wave D cannot close on code review alone — the four bars (crash-free, ≥30 fps, thermal, zero draw-over) are EMPIRICAL and unmeasured; closure = round 3 + the owner's field runs (on-device TSan, FT-28/FT-31) returning numbers on that build — with RENDER-LENS-2's hold-measurement fixed FIRST so the instrument doesn't blame thermal throttling.** Owner gate open.
