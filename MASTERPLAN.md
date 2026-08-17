# AugmentMeReality — Master Plan

*Pin virtual 3D things to real-world places. Anyone who opens the camera there sees them.*

**The hero scenario:** You know your friend's address. From your couch, you open the map,
drop a giant 3D "HAPPY BIRTHDAY 🎂" in front of their house, and text them *"look out your
window through the app."* They open the AR camera and the message is floating right there.

---

## 1. Deep research — how do you anchor virtual content to a real place?

This is the single hard problem of the app. Everything else (map UI, 3D content, sharing)
is well-trodden ground. There are three tiers of localization technology, and the right
strategy is to **layer them**: ship the universal one first, upgrade precision where
better tech is available.

### Tier A — GPS + compass + ARKit world tracking (works everywhere)
- Get the phone's GPS fix and true-north heading (`CoreLocation`).
- Run ARKit world tracking with `worldAlignment = .gravityAndHeading` so the AR
  coordinate system is aligned: **+X = east, −Z = true north, +Y = up**.
- Convert the (latitude, longitude) delta between the viewer and the pinned content into
  east/north **meters** (ENU tangent-plane math) and place the 3D entity at that offset.
- Once placed, ARKit's visual-inertial odometry keeps it glued to the world even as GPS jitters.
- **Accuracy:** ~5–15 m position, ±5–15° heading. For "giant birthday text over a house"
  this is genuinely good enough. Proven by the popular open-source
  [ARKit-CoreLocation](https://github.com/AndrewHartAR/ARKit-CoreLocation) project.
- **Cost/coverage:** free, works anywhere on Earth, no account or API key.

### Tier B — Apple ARGeoAnchors / `ARGeoTrackingConfiguration` (precise, limited coverage)
- ARKit matches the camera feed against Apple Maps "Look Around" imagery → sub-meter-ish
  placement from just a GPS coordinate; ARKit even resolves the ground altitude for you.
- **Coverage:** only ~25+ US metro areas + London. Requires A12+ chip, cellular + GPS.
- **Cost:** free, built into iOS. We detect availability at runtime
  (`ARGeoTrackingConfiguration.checkAvailability`) and automatically use it when possible.

### Tier C — Google ARCore Geospatial API (precise, near-global) ← the endgame
- Uses Google's Visual Positioning System (VPS) built from tens of billions of Street View
  images. **~1–5 m positional accuracy, <5° rotational**, coverage in **87+ countries** —
  anywhere Street View has been.
- Has a native iOS SDK (`ARCore` CocoaPod/SPM, runs on top of ARKit). Supports *terrain
  anchors* (auto ground altitude) and *rooftop anchors* — ideal for "in front of a house."
- **Cost:** free tier is generous; requires a Google Cloud API key. This is the Wave-4
  precision upgrade once the product works end-to-end.
- (Niantic Lightship VPS is the alternative — centimeter accuracy but only at ~1M scanned
  landmarks; wrong shape for "any friend's house," so we skip it.)

### The altitude problem (learned from research)
GPS altitude is wildly inaccurate, and when you pin remotely from a map you don't know the
ground height there. Strategy: store `heightAboveGround` (not absolute altitude) with each
pin. At view time, estimate the local ground from detected AR planes (or camera height),
Tier B/C resolve terrain altitude natively. This is what makes remote placement work.

### Competitive scan
- **WallaMe** — AR notes on walls, but you must *be there* and photograph the wall to place.
- **Mark AR / Spark AR posts** — social AR graffiti, same be-there constraint.
- **Pokémon GO** — geo AR at planet scale, but content is game-controlled.
- **Our differentiator:** *remote placement* — pin a surprise at any address from the map,
  without ever visiting. None of the above do this. It also forces our architecture to be
  coordinate-first (Tier A/C) rather than scan-first.

### Sharing backend
**CloudKit public database**: free (10 GB public storage that grows with installs), zero
servers, every iCloud-signed-in user is automatically authenticated, and it natively
supports **geo-radius queries** (`distanceToLocation:fromLocation:`) — exactly "give me all
drops within 2 km of me." Fallback/offline layer is a local JSON store; the two sit behind
one `DropStore` protocol so we can swap in Firebase/Supabase later if we outgrow CloudKit.

---

## 2. Product concept

A **"Drop"** = a piece of 3D content pinned to a coordinate:
`{ id, content type, message, lat/lon, heightAboveGround, scale, color, author, createdAt }`

Content types (all generated procedurally in RealityKit — no asset pipeline needed):
- **3D Text** — any message, extruded, metallic, huge if you want (the birthday hero case)
- **Balloons** — a floating cluster with strings
- **Gift box** — box + ribbon + bow
- **Heart** — extruded ♥ glyph
- **Beacon pin** — a tall marker visible from afar

Three surfaces:
1. **Map** — see all drops, search any address, tap to pin a new drop there.
2. **AR Camera** — see every nearby drop rendered in the real world; HUD arrow + distance
   guides you toward drops you can't see yet.
3. **Drops list** — manage what you've placed, distances, delete.

---

## 3. Architecture

```
SwiftUI App (iOS 17+)
├── Map surface        MapKit (SwiftUI Map, MapReader, MKLocalSearch address search)
├── AR surface         ARKit + RealityKit (ARView via UIViewRepresentable)
│    ├── PlacementEngine: Tier B geo-tracking when available, else Tier A GPS+heading
│    └── DropEntityFactory: procedural RealityKit meshes (generateText, spheres, boxes)
├── Services
│    ├── LocationService    CLLocationManager wrapper (fix + true heading)
│    ├── GeoMath            ENU offsets, haversine distance, bearings
│    └── DropLibrary        observable façade over the stores
│         ├── LocalDropStore     JSON on disk (always on = offline cache)
│         └── CloudKitDropStore  public DB, geo-radius queries (flag-gated)
└── Models: GeoDrop (Codable, CloudKit-mappable)
```

---

## 4. Build waves

### ✅ Wave 1 — Foundation (built)
- Xcode project (no external dependencies), SwiftUI shell, 3-tab navigation
- Map with user location, **address search** (the "I know his address" flow),
  tap-anywhere-to-pin, drop composer (content, message, size, height, color)
- `GeoDrop` model, local JSON persistence, drops list with live distances

### ✅ Wave 2 — The magic: AR viewing (built)
- AR camera screen; Tier A placement everywhere (GPS + heading ENU), automatic
  Tier B upgrade (`ARGeoAnchor`) in supported cities
- Procedural 3D content factory incl. extruded 3D text; text faces the viewer
- Ground estimation from detected planes; `heightAboveGround` honored
- HUD: localization status, nearest-drop distance + bearing arrow, compass-accuracy hints
- "Demo drop 15 m ahead" button so you can test without walking anywhere

**Wave 3.0 — v0.3, "real object, not a sticker" (fourth field test, 2026-07-07):** the
drop rendered but felt like a flat sticker gliding on the camera and drew *on top of* a
parked car. Fixes: (1) **LiDAR occlusion** — scene reconstruction mesh + smoothed scene
depth + person segmentation (`sceneUnderstanding .occlusion`), so cars/trees/people hide
content behind them (LiDAR device required; live depth reaches ~5–8 m, but the
reconstructed mesh persists spatially, so obstacles you walk past keep occluding);
(2) **true world-locking** — the v0.2 min-apparent-size boost + per-frame billboarding
made content follow the camera like a sticker; content is now placed once, true-scale,
fixed orientation forever — full perspective and parallax; a separate small **way-point
orb** above each drop keeps constant apparent size for far findability and hides within
25 m; (3) **lit PBR materials with emissive** (shading depth cues by day, glow at
night); (4) **placement hysteresis** — refinements rate-limited (≥8 s apart, ±15° once
the heading estimate converges) so content stays nailed down instead of sliding.

**Wave 2.7 — v0.2, total-invisibility fixes (third field test, 2026-07-06):** a 100 m
walk toward a drop with correct HUD guidance rendered *nothing*, even at the spot.
Root causes addressed: (1) **ground-plane poisoning** — the ground was taken as the
lowest horizontal plane ever detected, and one night-time garbage plane (reflective
roads, headlights) sinks every drop underground → planes are now only trusted within a
sane band (0.5–4 m below the camera) and final content altitude is clamped to
[camera−5 m, camera+40 m], so content can physically never render out of the visible
band; (2) the **Apple geo-anchor auto-upgrade could blank everything** — if ARKit
reported geo availability it re-anchored all content to geo anchors, which can fail to
localize indefinitely at night with no fallback → upgrade disabled behind
`AppConfig.appleGeoAnchorsEnabled = false` until Wave 4 pairs it with a timeout
fallback; (3) emoji-only messages extrude to an empty mesh (color bitmap glyphs have no
outlines) → fallback text; (4) every drop now gets a glowing ground-to-content pillar;
(5) the HUD shows **render diagnostics** ("Rendered 96 m ahead · 3 m up") and the build
version, so any future "I see nothing" report pinpoints the failing stage instantly.

**Wave 2.6 — night test at a window (2026-07-06):** placing a text 7 m outside a window
at night showed nothing. Two causes, both fixed: (1) content used scene-lit metallic
materials — ARKit's estimated environment light is ~zero at night, rendering virtual
objects nearly black against a dark street → all drop content is now **unlit**
(full-bright neon look, immune to lighting, visible day and night); (2) the session's
north comes from a single compass sample at startup, which indoors near a window can be
off by tens of degrees, pushing even a 7 m drop out of frame → the engine now
continuously compares the live compass against the AR camera's yaw and rotates
placements by the smoothed difference (re-syncs when the estimate moves > 5°). The HUD
also now says explicitly "straight ahead / turn left / turn right / behind you".

**Wave 2.5 — seamlessness fixes (from first field test, 2026-07-06):** the first cut
gated placement on ±25 m GPS + stabilized tracking (content appeared late) and rendered
at true scale (invisible beyond ~50 m). Now: content places **instantly** on the first
GPS fix of any accuracy and silently slides to corrected positions as fixes improve
(anchoring error measured as GPS-displacement vs AR-displacement, so walking never
causes false corrections); every drop keeps a **minimum apparent size** (~2° visual
angle, sub-linear boost so approaching still reads as growth, true perspective within
~50 m); render range 2 km; 3D text billboards to face the viewer every frame.

### ✅ Wave 3 — Everyone sees it (built, flag-gated)
- `CloudKitDropStore` on the **public database** with geo-radius fetch, merged with the
  local store behind one façade; author names on drops
- Ships disabled by default (needs a paid Apple developer team to sign the iCloud
  entitlement). Flip `AppConfig.cloudKitEnabled` after adding the capability — README has
  the 3-step guide.

### ✅ Wave 4 — Precision (built, v0.4 — needs a free Google API key to activate)
- **ARCore Geospatial API (Tier C)** integrated via Swift Package Manager:
  `GeospatialEngine` runs a `GARSession` beside ARKit, feeding it every frame
- **VPS localization**: when accuracy is good (≤10 m horizontal, ≤15° yaw), each drop
  gets a **terrain anchor** — Google resolves the exact ground elevation at the pinned
  coordinate, `heightAboveGround` rides on top
- **Seamless handoff**: compass tier places instantly as always; on first VPS
  resolution the content *glides* (1.2 s) to its exact spot, then VPS owns its pose
  (compass tier never touches it again)
- **Streetscape Geometry occlusion**: real building meshes around the viewer are
  installed as invisible `OcclusionMaterial` occluders — content hides behind actual
  buildings, far beyond LiDAR range (LiDAR still handles near cars/people)
- People occlusion was already active since v0.3 (`personSegmentationWithDepth`)
- Activation: paste an API key into `AppConfig.googleGeospatialAPIKey` (README §VPS);
  without a key the app runs the compass tier only
- Honest limits: VPS needs Street View coverage and decent visibility of buildings
  (weak in pitch dark / featureless areas); GARSession requires `.gravity` world
  alignment, so pre-VPS compass placement waits ~3 s for direction calibration

### Wave 5 — Social
- Accounts (Sign in with Apple), friends, private drops ("only Adnan's friend can see it")
- **Deep links / share sheet**: "Someone left you a surprise 📍 — open camera here"
- Push notification when you walk near a drop addressed to you (region monitoring)
- Photo/video capture from the AR view with share sheet (the friend will want to post it)
- Reactions, view counts ("your birthday drop was seen 3 times")

### Wave 6 — Content & scale
- USDZ model library + user-imported models, animated characters, GIF/photo boards
- Text-to-3D generation ("a golden dragon holding a cake")
- Moderation (report/block, profanity filter), drop expiry (birthday drops auto-expire),
  anti-grief rate limits, clustering for dense areas
- Android companion (ARCore) reading the same backend

---

## 5. Risks & mitigations

| Risk | Mitigation |
|---|---|
| GPS/compass error puts drop ~10 m off | Make content BIG by default; HUD guidance; Tier B/C auto-upgrade where available |
| Compass needs calibration (figure-8) | Detect low heading accuracy, show calibration hint in HUD |
| Remote pin altitude unknown | Store height-above-ground; resolve ground locally at view time |
| CloudKit needs paid dev account | Local store works instantly; cloud is one flag + capability away |
| Abuse (offensive drops at someone's home) | Wave 6 moderation, expiry, rate limits — required before public launch |
| ARKit unavailable (simulator/old device) | Graceful fallback screen; map + list still fully work |

## 6. Verification status
- `xcodebuild` device build (iOS SDK, Debug): **BUILD SUCCEEDED, 0 warnings** (Xcode 26.5, 2026-07-06)
- On-device flows still to test manually: place → walk → view; demo drop; address search.
