# AugmentMeReality — Enhanced Master Plan (v2, Industrial)

*Pin virtual 3D things to real-world places. Anyone who faces the camera there sees them — instantly, frozen, and hidden behind whatever is really in the way.*

> **Read this first. This document is a mandate, not a suggestion.** The previous plan
> shipped a working prototype and then mistook "it builds and eventually renders something"
> for "it is good." That gap is the whole job. Everything below exists to close it.

---

## 0. Who is building this, and the standard they are held to

You (the AI code agent) are to operate, for the entire life of this project, as **two senior
people fused into one**:

- **A software engineer with 20+ years of shipping commercial product** — someone who has
  maintained systems used by millions, who treats latency, jank, battery, crash-free rate,
  and cold-start as first-class product features, not afterthoughts. Someone who has been
  burned enough times to distrust their own first instinct and to measure instead of assume.
- **An augmented/virtual reality engineer with 15+ years** — someone who has shipped
  location AR, who knows VIO, SLAM, VPS, sensor fusion, occlusion, and the specific ways all
  of them fail in the rain, at night, at 80 mph, and in a dead-flat suburban street with no
  visual features. Someone who knows the difference between a demo that works on a table and
  an experience that survives contact with the real world.

**The operating rules for that person, enforced for every task:**

1. **Never settle for "easy" when "right" is knowable.** If there is a harder path that
   produces a materially better result, take it or explicitly justify — in writing, in
   `DECISIONS.md` — why you didn't. "It was faster to implement" is not a justification.
2. **Research before you build, every time a claim about the physical world or a third-party
   SDK is load-bearing.** Read the primary source (the SDK reference, the paper, the release
   notes), not a memory of it. Cite it in the ADR. If you cannot cite it, you do not know it.
3. **Be a perfectionist about the seam between virtual and real.** The single metric this
   product lives or dies on is: *can a stranger tell the object isn't really there?* Edge
   bleed, pop-in, sliding, drawing-over-what-should-hide-it, wrong scale, wrong ground height
   — each one of these is a P0 bug, not polish.
4. **Measure everything that the user can feel.** Time-to-first-object, anchor drift in cm,
   occlusion error at the silhouette, frame time p95, thermal state at 10 minutes. If it
   isn't instrumented, it isn't done.
5. **Think out of the box.** The obvious architecture (open camera → wait for VPS → show
   object) is the one that killed the last version. The right architectures in this document
   are deliberately non-obvious. When you hit the next wall, the answer is probably also
   non-obvious. Go find it.
6. **Honesty over optimism in the HUD, the logs, and this document.** If VPS hasn't locked,
   the app must not pretend it has. If a feature can't hit the bar, say so here and route
   around it — don't ship a lie the user discovers in the field.

If at any point the work drifts toward "good enough for a portfolio piece," stop. The target
is **a commercial product that thousands — then millions — of people keep open, keep placing
into, and keep sharing from.** Sky-high is the floor.

---

## 1. The three idea-killers, named — and the bar for each

The previous field tests (2026-07-06/07) surfaced the real enemies. State them plainly so
every decision can be checked against them.

### Killer #1 — The wait-then-pop-in
> *"That 5-to-30-second time is one of the idea killers. Somebody opens the camera and waits;
> it suddenly appears, and now they see the appearance of the object being placed — no thrill
> left. It should be there as soon as they face the camera."*

This is correct and it is non-negotiable. **VPS localization typically takes 10–15 seconds
and is device-dependent — some devices take minutes or never converge** (confirmed:
Google's own SDK guidance and developer reports below). Therefore the architecture must
**never gate the first render on VPS.** The object is on screen from frame one; VPS silently
corrects it underneath. The user must never witness "placement." They witness *presence*.

> Research basis: Under typical conditions VPS gives positional accuracy usually better than
> 5 m and often ~1 m and rotation better than 5°, but most devices reach that only after
> ~10–15 s of scanning, and some take far longer or wobble for minutes
> (google-ar/arcore-unity-extensions issue #180; ARCore GARSessionConfiguration reference).
> **Conclusion: VPS is a correction layer, not a spawn trigger.**

**Bar:** median time-to-first-visible-object **≤ 400 ms** from the camera tab appearing —
i.e. the first camera frame. Not 400 ms after a fix. 400 ms after the shutter opens.

### Killer #2 — The sticker / the drift / the draw-over
> *"I don't expect the blurring of building edges and glitchy effect. I certainly don't want
> to see it's been drawn over the building while its location was behind it. I want the
> naturally visible part, and it's really hard to differentiate if it's virtual or really
> placed there. Super natural, perfectly frozen, naturally hidden behind obstructions if it
> means to be."*

Three distinct sins bundled here, each with its own fix (§4, §5):
- **It follows the camera like a sticker** → true world-lock, place-once, full parallax.
- **Its edges are blurry / it glitches** → PBR + anti-aliased silhouette, temporally stable
  occlusion mattes, no per-frame billboard snapping.
- **It draws over a building it's actually behind** → real occlusion from building meshes
  (Streetscape Geometry) + semantic sky/building masking + depth, not just near-field LiDAR.

**Bar:** at the object's silhouette, occlusion error **< 1° of visual angle**; zero frames
where content renders over a surface that is geometrically in front of it and that we have
geometry or a semantic label for.

### Killer #3 — The train window (the signature test)
> *"I'm sitting inside a moving train's window seat, I open the app and see all the objects
> nearby placed for public view. I face the camera through the train window outside in the
> direction I literally see it. I see it far away as one of the giants. All processed and
> clean."*

This is the hardest scenario in consumer AR and it deserves its own mode. **ARCore/ARKit VIO
is built for a person walking; it degrades badly in large, dynamic outdoor scenes and through
glass on a vehicle moving at speed** (confirmed below). Visual tracking through a train window
sees: reflections, a fast-moving background, a static window frame, and its own poor feature
matches. Naive VIO will think *the world* is moving and will smear everything.

> Research basis: ARCore is documented as targeted at more constrained scenes and is reported
> to "fail to continue tracking in larger outdoor areas" and to perform worst "in large and
> dynamic environments" (arXiv 2010.01023, §6 Limitations). VPS needs Street View coverage and
> visible building texture; a train window at speed gives it neither reliably.

The answer is **Transit Mode (§6)** — a dedicated pipeline that, when we detect vehicular
speed, *stops trusting VIO for world-lock* and instead renders the far-field objects from a
**GPS + heading + gyro dead-reckoned virtual camera** against a **geo-referenced far-field
render** (objects treated as distant billboarded-with-parallax giants anchored in ENU/ECEF
space, not in the wobbly VIO frame). Occlusion in transit comes from **Streetscape Geometry
building meshes and the semantic building/sky mask**, never from LiDAR (useless through glass
at range). This is the out-of-the-box thinking Killer #3 demands.

**Bar:** seated on a moving train, panning the phone across the window, far objects (50 m–2 km)
sit rotationally stable (no smear, no swim), correctly sized by distance, and occlude behind
real buildings as they pass — at 30 fps minimum, no VIO "world is sliding" artifact.

---

## 2. Deep research — the localization & rendering stack, re-derived

The previous plan's Tier A/B/C layering was directionally right but under-specified and it
let VPS gate the experience. Here is the corrected, sourced stack. **Layer them; never let a
slow layer block a fast one.**

### 2.1 Positioning layers (fastest-to-slowest, all running concurrently)

| Layer | What it gives | Latency to first useful output | Accuracy | Role |
|---|---|---|---|---|
| **L0 — GNSS + true-heading + gravity + gyro** (CoreLocation/FusedLocation + CoreMotion) | A coarse 6-DoF world pose in ENU immediately | **First fix in <1 s; heading instant** | 5–15 m pos, ±5–15° yaw | **Spawn layer.** Objects appear NOW at their ENU offset. Never blocks. |
| **L1 — VIO world-lock** (ARKit/ARCore VIO) | Frame-to-frame stability, parallax, near occlusion | ~0.5–2 s to stabilize | drift-prone over distance | **Stabilize layer** for pedestrian use. Disabled as world-lock in Transit Mode. |
| **L2 — VPS (ARCore Geospatial)** | Sub-5 m, often ~1 m global pose + yaw <5° | **10–15 s typical, device-variant, sometimes never** | ~1–5 m / <5° | **Correction layer.** Silently glides objects to truth once locked. Never gates render. |
| **L2b — ARKit ARGeoAnchor** | Similar precision, Apple imagery | seconds–tens of seconds | sub-meter-ish | Optional iOS-native corroboration, **behind a timeout+fallback** (the v0.2 bug was trusting it with no timeout). |

**Design rule:** the render loop always has a pose from the **best layer that has converged so
far**, and objects **glide** (short critically-damped tween, ~0.8–1.2 s) between layers so a
correction reads as the world settling, never as a jump or a spawn. GPS-displacement vs
AR-displacement is compared to reject false corrections while walking (kept from v2.5 — that
instinct was right).

### 2.2 Occlusion layers (near-to-far — this is what sells "really there")

| Source | Range | Handles | Devices | Notes |
|---|---|---|---|---|
| **LiDAR scene depth + reconstruction** | ~0–8 m live, mesh persists | cars, trees, people, walls up close | LiDAR iPhones/iPads | Kept from v0.3. Near-field only. Useless through train glass. |
| **Person segmentation (depth)** | any | people crossing in front | most modern devices | Kept from v0.3. Always on. |
| **ARCore Streetscape Geometry** (building + terrain meshes from Street View) | building-scale, far beyond LiDAR | **the whole building your object is behind** | Android + iOS via ARCore | **The key to Killer #2 & #3.** Real building meshes as invisible occluders. |
| **ARCore Scene Semantics** (per-pixel sky/building/tree/vehicle labels) | whole frame | sky (never draw giants "into" sky wrongly), building edges, far occlusion where no mesh exists | ARCore-supported (Depth-API class devices) | Per-pixel matte to clean silhouettes and catch what meshes miss. |
| **Geospatial Depth** (fuses sensor depth with Streetscape Geometry) | **up to ~65 m** | mid-far occlusion without a ToF sensor | Depth-API devices in VPS areas | Bridges the LiDAR→building gap. This is how "hidden behind that building 60 m away" works. |

> Research basis: Streetscape Geometry exposes building/terrain meshes usable as occluders on
> Android **and iOS**; Geospatial Depth merges Streetscape Geometry with device depth to give
> depth **up to ~65 m** without needing a hardware depth sensor; Scene Semantics labels each
> pixel (sky, building, tree, road, vehicle, person, …) for outdoor scenes and reports
> per-label prevalence. (Google ARCore developer docs, 2023–2026.)

**Design rule for the silhouette (Killer #2):** composite occlusion in this priority —
`person-seg (nearest) → LiDAR depth → Geospatial Depth (≤65 m) → Streetscape building mesh →
semantic building/sky matte (fallback)`. Feather the matte by ≤1 px and temporally stabilize
it (EMA over the confidence image) so edges don't shimmer. **Never** render a "giant" into a
region the semantic mask calls `SKY` if its geo-position places it behind a `BUILDING` — that
is the exact "drawn over the building" artifact, caught by a cheap per-pixel check.

### 2.3 The altitude problem (unchanged conclusion, sharpened)
Store `heightAboveGround`, never absolute altitude. Resolve ground at view time via, in order:
**Terrain/Rooftop anchors (VPS resolves true elevation) → Geospatial Depth ground → detected
AR planes → camera-height estimate.** Clamp final altitude to a sane band around the camera
(kept from v0.2 — that clamp fixed a real bug).

### 2.4 Why not Niantic Lightship / Immersal / a scan-first VPS
Lightship gives centimeter accuracy and excellent long-range mesh occlusion, but it localizes
against **crowdsourced scanned Wayspots** — it is dense only where people have scanned. Our
core promise is *"any friend's house, anywhere, without ever visiting."* That is coordinate-
first, global, and matches **ARCore Geospatial / Street View coverage (87+ countries)**, not
scan-first coverage. So: **ARCore Geospatial is the spine.** Keep Lightship on the Wave-7
research shelf as a *precision booster in dense-scan urban cores* (a place-quality upgrade),
not the base layer. Document this trade-off in the ADR; don't silently re-litigate it later.

---

## 3. The product — what makes millions keep it open

A state-of-the-art renderer with nothing to look at dies in a week. The last plan had almost
no retention design. Location-AR's graveyard is real: **geo-AR games routinely lose 90%+ of
peak users** without "completeness" — a full loop of reasons to return. Build the loop in from
Wave 5, not "someday."

> Research basis: geolocation AR titles have lost 90%+ of peak actives without designed
> "completeness"; Pokémon GO sustained ~60%+ 3-day retention and tens of minutes/day via a
> behavioural loop of explore → collect → progress → socialize → share, driven heavily by
> word-of-mouth and real-world social presence. (ScienceDirect 2023; AR Insider; SurveyMonkey
> Intelligence.)

### 3.1 The core loop (must all exist for "complete")
1. **Discover** — open the map or the camera and *see that the world around you is full of
   things other people left.* Density is the dopamine. Empty map = dead app; seed cities.
2. **Approach & reveal** — walk (or ride) toward a drop; it grows, resolves, and reveals
   naturally from behind real obstructions. The reveal *is* the reward — so it must be flawless.
3. **React & collect** — leave a reaction, a reply, a "was here"; collect limited/rare drops.
4. **Create** — place your own, trivially, in <20 s, from anywhere (remote placement — our
   moat; nobody else lets you surprise a friend's house from your couch).
5. **Share** — capture a photo/video of the AR moment; the share *is* the growth engine.
   Every shared clip is an ad that says "this is really there — how?"
6. **Return** — you get notified when someone reacts to your drop, when a friend leaves you
   one, or when a rare/limited drop appears near you (region-monitoring push).

### 3.2 Signature experiences (the things people screenshot)
- **The Birthday Surprise** (the hero, kept): remote-drop a giant "HAPPY BIRTHDAY" at a
  friend's house; text them to look through the app.
- **The Train Window Gallery** (new hero): the seated-commuter view of a city studded with
  giant public drops sliding past the window, correctly occluded by real buildings. This is
  the demo that goes viral *because* it looks impossible. It must be perfect (Killer #3).
- **The Skyline Giant**: drops so large and so correctly-placed they read as landmarks —
  a 60 m message standing behind the actual skyline, revealed building-by-building as you move.

### 3.3 Trust, safety, moderation — required before public launch, not after
Public drops at real addresses is a harassment vector. Non-negotiable for a public product:
report/block, profanity/NSFW filter on text and models, rate limits, drop expiry, home-address
protections (no unsolicited drops tightly geofenced to a private residence without the
recipient opting in), and clustering to prevent griefing in dense spots. Ships **with** Wave 5
social, gated in front of any public visibility.

---

## 4. Architecture (v2)

```
Cross-platform core (native where it counts)
├── Platform: native iOS (Swift/RealityKit) + native Android (Kotlin/Filament or AR Foundation)
│      Rationale: the seam-quality bar (occlusion, PBR, silhouette) needs native renderer
│      control. WebAR is an acquisition/marketing channel only (Wave 8), never the main app.
│
├── Positioning: PoseProvider  (the "best converged layer" arbiter, §2.1)
│      ├── GnssHeadingPose      L0 — instant ENU spawn pose
│      ├── VioPose              L1 — VIO stabilize (pedestrian world-lock)
│      ├── GeospatialPose       L2 — ARCore VPS correction (glide-in)
│      └── GeoAnchorPose        L2b — ARKit ARGeoAnchor, timeout+fallback guarded
│
├── Occlusion: OcclusionStack  (composited, near→far, §2.2)
│      ├── PersonSeg → LiDARDepth → GeospatialDepth(≤65m) → StreetscapeMesh → SemanticMatte
│      └── SilhouetteRefiner    (≤1px feather, temporal EMA — no shimmer)
│
├── Rendering: DropRenderer
│      ├── PedestrianPath       VIO-locked, place-once, full parallax
│      ├── TransitPath          §6 — GPS/gyro dead-reckoned far-field, glass-safe
│      └── DropEntityFactory    procedural PBR meshes; emissive night look; unlit fallback
│
├── Content sync: DropLibrary   (observable façade)
│      ├── LocalDropStore        JSON cache (offline-first, always on)
│      ├── CloudDropStore        geo-radius query backend (public + friend-scoped)
│      └── PrefetchEngine        §5.4 — predictive spatial prefetch so drops are ready
│                                BEFORE the camera opens (kills pop-in at the data layer)
│
├── Motion state: MotionClassifier  (still / walking / vehicular) → selects render path
│
└── Models: GeoDrop (Codable, backend-mappable), Reaction, Author, Visibility
```

**Non-negotiable engineering constraints baked into the architecture:**
- The render loop **owns a valid pose every frame** from L0 upward; it never waits.
- Layer hand-offs are **glides**, never snaps.
- Occlusion is **composited by priority**, temporally stable, and **semantic-gated** so we
  never draw over something we know is in front.
- Motion state **switches the render path** automatically and hysteretically (no flapping).

---

## 5. Killing the pop-in for real (Killer #1, the full solution)

Instant presence is a *system* property, not one trick. Four things happen before and during
camera open so the object is simply *there*:

**5.1 Warm the AR session off the map tab.** The moment the user is on the map looking at
drops (i.e., intent is forming), pre-initialize the AR session, camera, VIO, and — if
available — kick off the VPS availability check and localization *in the background*. By the
time they hit the camera tab, VIO is already tracking and VPS may already be converging.
(Cold-start mitigation by pre-warming is a well-established pattern; apply it to the AR
session, not just data.)

**5.2 Spawn on L0, always.** First camera frame → objects are drawn at their GNSS+heading ENU
offset immediately. No "searching…" gate on visibility. The HUD may *inform* about precision,
but the object is on screen at frame one.

**5.3 Glide, don't pop.** When VIO stabilizes and again when VPS locks, objects glide
(critically-damped, ≤1.2 s) from the coarse pose to the corrected one. The user reads this as
the world *settling into focus*, which feels premium — the opposite of pop-in.

**5.4 Predictive spatial prefetch.** `PrefetchEngine` fetches all drops within the render
radius (2 km) — including their meshes/params — **while the user is still on the map**, keyed
off current location and heading of travel, so no drop is ever fetched *after* the camera
opens. Cache is warm; the network is never in the critical path of a reveal.

**Acceptance test for Wave-level sign-off:** open camera 20 times in varied conditions;
median time-to-first-visible-object ≤ 400 ms; **zero** instances where the user sees an object
"appear" into an empty spot they were already looking at. If either fails, the wave is not done.

---

## 6. Transit Mode (Killer #3, the signature build)

Triggered by `MotionClassifier == vehicular` (speed + accelerometer signature; hysteretic so
a fast walk or a stop doesn't flap it). When active:

**6.1 Stop trusting VIO for world-lock.** Through glass at speed, VIO's feature matches are
garbage and it will interpret the moving background as self-motion. So Transit Mode renders
the world from a **synthetic camera** whose pose = **last good GNSS position + fused
heading/gyro (CoreMotion/rotation-vector) dead reckoning**, updated at display rate. Gyro
gives smooth rotational tracking (which is what panning the phone across the window actually
is); GNSS gives the slowly-updating position along the track. The far objects are anchored in
**ECEF/ENU geo-space**, so they're stable in the world regardless of VIO.

**6.2 Render far objects as distance-correct giants.** At 50 m–2 km, parallax from the few
meters of phone movement is negligible; what matters is *correct angular size and bearing*
from the geo pose. Objects are placed at true geo-coordinates and projected through the
synthetic camera — so a giant 2 km away sits at the right spot on the horizon and slides past
at the right rate as the train moves. No min-apparent-size hacks (those caused the v0.2
sticker feel); true angular size, because at giant scale it's actually visible.

**6.3 Occlude with geometry + semantics, never LiDAR.** As buildings pass between viewer and a
far drop, the **Streetscape Geometry building meshes** (and the **semantic building mask** for
anything meshless) hide the drop exactly as the real building does. This is the "naturally
hidden behind obstructions" moment, at city scale, through a train window. Geospatial Depth
extends clean occlusion to ~65 m; beyond that, building meshes + semantic matte carry it.

**6.4 Reflection & frame rejection.** The window frame and reflections pollute the camera
feed. Use the semantic mask to identify sky/building regions and down-weight the rest; do not
attempt VIO feature tracking on reflection-heavy frames (that's what smears). Render quality is
driven by geo-pose + occlusion geometry, so a noisy feed doesn't wreck the world-lock.

**6.5 Honest degradation.** If GNSS drops (tunnel) or there's no Street View coverage for
occlusion geometry, the HUD says so plainly and the far-field gracefully simplifies (objects
without reliable occluders render with a soft depth cue rather than a false hard edge). Never
fake a lock you don't have.

> This mode is the out-of-the-box answer the brief demands. It exists because the obvious
> pipeline (VIO world-lock) is *physically wrong* for a vehicle at speed, and no amount of
> tuning fixes a wrong model. Build the right model.

---

## 7. Build waves (v2)

Waves 1–4 from v1 are largely built; v2 **raises their bar and adds the hard waves.** A wave
is "done" only when its **acceptance tests (§10)** pass on real devices in the field — not when
it compiles.

### ✅ Wave 1–2 — Foundation + first AR (built) → **re-audited to v2 bar**
Keep the map, address search, remote placement, procedural content, HUD guidance. **Re-audit
against §5 (instant spawn) and §4 (glide, never snap).** Remove any remaining min-apparent-size
billboard hack in the pedestrian path.

### ✅ Wave 3 — Everyone sees it (built, flag-gated) → **harden**
CloudKit/public-DB geo-radius sync stays, but the backend must be **cross-platform from the
start** (Android is not optional for a "millions of users" product — see §8). Add author
identity and the data model for reactions/visibility now, even if the UI lands in Wave 5.

### ◐ Wave 4 — Precision & occlusion (partly built) → **complete to the seam-quality bar**
- ARCore Geospatial (VPS) as the **correction layer**, never a gate (fix any gating).
- **Streetscape Geometry** occluders — the real fix for Killer #2's "drawn over the building."
- **Geospatial Depth** for clean ≤65 m occlusion without a ToF sensor.
- **Scene Semantics** matte for silhouette cleanup and sky/building gating.
- Seamless glide hand-off L0→L1→L2. Timeout+fallback on ARGeoAnchor.
- **Acceptance:** §10 occlusion + latency tests pass. Not before.

### ★ Wave 5 — Transit Mode (§6) — the signature
The hardest wave; the one that makes the train-window demo real. Motion classifier, synthetic
geo-camera, geo-space far-field render, geometry+semantic occlusion, honest degradation.
**Acceptance:** the train-window bar in §1 Killer #3 and §10.

### ★ Wave 6 — Social & retention (§3) — the reason to return
Accounts (Sign in with Apple / Google), friends, friend-scoped and public drops, reactions,
view counts, deep-link/share-sheet ("someone left you a surprise here"), region-monitoring
push, **AR photo/video capture with one-tap share** (the growth engine), and the full
moderation/safety stack (§3.3) gating anything public. Seed drops in launch cities so the map
is never empty.

### Wave 7 — Content depth & scale
USDZ/glTF library + user models, text-to-3D ("a golden dragon holding a cake"), animation,
limited/rare/collectible drops (retention), clustering & LOD for dense areas, drop expiry,
anti-grief. Research shelf: Lightship as an urban-core precision booster.

### Wave 8 — Reach
WebAR acquisition channel (marketing, not the main app), broader device support, localization,
and the scale/backend work for millions of concurrent geo-queries.

---

## 8. Cross-platform reality check

"Millions of users communicating and placing objects" is **impossible on iOS-only** — the
Android install base is most of the world, and ARCore (the spine of our precision + occlusion
stack) is an Android-first platform with an iOS SDK on top. **Plan for both from Wave 3's
backend outward.** Share 3D assets (USDZ for iOS, glTF for Android). Native renderers on each
platform for seam quality; shared positioning/occlusion/sync logic where the SDKs allow.
Document per-platform capability gaps (LiDAR only on some iPhones; Scene Semantics/Depth only
on Depth-API-class devices) and degrade honestly per device.

---

## 9. Risks & mitigations (v2)

| Risk | Mitigation |
|---|---|
| VPS takes 10–15 s / never locks on some devices | **Never gate render on VPS** (§5). Objects spawn on L0; VPS glides in. HUD shows honest precision chip. |
| VIO smears through a moving train window | **Transit Mode** (§6): geo-pose + gyro dead reckoning, VIO dropped as world-lock. |
| Object drawn over a building it's behind | Streetscape mesh + Geospatial Depth + semantic building matte, composited & semantic-gated (§2.2). |
| Blurry/shimmering silhouette | SilhouetteRefiner: ≤1px feather + temporal EMA on the matte; no per-frame billboard snap. |
| Empty map = dead app | Seed drops in launch cities; density-first onboarding; friend-invite loop (§3). |
| Public drops enable harassment | Full moderation/safety stack gating all public visibility, shipped with Wave 6 (§3.3). |
| Night / featureless street breaks VPS & lighting | Unlit/emissive drop look (kept from v2.6); honest "GPS-only precision" HUD; graceful occlusion fallback. |
| iOS-only can't reach millions | Cross-platform from Wave 3 backend (§8). |
| Battery/thermal from full AR + ML masks | Budget frame time & thermal; throttle semantic/depth cadence; LOD far objects; measure at 10 min (§10). |
| GNSS gap in tunnel | Dead-reckon briefly, then honestly degrade far-field; don't fake a lock. |

---

## 10. Verification — the bar, as tests (a wave is not done until these pass on-device)

Instrument and log every one of these; store results in the repo per wave.

**Latency (Killer #1)**
- Median time-to-first-visible-object ≤ **400 ms** from camera-tab frame one, over 20 opens.
- **Zero** observed "object appears into a spot I was already looking at" events.
- Layer hand-offs (L0→L1→L2) are glides; **zero** perceptible snaps in a 5-min session.

**Seam quality (Killer #2)**
- Occlusion error at silhouette < **1° visual angle** against ground truth.
- **Zero** frames drawing content over a surface we have geometry/semantic-label for as being
  in front.
- Silhouette matte temporal jitter below a fixed shimmer threshold (measured on the confidence
  image variance frame-to-frame).
- Placed object drift < a few cm over a 2-min stationary hold once VPS-locked.

**Transit (Killer #3)**
- On a moving train, far objects (50 m–2 km) rotationally stable while panning, correctly
  angular-sized, occluding behind real buildings as they pass, ≥ 30 fps, **no VIO smear**.

**Product/retention (the millions bar)**
- Core loop (§3.1) fully present and instrumented (discover→approach→react→create→share→return).
- Share flow exports a clean AR photo/video in ≤ 3 taps.
- Launch-city map is never empty on first open (seeded).

**Systems health**
- Crash-free sessions ≥ 99.5%. Frame time p95 within budget. Thermal state not `.serious` at
  10 min of continuous AR on target devices. Battery drain measured and documented.

**Build hygiene (necessary, not sufficient)**
- Native builds succeed, 0 warnings. But **"BUILD SUCCEEDED" is not a milestone** — it's the
  precondition for the field tests above, which are the actual milestones.

---

## 11. Working discipline (how the agent must operate on this repo)

- **`DECISIONS.md` / ADR log is law.** Every load-bearing choice (SDK, threshold, occlusion
  order, mode-switch heuristic) gets an ADR with the *sourced* rationale. No silent re-litigation.
- **`BRIEF.md`** carries these three killers and their bars at the top of every session so
  context compaction never loses the point of the project.
- **Research is a build step.** Before implementing anything touching VPS, Streetscape Geometry,
  Scene Semantics, Depth, motion classification, or occlusion order — open the primary SDK doc
  / paper, confirm current behavior and limits, cite it in the ADR. Your training memory is not
  a source.
- **Measure, then claim.** No "it should be instant now" in a commit message. Attach the number.
- **Field test on real devices, real streets, real trains, at night, in the rain.** The lab is
  where AR lies to you.
- **When you hit a wall, the easy path is probably wrong.** Re-derive from the physics of the
  situation (what can the sensors actually know here?) before writing code. That is what a
  20-year engineer and a 15-year AR engineer would do, and that is who is building this.

---

## 12. What "done" looks like

A stranger on a train opens the app. Before they've thought about it, the window is full of
giant messages other people left across the city — sitting exactly where they belong, sliding
past behind real rooftops, clean-edged, frozen in the world, indistinguishable from something
truly there. They point the phone at a friend's neighbourhood, drop a giant "HAPPY BIRTHDAY"
on the house, and share the clip. Their friend opens the camera at home and it's *just there* —
no wait, no pop-in, no seam. That clip becomes the reason ten more people install it.

That is the bar. Build to it. Don't settle.
