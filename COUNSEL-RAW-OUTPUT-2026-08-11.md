# Counsel Raw Output — AugmentMeReality Review (2026-08-11)

Verbatim structured output returned by the five counsel agents. Nothing here is summarized or edited — this is exactly what each agent returned. The synthesized/supervised version is in `COUNSEL-REVIEW-2026-08-11.md`.

- 4 reviewers: MATH (mathematics/geodesy), ARP (AR platform), SWE (Swift systems), PBS (backend/privacy/release)
- 1 researcher: industry-standard validation against primary sources
- Model: Opus-class, reasoning effort xhigh (reviewers) / high (researcher)

---

# Reviewer 1 — Mathematics & Geodesy

## Overall assessment (verbatim)

The geometry that is easy to get wrong is largely right: the ENU↔AR rotation convention (+X east, −Z north), the EUS quaternion yaw extraction (`atan2(x, −z)` on `eastUpSouthQTarget.act(0,0,−1)`), the facing-bearing law (yaw = π − β), the inverse-ENU in ADR-041, the circular EMA on sin/cos (which removes the ±180° seam entirely), and the shader's projection-matrix depth decode `d = zw/(zz − depth·wSign)` are all correct — I verified each algebraically rather than assuming. The defects are concentrated in the *estimation* layer, where the code repeatedly ships a fit or a filter without characterizing its support, its error, or its sampling rate. The worst is the mid-field metric alignment (ADR-031): a two-parameter affine fit constrained by data over 0.4–4 m is used out to 60 m, a region entirely outside its support, where the reported depth saturates at 1/b — a quantity nothing in the data constrains and for which no error bar is computed. The second tier is a set of physical-model omissions that the ADRs paper over: no terrain elevation anywhere (GeoDrop has no altitude field), a magnetic-heading fallback silently typed as `trueHeading` with no declination model, open-loop dead reckoning with a hard reset at every GNSS fix, and a "content present" test written as a fixed epsilon in nonlinear NDC depth. The Earth model itself (spherical tangent-plane with the wrong meters-per-degree constant for latitude) is a smaller, systematic error that the test suite structurally cannot see, because every geodesy test round-trips through GeoMath's own inverse.

## MATH-1 — Mid-field metric fit is used entirely outside its data support; depth saturates at 1/b

**Severity:** critical  
**File:** `AugmentMeReality/AR/MidFieldDepthEstimator.swift`:200

**Claim.** The affine fit `1/lidar ≈ a·rel + b` is constrained only by samples with depth in [0.4, 4] m — inverse depth y ∈ [0.25, 2.5] — but is then evaluated over 4–60 m, i.e. y ∈ [0.0167, 0.25], a region containing zero data; because metric = 1/(a·rel + b) ≤ 1/b for a>0 and rel≥0, the fitted intercept silently imposes a hard ceiling on every depth the model can ever report, and nothing in the fit, the R² gate, or the shader constrains that intercept.

**Evidence.** `guard depth > 0.4, depth < 4.0` (line 200) defines the entire support; `let b = (sumY - a * sumX) / n` (line 219) and `guard r2 >= 0.6, abs(a) > 1e-9` (line 221) are the only acceptance tests — R² is measured in-sample over the same 0.4–4 m band. The shader then computes `float inv = uniforms.midA * rel + uniforms.midB; ... float metric = 1.0 / inv;` and only rejects `inv <= 1.0/midMaxDepth` (SemanticMatte.metal:203-206). No standard error on b, no held-out validation, no check that the fitted line remains valid at the far end.

**Failure scenario.** Two concrete branches, both observed as the feature not doing what ADR-031 claims. (a) Typical street: LiDAR is valid only on the pavement 0.4–4 m ahead, over which DAv2's relative disparity spans roughly 0.55–0.90. OLS gives a ≈ (2.5−0.25)/0.35 = 6.4 and b ≈ 0.25 − 6.4·0.55 = −3.3. Every pixel with rel < 0.51 — i.e. everything beyond a couple of metres — yields inv < 0, is rejected by `inv > 1/60`, and produces no matte. The `DPT` HUD chip lights (a sample was published, `feed.hasSample` is true) while the 4–60 m band contributes literally nothing, so trees/cars/fences still draw over exactly as before ADR-031. (b) A scene where LiDAR spans more of the image's depth range (indoor→doorway, a wall at 4 m) gives b ≈ 0.2, so the maximum representable depth is 5 m. Step outside with that fit and the sky (rel ≈ 0, the model's far value) decodes to metric = 5 m, which passes the `metric > 3.0` gate; content at 50 m gets `smoothstep(3, 9, 45) = 1` and is fully matted out wherever sky is visible — the exact "hallucinated occluder eats content" failure ADR-031 promises can never happen.

**Industry gap.** Metric alignment of relative-depth models (ZoeDepth, Depth Anything metric heads, ARKit-anchored scale-shift alignment) is fitted over the *full* range of trustworthy reference depth, validated on held-out samples rather than in-sample R², carries a propagated uncertainty on the shift term, and explicitly refuses to emit depth outside the alignment's support. The standard safeguard here is to clamp the usable output range to the interval actually spanned by the reference samples and treat everything beyond it as unknown, not as a surface.

**Proposed direction.** Bound the reported depth to the inverse-depth interval the LiDAR samples actually spanned (plus a small margin), compute the standard error of b and disarm the occluder when 1/b is not resolvable at the content's distance, and add a test that feeds a fit whose sample band covers only 0.4–4 m and asserts nothing is matted at 50 m.

## MATH-2 — Content-presence test is an NDC epsilon; far content is excluded from all occlusion

**Severity:** high  
**File:** `AugmentMeReality/AR/SemanticMatte.metal`:88

**Claim.** `hasContent` is a fixed 1e-6 epsilon applied in the nonlinear NDC depth encoding and is deliberately written to accept both clear conventions, which means it also rejects real content at both ends of the range; with the near/far planes the app never sets, the rejection boundary lands inside the 50 m–2 km band the transit bar depends on, and all three occluders are gated behind it.

**Evidence.** `bool hasContent = depth > 1e-6 && depth < (1.0 - 1e-6);` and `bool distanceValid = hasContent && ...` (lines 88-92); every occluder branch is guarded by `distanceValid` (lines 98, 119, 200). The near/far planes are never configured anywhere in the project (no `zNear`/`zFar`/`PerspectiveCameraComponent` occurrences), so ARKit's documented defaults apply. For a Metal-style forward-Z projection with n=0.001, f=1000, 1−ndc = (1 − 0.001·D)/(999.999·D), which equals 1e-6 at D = 500 m; for a reverse-Z infinite-far convention, ndc = n/D reaches 1e-6 at D = 1000 m. `AppConfig.arVisibilityRadius = 2_000` (AppConfig.swift:147) and FT-15 exercises drops at 500 m–2 km.

**Failure scenario.** FT-16 ("as real buildings pass between you and a far drop, the drop hides behind them") cannot pass for the far half of its own range: a giant at 800 m is classified as "no content" by the very first test in the kernel, so the semantic building matte, the person matte and the mid-field matte are all skipped for every one of its pixels and it draws over the building in front of it, permanently and silently. Compounding this, with ARKit's default zFar = 1000 m, drops between 1 km and the 2 km visibility radius are outside the frustum and are not drawn at all — FT-15's "~500 m–2 km" case has no rendered object to evaluate. Neither boundary is asserted, logged, or covered by a test.

**Industry gap.** Production AR renderers determine the depth-clear convention once (from the API or a one-time probe) rather than writing a test that is ambiguous between them, express validity thresholds in metres after the linearizing decode instead of as an epsilon in NDC, and set the far plane explicitly to the content radius (or use an infinite-far reverse-Z projection) when content is kilometres away.

**Proposed direction.** Determine the clear value once at pass setup, test presence against that single convention, and move the validity threshold to the metric side (e.g. `contentDistance > 0 && contentDistance < farPlane`), then set the camera's far plane from `arVisibilityRadius`.

## MATH-3 — Magnetic heading is silently substituted for true heading with no declination correction

**Severity:** high  
**File:** `AugmentMeReality/Services/LocationService.swift`:47

**Claim.** When `CLHeading.trueHeading` is unavailable the service substitutes `magneticHeading` under the same property name, and the AR heading estimator consumes it in a variable literally named `trueHeading`, so the local magnetic declination is injected directly into the session's north estimate with no flag, no correction model, and no effect on the accuracy gate.

**Evidence.** `let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading` (LocationService.swift:47) feeding `guard let trueHeading = locationService?.headingDegrees` and `ingestHeadingDelta((trueHeading - yawAR) * .pi / 180, alpha: alpha)` (GeoARSessionManager.swift:1645, 1677). The reliability gate only inspects `locationService?.headingAccuracy` (line 1647), which is the magnetometer's own accuracy and carries no information about declination. `ingestHeadingDelta` seeds outright on the first sample: `if headingSampleCount == 0 || alpha >= 1 { headingCorrectionSin = sin(delta) ... }` (line 1681).

**Failure scenario.** `trueHeading` is negative until Core Location has a position fix, which is precisely the cold-start window in which ADR-003/the TTFO bar require spawning from one seeded compass sample (`headingSampleCount < 1`, line 1128). In Seattle (declination ≈ +15.5°) or New York (≈ −13°) the very first placement is therefore rotated about the viewer by the full declination — 13° at 100 m is 22 m of lateral error, which is ADR-017's own arithmetic for the exact field complaint it was written to fix ("object appears at the right place, then moves"). Worse, once the compass estimate is deemed converged the re-sync threshold widens to 15° (`headingConverged ? 15.0 : 5.0`, line 1175), so a declination error below 15° never triggers a re-sync at all and the drop stays permanently mis-bearinged in any region where VPS never localizes.

**Industry gap.** Location-AR implementations treat magnetic and true heading as different quantities: they either refuse magnetic heading for world alignment, or correct it with a declination model (WMM/IGRF, or Core Location's own true heading once a fix exists) and propagate a "heading is magnetic-only" state into both the estimator's noise model and the UI.

**Proposed direction.** Publish heading with an explicit `isTrueNorth` flag; refuse magnetic-only samples for the ENU→AR correction (or correct them with a declination model) and force a re-sync when the first true-north sample arrives.

## MATH-4 — Transit dead reckoning is open-loop with a hard reset at every GNSS fix

**Severity:** high  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:1745

**Claim.** Every render frame recomputes each drop's position from the raw latest CLLocation advanced by course×speed, with no state carried between fixes and no fusion, so each new GNSS fix injects its full independent error as a position step; and once the fix ages past 8 s the predicted device position freezes while the camera keeps moving, which converts every drop into a vehicle-locked sticker.

**Evidence.** `let device = GeoMath.predicted(from: fix, at: Date())` then `holder.position = SIMD3(x, y, z)` computed as `camPos + rotated ENU(device → drop)` (lines 1745-1759) — the only smoothing anywhere in the chain is the heading EMA, which affects bearing, not range. `GeoMath.predicted` is memoryless: `coordinate(from: location.coordinate, bearingDegrees: location.course, distanceMeters: location.speed * min(elapsed, 8))` (GeoMath.swift:61-65). Because the drop position is `camPos + offset` and `offset` is constant once the prediction saturates, the content translates 1:1 with the VIO camera.

**Failure scenario.** FT-14/FT-15 require far drops to "hold their bearing" and "slide past at the believable rate." On a train, fixes arrive ~1 Hz with 5–15 m independent horizontal error; a 8 m fix-to-fix step moves a drop at 200 m by atan(8/200) = 2.3°, roughly 40–50 px on the panel, once per second — a visible per-second twitch superimposed on the smooth motion, exactly the "world sliding" the test is meant to rule out. In a tunnel (FT-17) the prediction saturates at 8 s and the giant then rides along with the train at a fixed relative position rather than falling behind, which reads as a HUD element pinned to the glass — killer #2's sticker failure — while the status line claims only that positions "may lag".

**Industry gap.** Vehicle-grade geo-pose uses a filter (complementary or Kalman) over GNSS position/velocity plus IMU, so a new fix is an innovation blended in over a time constant rather than a teleport, and the filter's covariance drives both the render and the honesty UI. Freezing an open-loop extrapolation at a fixed 8 s cap is neither an error bound nor a graceful degradation.

**Proposed direction.** Fuse GNSS fixes into a small constant-velocity filter (position + velocity state, innovation gated by horizontalAccuracy) and drive the render from the filter's estimate, so fix arrivals slew rather than step and the growing covariance — not a hardcoded 8 s — decides when to stop trusting the estimate.

## MATH-5 — No terrain elevation model anywhere; transit vertical assumes viewer and drop share a ground plane

**Severity:** high  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:1757

**Claim.** GeoDrop stores no altitude of any kind, and the transit path resolves a drop's world Y as the viewer's camera height minus a fixed 1.5 m, so a drop's vertical position is wrong by the full terrain-elevation difference between viewer and drop — up to tens of metres over the declared 2 km range — with no source of truth available on that path.

**Evidence.** `let y = camPos.y - 1.5 + Float(drop.heightAboveGround) + (drop.isRooftop ? 8 : 0)` (line 1757). `GeoDrop` has only `latitude`, `longitude`, `heightAboveGround` (Models/GeoDrop.swift:49-52) — no altitude, no terrain reference. In transit the VPS terrain-anchor path that ADR-009 designates authoritative is explicitly disabled (`guard renderPath == .pedestrian else { return }`, line 602; `vpsOwnedDrops.removeAll()`, line 1042), so the flat-ground assumption is the *only* vertical model in the mode that renders 50 m–2 km content.

**Failure scenario.** FT-15 asks for a drop 500 m–2 km out to "sit on the horizon at the right spot." Pinned on a hill 60 m above the track, or viewed from a train on a viaduct 10 m above street level, the drop renders 60 m too low or 10 m too high — at 1 km that is 3.4° / 0.6° of vertical error, placing a "giant on the horizon" either buried in the ground plane or floating above the skyline. The constant 1.5 m also assumes a standing pedestrian eye height, which is wrong by ~0.4 m for a seated passenger, the only posture transit mode exists for. Earth curvature (d²/2R = 0.31 m at 2 km) is the smallest of the three errors and is the only one ADR-015 mentions.

**Industry gap.** Location-AR platforms resolve a pinned coordinate's ground elevation from a terrain source (ARCore terrain/rooftop anchors, a DEM tile, or a stored WGS84 ellipsoidal altitude plus a geoid model) and store it with the anchor so it survives modes where the live resolver is unavailable. Deriving remote ground height from the local viewer's floor is only defensible within a few tens of metres.

**Proposed direction.** Persist the resolved terrain altitude on GeoDrop when a VPS terrain/rooftop anchor first resolves it (and/or from a DEM at creation), and use that stored altitude — relative to the viewer's own resolved ground altitude — for the transit vertical instead of `camPos.y − 1.5`.

## MATH-10 — ADR-049's compensation law does not follow from ADR-049's own derivation

**Severity:** medium  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:1907

**Claim.** The ADR derives a *distance-independent* angular demagnification (θ_perceived/θ_real ≈ 0.20–0.25 "at every distance"), which is mathematically corrected by a constant gain; the implemented fix is a distance-dependent power law that applies zero correction inside 8 m — where the same demagnification holds — and 6.9× at 2 km, so the remedy does not address the stated cause and instead makes an object's world-space size a function of viewer distance.

**Evidence.** `return min(max(pow(distance / AppConfig.perceptualD0, AppConfig.perceptualBeta), 1), AppConfig.perceptualCap)` with d₀=8, β=0.35, cap=12 (lines 1909-1912, AppConfig.swift:160-162). ADR-049's derivation: "So θ_perceived/θ_real ≈ 0.20–0.25 **at every distance**" — a constant ratio. The applied factor is 1.0 for all d ≤ 8 m by construction, and the rendered scale is recomputed per frame from the live distance: `let distance = simd_length(holder.position - camPos); let factor = Self.perceptualFactor(atDistance: distance); content.scale = SIMD3(repeating: Float(drop.scale) * factor)` (lines 1923-1934).

**Failure scenario.** Two identical drops placed at 10 m and 100 m render at a physical size ratio of (100/10)^0.35 = 2.24 — a viewer standing between them sees two objects that should be identical but are not, and walking from one to the other watches the far one physically shrink to match the near one. Against real referents the same breaks: a 2 m figure standing beside a 2 m doorway at 60 m renders 3.9 m tall, i.e. twice the doorway, and shrinks back to door height as the viewer approaches — destroying the size-constancy-against-familiar-structure cue that the ADR's own diagnosis says the visual system relies on. In the shared-content product, two viewers at 15 m and 150 m of the same drop are looking at objects of different world size, so a screenshot from one does not match the other.

**Industry gap.** If the measured defect is a fixed angular demagnification of the whole optical chain, the matching correction is a constant scale (or a wider virtual FOV / narrower render FOV), which preserves relative size and depth ordering exactly. Distance-dependent scaling is a legitimate *legibility* device for HUD-class markers (which ADR-008 already permits for orbs), not a correction for a distance-independent optical constant, and the borrowed "size-constancy exponents 0.2–0.4" describe perceived-vs-physical size in observers, not a rendering gain to be applied on top of an observer who already applies it.

**Proposed direction.** Either apply the constant gain the derivation implies (uniform, including inside d₀) or keep the power law but re-scope it explicitly to the marker/legibility layer, and add a test asserting two drops of equal true scale render at equal world size regardless of viewer distance.

## MATH-11 — Geodesy tests validate GeoMath only against its own inverse

**Severity:** medium  
**File:** `AugmentMeRealityTests/GeoMathTests.swift`:8

**Claim.** Every ENU, bearing, and dead-reckoning assertion constructs its expected value by calling another GeoMath function that shares the same Earth model and the same scale constant, so the suite is structurally incapable of detecting any error in that model — including the wrong meters-per-degree constant in MATH-6 — and there is no comparison against a geodesic reference.

**Evidence.** `let target = GeoMath.coordinate(from: origin, bearingDegrees: 0, distanceMeters: 100); let enu = GeoMath.enuOffset(from: origin, to: target); XCTAssertEqual(enu.y, 100, accuracy: 0.5)` (lines 9-11) — `coordinate` divides by `metersPerDegreeLatitude` and `enuOffset` multiplies by it, so the constant cancels identically and the assertion holds for *any* value of the constant. The same pattern appears at lines 15-20, 22-27, 64-70 and 72-78. `CLLocation.distance(from:)` — a WGS84 geodesic available for free in the test target and already used by `DropLibrary.drops(near:within:)` — is never used as a reference.

**Failure scenario.** An engineer changes `metersPerDegreeLatitude` to any value, or swaps the spherical model for a different one, and all five geodesy tests still pass at 0.5 m accuracy. Meanwhile the load-bearing consumers — placement (line 1223), the ADR-041 inverse write-back (line 1549), and the VPS coverage-movement gate (GeospatialEngine.swift:145) — all inherit the undetected error, and the discrepancy against `CLLocation.distance` used for radius filtering goes unnoticed.

**Industry gap.** Geodesy code is tested against an independent implementation or published reference vectors (Vincenty/Karney results, or the platform's own geodesic distance), not against its own round trip. Round-trip tests are valid for detecting sign and convention errors only, and should be labelled as such.

**Proposed direction.** Add assertions comparing `enuOffset` magnitude and `bearing` against `CLLocation.distance(from:)` and a published geodesic reference at several latitudes (0°, 25°, 51.5°) with a stated tolerance, keeping the round-trip tests as convention checks.

## MATH-12 — A single VPS heading sample is re-ingested every tick, over-weighting it and inflating the convergence counter

**Severity:** medium  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:1629

**Claim.** `updateHeadingCorrection` ingests `geospatial.headingErrorSample` on every 2.5 Hz tick whenever it is under 1.5 s old, without checking whether it is the same sample already consumed, so one measurement is folded into the circular EMA up to four times and increments `headingSampleCount` four times — and that counter is what widens the compass re-sync threshold from 5° to 15°.

**Evidence.** `if let sample = geospatial.headingErrorSample, Date().timeIntervalSince(sample.timestamp) < 1.5 { ... ingestHeadingDelta(sample.radians, alpha: vpsAlpha) ... }` (lines 1629-1636) — the only staleness test is age, and the sample is only replaced when `GeospatialEngine.update(with:)` runs, whose cadence is `garFeedInterval` (as slow as 1 s while converging without coverage, line 911). `ingestHeadingDelta` unconditionally does `headingSampleCount += 1` (line 1688), and `let headingConverged = headingSampleCount > 40` gates `headingLimitRad` (lines 1172-1175).

**Failure scenario.** With VPS feeding at 1 Hz and the tick at 2.5 Hz, the same yaw measurement is folded in ~2–3 times, so the estimator converges faster than the measurement noise justifies and a single bad optical yaw (still admitted at up to 20° accuracy, `vpsHeadingMaxYawAccuracyDegrees`) is applied with 2–3× its due weight. Separately, `headingSampleCount` reaches 40 in ~16 s from roughly 15 distinct measurements, after which the compass re-sync limit widens to 15° — so the system declares heading convergence, and stops correcting sub-15° bearing errors, on a sample count that is largely duplicates.

**Industry gap.** Filters keyed on sensor measurements deduplicate by measurement timestamp or sequence, and count independent observations for convergence tests; re-applying the same observation is a textbook double-counting error that makes the estimator overconfident.

**Proposed direction.** Track the last-consumed sample timestamp and skip ingestion when unchanged, and count only distinct measurements toward `headingSampleCount`.

## MATH-13 — Semantic classifier confidence is used directly as compositing alpha

**Severity:** medium  
**File:** `AugmentMeReality/AR/SemanticMatte.metal`:114

**Claim.** For a pixel labeled building/tree the matte value is set to the classifier's raw confidence, treating a posterior probability as a coverage fraction; a partially-confident building pixel therefore renders the content at partial opacity rather than hiding it, which is still a draw-over.

**Evidence.** `matte = semanticConf.sample(bilinearSampler, captureUV).r;` (line 114) — the confidence is assigned as the matte, not thresholded, and flows straight into `mix(color.rgb, linearRGB, half(smoothed))` (line 236). The uncertainty is in the *label*, not in the pixel's spatial coverage of the surface, and no calibration maps one to the other.

**Failure scenario.** A drop 100 m behind a facade whose pixels the segmenter scores at 0.5 renders as a 50%-opacity ghost visible through the wall. BRIEF's hard bar is "zero draw-over-known-front-surface frames" and killer #2 is "never draw content over a building it's geometrically behind" — a half-transparent ghost through a wall fails both, but it is invisible to any test that only checks whether content is fully drawn. Low-confidence regions are also spatially correlated (whole facades in shadow, backlit at dusk), so this is not per-pixel dither noise that averages out — it ghosts entire surfaces.

**Industry gap.** Segmentation posteriors are converted to a compositing alpha through an explicit decision threshold, with feathering derived from the *boundary* (distance transform, matting, or guided edge refinement) rather than from the classifier's certainty; using the posterior as alpha conflates "I am unsure this is a building" with "this pixel is half building".

**Proposed direction.** Threshold the label decision on confidence (accept/reject) and derive the soft edge from the label boundary, so an accepted building pixel occludes fully and an unconfident one does not occlude at all.

## MATH-6 — metersPerDegreeLatitude constant is the equatorial meters-per-degree of LONGITUDE

**Severity:** medium  
**File:** `AugmentMeReality/Services/GeoMath.swift`:8

**Claim.** `metersPerDegreeLatitude = 111_319.49` is exactly 2πa/360 for the WGS84 semi-major axis — the meters per degree of longitude at the equator — not the meters per degree of latitude, which is 110 574.4 m at the equator and 111 132.0 m at 45°; using it for the north axis produces a systematic scale error that is also anisotropic against the east axis, distorting both range and bearing.

**Evidence.** `static let metersPerDegreeLatitude = 111_319.49` (line 8), used as `let north = (target.latitude - origin.latitude) * metersPerDegreeLatitude` (line 15) and inverted at line 46. 2π·6378137/360 = 111 319.49. The correct meridional value M(φ)·π/180 = 110 574.4 at φ=0, 111 132.0 at 45°, 111 257 at 51.5°. Meanwhile the east axis uses `metersPerDegreeLatitude * cos(origin.latitude)`, which *under*-estimates the true prime-vertical value πN(φ)cosφ/180 by up to 0.17%. The file's own docstring claims accuracy "well under GPS error at the sub-kilometer ranges this app renders at."

**Failure scenario.** At the equator every north/south offset is over-scaled by 0.674%: a drop 800 m due north is placed 5.4 m too far, and ADR-041's inverse-ENU writes back a coordinate biased by the same amount, so the error is baked into the shared drop and every other viewer inherits it. At 2 km (the declared visibility radius) the north error reaches 13 m — larger than the VPS accuracy the whole Tier-C stack exists to achieve. The north/east anisotropy (+0.67% vs −0.02% at the equator) additionally rotates a 45° bearing by ~0.19°. At mid-latitudes the error shrinks to 0.06–0.17% and is benign, so this will pass any test run in northern Europe and fail progressively toward the tropics.

**Industry gap.** Tangent-plane geodesy in shipping code uses either the WGS84 meridional/prime-vertical radii of curvature (M(φ), N(φ)) evaluated at the origin latitude, or a proper ECEF→ENU transform. A single hardcoded scalar for both axes is only acceptable with an explicitly stated error budget, and the scalar chosen here is the wrong one of the two.

**Proposed direction.** Replace the single constant with latitude-dependent meridional and prime-vertical scale factors (or do the conversion via ECEF), and state the residual error at 2 km in the docstring.

## MATH-7 — LiDAR alignment samples ignore ARKit's confidenceMap and use non-robust OLS

**Severity:** medium  
**File:** `AugmentMeReality/AR/MidFieldDepthEstimator.swift`:197

**Claim.** The alignment reads `frame.sceneDepth?.depthMap` but never `sceneDepth.confidenceMap`, and fits with plain ordinary least squares plus an in-sample R² gate, so specular, transparent, and low-reflectance returns that land inside the 0.4–4 m band act as unbounded leverage points on both a and b.

**Evidence.** `guard let lidar = frame.sceneDepth?.depthMap else { ... }` (line 116) — `confidenceMap` appears nowhere in the file. The fit accumulates every accepted sample with equal weight (`sumX += rel; sumY += y; ...`, lines 207-208) and accepts on `count >= 40` plus `r2 >= 0.6` (lines 212, 221). There is no residual pass, no trimming, no re-weighting.

**Failure scenario.** Standing at a shop window or a car windscreen — the exact scene ADR-044's Glass Mode exists for — the LiDAR returns a mixture of pane-surface hits at ~1 m and through-glass hits at 3–4 m for pixels whose relative depth is essentially identical. A handful of such points is enough to swing the slope; because b is the extrapolated intercept (see MATH-1), a modest slope error becomes a large error in the far-field ceiling 1/b, and the R² gate still reports ≥0.6 because the bulk of the ground-plane samples dominate the variance. The result is a fit that passes every guard and mis-orders occlusion across the whole mid-field, with no diagnostic that anything went wrong.

**Industry gap.** Apple's own guidance for `ARDepthData` is to gate on `confidenceMap == .high` before any quantitative use, and depth-alignment pipelines universally use a robust estimator (RANSAC, least-median-of-squares, or Huber IRLS) rather than OLS, because a single bad correspondence in a two-parameter fit is unbounded.

**Proposed direction.** Filter samples to high-confidence LiDAR texels, fit with RANSAC or a trimmed/Huber estimator, and gate on the robust residual scale rather than in-sample R².

## MATH-8 — Inverse-depth fit accepts a negative slope, inverting depth ordering

**Severity:** medium  
**File:** `AugmentMeReality/AR/MidFieldDepthEstimator.swift`:221

**Claim.** The acceptance test is `abs(a) > 1e-9`, which admits a < 0; but `1/metric = a·rel + b` is only a valid inverse-depth map when a > 0 (the model emits disparity, so nearer ⇒ larger rel), and a sign-inverted fit turns the mid-field occluder into a depth-order inverter.

**Evidence.** `guard r2 >= 0.6, abs(a) > 1e-9 else { return nil }` (line 221). The correlation-based R² is sign-blind: `let r2 = (covXY * covXY) / (varX * varY)` (line 220) is 1.0 for a perfectly anti-correlated relationship. The shader has no sign check either — only `isfinite(inv) && inv > 1.0 / uniforms.midMaxDepth` (SemanticMatte.metal:204).

**Failure scenario.** Any scene or model-conversion variant in which the network's output is depth rather than disparity (a real risk with third-party CoreML conversions of Depth Anything), or a degenerate scene whose LiDAR band happens to anti-correlate, produces a < 0 with R² near 1. Far background pixels then decode to small metric values; wherever that value lands in (3 m, contentDistance − 1.5·margin) the shader computes `smoothstep(margin*0.5, margin*1.5, contentDistance - metric) = 1` and fully mattes the content out — content vanishes behind empty space. The bundled model's output convention is asserted nowhere in code or tests.

**Industry gap.** A physically-parameterized fit ships with its sign and range constraints enforced at the acceptance boundary, not just its correlation quality; and the polarity of a third-party model's output is pinned by a fixture test rather than assumed.

**Proposed direction.** Change the guard to `a > 1e-6` and add a test that a synthetic anti-correlated (a<0) dataset is rejected, plus a fixture asserting the bundled model's near-pixel output exceeds its far-pixel output.

## MATH-9 — Matte EMA uses a per-render-frame alpha decoupled from the 30 fps capture rate

**Severity:** medium  
**File:** `AugmentMeReality/AR/SemanticMatte.metal`:223

**Claim.** The temporal filter's coefficient is a fixed per-invocation alpha with no dt term, while the kernel runs once per rendered frame and the inputs update once per captured frame; with capture pinned at 30 fps and the render loop free-running at the display rate, the filter iterates 2× (or 4× on ProMotion) per new measurement, collapsing its effective retention and defeating the noise suppression it exists for.

**Evidence.** `float alpha = (matte >= previous) ? uniforms.attackAlpha : uniforms.releaseAlpha; float smoothed = mix(previous, matte, alpha);` (lines 223-224) with `matteAttackAlpha = 0.6`, `matteReleaseAlpha = 0.85` (AppConfig.swift:131-132). Capture is pinned by `filter { $0.framesPerSecond == AppConfig.targetFrameRate }` with `targetFrameRate = 30` (GeoARSessionManager.swift:501, AppConfig.swift:86). `preferredFramesPerSecond` is never set anywhere in the project, so ARView renders at the display link rate. Retention after N iterations on the same input is (1−α)^N: for attack, 0.40 → 0.16 at N=2 → 0.026 at N=4.

**Failure scenario.** The comment above the block states the design intent — "enough memory to kill single-frame stencil noise". With two render frames per captured frame the matte has already absorbed 84% of each new (noisy) stencil before the next measurement arrives, so per-capture-frame stencil flicker passes through essentially unfiltered and the silhouette shimmers on a moving hand — the FT-27 symptom the asymmetric alphas were tuned to fix, reappearing whenever the render rate differs from the tuning rig's. The same coefficients also mean the filter behaves differently under the PowerGovernor's thermal states, so field tuning of these constants is not reproducible.

**Industry gap.** Temporal filters in render pipelines are parameterized by a time constant and converted per frame as `alpha = 1 − exp(−dt/tau)`, or are advanced only when the underlying measurement is new (tracked by frame timestamp). A bare per-frame alpha is only valid when the render and measurement rates are both fixed and equal.

**Proposed direction.** Pass the captured-frame timestamp into the uniforms and either advance the EMA only on a new capture timestamp, or convert the tuned alphas to time constants and compute `alpha = 1 − exp(−dt/tau)` per invocation.

## MATH-14 — The person-matte "guided filter" is a near-box joint-bilateral that softens low-contrast silhouettes

**Severity:** low  
**File:** `AugmentMeReality/AR/SemanticMatte.metal`:179

**Claim.** The edge-refinement step is a joint-bilateral filter (not the guided filter of He et al. that the code, ADR-030, and the type name claim), and its two kernels are mis-parameterized: the spatial term has σ_s ≈ R, making it nearly a box average, and the range term has a fixed luma σ with no local-contrast adaptation, so on a low-contrast silhouette every neighbour gets equal weight and the filter blurs the very edge it is meant to sharpen.

**Evidence.** `float wl = exp(-dl * dl * 30.0);` gives σ_luma = 1/√60 = 0.129 in normalized video-range luma — fixed for all scenes. `float ws = exp(-float(dx*dx + dy*dy) / (2.0 * float(R*R) + 1.0));` gives σ_s = √((2R²+1)/2) = 2.12 for R=2, i.e. the Gaussian's sigma equals the window radius, so the corner tap still carries weight exp(−8/9) = 0.41 — the spatial term contributes almost no falloff. With `personMatteRefineRadius = 2` (AppConfig.swift:94) the window is 5×5 on a full-resolution stencil, so the edge can be displaced by at most 2 px in any case.

**Failure scenario.** At night or against a matching background — dark clothing in front of a dark wall, one of BRIEF's explicit conditions — the luma differences across the silhouette fall well below 0.129, so every wl ≈ 1, every ws ≈ 1, and the weighted average degenerates to an unweighted 5×5 box blur of the stencil. The subsequent `smoothstep(0.55, 0.85, m)` then erodes that blurred edge, so the net effect at exactly the hardest case is a softer, slightly shrunken silhouette rather than a snapped one — the opposite of ADR-030's stated purpose, and invisible in daylight testing where the range term does work.

**Industry gap.** Joint-bilateral upsampling conventionally uses σ_s ≈ R/2–R/3 so the window truncation is at 2–3σ, and adapts the range σ to local guide variance (which is exactly what the guided filter's ε/variance formulation does automatically, and the reason it is preferred over bilateral for matte refinement). Naming the implementation after a different algorithm also hides the discrepancy from review.

**Proposed direction.** Either implement the actual guided filter (local mean/variance with an ε regularizer, which self-adapts to contrast) or set σ_s ≈ R/2 and derive the range σ from the local luma variance in the window; rename the code and ADR to match whichever is shipped.

---

# Reviewer 2 — AR Platform Engineering

## Overall assessment (verbatim)

The AR layer is unusually thoughtful at the algorithm level — the depth-decode derivation in SemanticMatte.metal, the inverse-depth LiDAR alignment, the asymmetric matte EMA, and the perceptual-size law are all correct and well-reasoned, and several things that look wrong on first read (the 4-texel depth max, the ENU→AR bearing convention, the ADR-045 CVMetalTexture retain) verify as sound. The defects are concentrated at the seams: the perception-scheduling gates that decide *whether* the occluders run at all, the ARSession lifecycle, and device-capability handling. Two independent bugs — the missing Vision orientation on the person sentinel and the unreachable `.personSegmentationWithDepth` fallback — mean the person occluder, the most visible occluder in the product and the subject of three ADRs and two field-test rounds, is likely off in normal portrait use and is provably off on every non-LiDAR iPhone. A latched `semanticMatteArmed` flag defeats ADR-035's render-callback detach for the rest of the session. The session lifecycle is the weakest area: there is no `ARSessionDelegate` anywhere in the repo, and every resume performs a full `.resetTracking` while the GARSession beside it is neither restarted nor invalidated, so post-resume VPS anchor updates are applied as ordinary refinements from a world frame that no longer exists. Load-bearing AR logic (heading estimator, deferred-correction state machine, perception-gate composition, window-mode hysteresis) has zero test coverage, and the one governor thermal test asserts on an input the governor never reads.

## ARP-1 — Person occlusion is structurally dead on every non-LiDAR iPhone

**Severity:** critical  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:486

**Claim.** On any device without LiDAR the session requests stencil-only `.personSegmentation` (which deliberately suppresses RealityKit's built-in people occlusion) but the Metal pass can never composite it, because it requires `frame.sceneDepth` which those devices do not provide — and the documented `.personSegmentationWithDepth` fallback is unreachable.

**Evidence.** `makeConfiguration` line 486-491: `if AppConfig.customPersonOcclusion, ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) { config.frameSemantics.insert(.personSegmentation) } else if ...supportsFrameSemantics(.personSegmentationWithDepth) {...}`. `AppConfig.customPersonOcclusion` is a hardcoded `true` (AppConfig.swift:81) and `.personSegmentation` is supported on all A12+ devices, so the `else if` branch can only be reached on pre-A12 hardware where neither semantic exists. Meanwhile SemanticOcclusionPass.swift:215-221 gates the person matte on `frame.segmentationBuffer` AND `frame.sceneDepth?.depthMap` together, and `personEnabled = stencilTexture != nil && sceneDepthTexture != nil`. `wantsPersonOcclusion` at GeoARSessionManager.swift:266 has no LiDAR gate either, so the pass is constructed with `personOcclusionEnabled: true` on hardware that can never satisfy it. ADR-030's own key enabler is stated as "on a LiDAR device `frame.sceneDepth` already contains the person's real depth" — the non-LiDAR case is simply not handled.

**Failure scenario.** A user on an iPhone 15 (non-Pro), 14, 13, 12 or SE3 opens a drop, a friend walks between them and the content: the content draws straight over the person, every frame, with no degradation notice. The phone still pays the full 14–29 ms/frame `.personSegmentation` cost the whole time, so it is the worst of both — zero occlusion at maximum heat. This is a direct violation of BRIEF killer #2 ("zero draw-over-known-front-surface frames") on the majority of the addressable install base.

**Industry gap.** Standard iOS AR practice is to branch capability at one place and degrade explicitly: if `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)` is false, request `.personSegmentationWithDepth` and let RealityKit's built-in people occlusion carry it (blurrier, but present), and set `personOcclusionEnabled` on the custom pass to false so the segmentation stream is not requested for nothing. Apple's own People Occlusion guidance treats depth availability as the branch point, not as an assumption.

**Proposed direction.** Gate `wantsPersonOcclusion` on `supportsFrameSemantics(.sceneDepth)` as well, and make the `.personSegmentationWithDepth` fallback reachable whenever the custom path's depth prerequisite is unmet.

## ARP-2 — Person-presence sentinel feeds Vision a 90°-rotated image, so the gate rarely opens

**Severity:** critical  
**File:** `AugmentMeReality/Services/PersonSentinel.swift`:53

**Claim.** The ADR-037 sentinel that gates the entire person-segmentation stream runs `VNDetectHumanRectanglesRequest` on ARKit's raw `capturedImage` with no `CGImagePropertyOrientation`, so with the app locked to portrait Vision sees every human rotated 90°; detection rate collapses and `personLikely` stays false, which keeps `.personSegmentation` out of the configuration entirely.

**Evidence.** `let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)` (PersonSentinel.swift:53) — no orientation argument, so Vision defaults to `.up`. The buffer is `frame.capturedImage` (GeoARSessionManager.swift:1805), which ARKit delivers in landscape sensor orientation; the app is portrait-locked (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = UIInterfaceOrientationPortrait`, project.pbxproj:349). The sentinel's verdict is load-bearing: `let personUseful = ... && personSentinel.personLikely && !windowModeActive` (GeoARSessionManager.swift:859-861) feeds `setPerception(active:person:depth:)` at line 865, and `personEnabled` in the shader depends on the stencil that only arrives when that semantic is set.

**Failure scenario.** On a LiDAR iPhone in normal portrait use, a person walks between the camera and the content. The upper-body detector, looking at a sideways torso, mostly returns no results; `personLikely` never becomes true; `.personSegmentation` and `.sceneDepth` are never inserted into the configuration; `frame.segmentationBuffer` is nil; the Metal pass's person branch never runs. The content draws over the person indefinitely — not for the ~1 s ADR-037 declares as the accepted cost of the trade, but permanently. Combined with ARP-1 this means people occlusion is unreliable on LiDAR devices and absent on non-LiDAR devices.

**Industry gap.** Every Apple Vision-on-ARKit sample passes an explicit `CGImagePropertyOrientation` derived from the current interface orientation (`.right` for a portrait rear camera) when constructing `VNImageRequestHandler` from `frame.capturedImage`. Vision's detectors are trained on upright subjects and are documented as orientation-sensitive; omitting the parameter is the single most common Vision-on-ARKit integration bug.

**Proposed direction.** Pass `orientation: .right` (or derive it from the interface orientation) to `VNImageRequestHandler` in the sentinel, and add a device check that the gate actually opens with a person in frame.

## ARP-3 — semanticMatteArmed latches true, permanently defeating ADR-035's render-callback detach

**Severity:** high  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:1835

**Claim.** `semanticMatteArmed` is only ever written inside a block guarded by `geospatial.semanticActive`, so when the semantics NN is switched off while the flag is true, the flag can never be cleared — the Metal post-process callbacks stay attached for the rest of the session and the HUD keeps claiming the semantic matte is armed.

**Evidence.** `if semanticPass != nil, geospatial.semanticActive { ... if farMode != semanticMatteArmed { semanticMatteArmed = farMode } }` (lines 1835-1847). `semanticActive` is driven by `geospatial.setSemanticsActive(needsSemantics && tier > .idle)` (line 875) where `needsSemantics` requires some drop beyond 55 m (lines 870-874), while `farMode` requires some drop beyond `semanticMatteTreeDistance` = 15 m (line 1841, AppConfig.swift:63). The two thresholds differ, so the 15–55 m band is exactly where semantics turns off while `farMode` is still true. `passNeeded = appliedPerception.person || semanticMatteArmed || midDepthActive` (line 879) then stays true forever, so `semanticPass?.setCallbacksActive(false)` (line 885) is never reached. Grep confirms lines 1844-1845 are the only writes to the flag.

**Failure scenario.** A user walks toward a drop from 80 m. At >55 m semantics enables and the matte arms. Crossing 55 m, `setSemanticsActive(false)` runs, the guarded block stops executing, and `semanticMatteArmed` freezes at true. For the remainder of the session the post-process pass is attached every frame — ADR-035 states plainly that an idle attached pass "forces RealityKit through an offscreen render + full-screen copy every frame — real bandwidth, real heat" — and the purple SEM chip stays lit while Google's NN is off, so a field heat report reads the wrong cause. This is the exact regression ADR-035 was written to eliminate, reintroduced by a flag that cannot fall.

**Industry gap.** State that gates resource attachment is normally computed unconditionally each tick from its inputs and only then compared, never written inside the branch that its own precondition guards. A derived-state flag with an asymmetric write path is a well-known latch bug; leading teams either make it a pure computed property or assert reachability of the false branch in a test.

**Proposed direction.** Compute `farMode` (and hence `semanticMatteArmed`) unconditionally, clearing it to false whenever `semanticPass == nil` or `geospatial.semanticActive` is false, before the pass-attachment decision reads it.

## ARP-4 — Every resume hard-resets ARKit world tracking while the GARSession beside it is left stale

**Severity:** high  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:312

**Claim.** `resumeSession()` re-enters `runGPSCompass()`, which runs the configuration with `[.resetTracking, .removeExistingAnchors]` and calls `resetPlacements()`, destroying all content, heading state, ground locks and VPS ownership — while `GeospatialEngine` is neither stopped/restarted nor told to invalidate its anchors, so its `requestedDrops`/`resolvedDrops` sets and its GARAnchors survive into a world coordinate frame that no longer exists.

**Evidence.** `resumeSession()` (line 312-316) calls `runGPSCompass()`, which at line 536-537 does `arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])` then `resetPlacements()`. `resetPlacements()` (557-595) clears `vpsOwnedDrops`, `placedHolders`, `groundLockBaseY`, `headingCorrectionSin/Cos`, `headingSampleCount`, `placementBasis` — but touches nothing in `geospatial`. `GeospatialEngine.requestedDrops` and `resolvedDrops` (GeospatialEngine.swift:60-61) are only cleared by `stop()` or per-drop `invalidateAnchor`, neither of which is on this path. The resume path is reached from `ARSessionHolder.startIfNeeded()` line 89-91 (`else if !sessionRunning { manager.resumeSession() }`), which fires after `appDidEnterBackground()` → `suspend()` and after every tab-flip beyond the 5 s `pauseGraceSeconds`.

**Failure scenario.** User is watching a drop, takes a phone call or switches apps for 10 s, comes back. All content vanishes and re-places from the raw GPS fix; VIO restarts from `.limited(.initializing)`; the LiDAR mesh is discarded and re-scanned; the ground lock the user set with "Place on ground" is gone. Worse, the next `garFrame.updatedAnchors` for an already-resolved drop takes the `isFirst == false` branch of `applyVPSTransform` (line 622), computes a `correction` against a holder whose world origin just moved, exceeds 5 m, and glides the drop to a position derived from the pre-reset frame — the object ends up somewhere wrong and `requestAnchor` will not re-pin it because `requestedDrops` still contains its id.

**Industry gap.** Apple's documented recovery for a paused session is to re-run the *same* configuration without `.resetTracking` and let ARKit relocalize against the retained world map (`sessionShouldAttemptRelocalization`), preserving anchors. ARCore's iOS Geospatial guidance likewise treats an ARKit tracking reset as an event the GARSession must be recreated across, since GARAnchor transforms are expressed in the ARSession world frame.

**Proposed direction.** Split resume from cold start: re-run the existing configuration with no options and rely on relocalization, and if a reset is genuinely required, tear down and restart the GeospatialEngine so every anchor is re-requested in the new frame.

## ARP-5 — No ARSessionDelegate anywhere: interruptions, errors and tracking state are unhandled

**Severity:** high  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:230

**Claim.** The app never sets `arView.session.delegate` and implements none of `sessionWasInterrupted`, `sessionInterruptionEnded`, `session(_:didFailWithError:)`, `session(_:cameraDidChangeTrackingState:)` or `sessionShouldAttemptRelocalization`, so every ARKit failure and interruption is silent and unrecovered.

**Evidence.** A repo-wide grep for `ARSessionDelegate|ARSessionObserver|sessionWasInterrupted|sessionInterruptionEnded|didFailWithError|session.delegate|cameraDidChangeTrackingState|sessionShouldAttemptRelocalization` across all Swift files returns only `LocationService.swift:62` (a CLLocationManager method). `attach()` (line 230-284) wires a `SceneEvents.Update` subscription and the geospatial callback but no session delegate. Placement in `tickGPSCompass` proceeds off `frame.camera.transform` (line 1206) with no check of `frame.camera.trackingState`, and `basisCameraPosition` (line 1301) is captured from it unconditionally. ADR-045's own launch-gap register lists "ARSession interruption/error delegates (call/lock recovery is untested code)" as an open P1.

**Failure scenario.** An incoming call arrives mid-session: ARKit interrupts, the camera feed freezes, and nothing in the app knows. On return there is no relocalization attempt and no UI signal; the user sees a stalled viewfinder with content still drawn at pre-interruption positions. Separately, if `session.run` is ever handed an unsupported frameSemantics combination or the camera is revoked mid-session, ARKit reports it through `didFailWithError` — which is unimplemented — so the session dies with a black viewfinder, `sessionFrameReady` stuck true, the reveal overlay already dismissed, and no recovery path. And because tracking state is never consulted, placements captured during `.limited(.initializing)` poison `basisCameraPosition`, corrupting the GPS-vs-AR drift comparison that drives every subsequent refinement.

**Industry gap.** Implementing `ARSessionObserver` is the baseline contract for a shipping ARKit app: Apple's session-lifecycle documentation makes interruption/resume, error surfacing, and relocalization-vs-reset an explicit app responsibility, and every Apple ARKit sample implements all four callbacks. BRIEF's own 99.5% crash-free / TTFO bars are unmeasurable without them.

**Proposed direction.** Adopt `ARSessionDelegate` on the manager, surface `didFailWithError` to the HUD, gate placement on `.normal` tracking state, and use interruption callbacks plus `sessionShouldAttemptRelocalization` to drive resume instead of a blind reset.

## ARP-6 — 30 fps video-format picker has a resolution floor but no ceiling — can re-select the 4K@30 heat bug

**Severity:** high  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:500

**Claim.** The format filter constrains only the *minimum* pixel area (≥720p) among 30 fps formats and then takes the smallest; if the device's 30 fps format list contains only a 4K entry, the "fix" selects exactly the 3840×2160@30 format ADR-034 identifies as the root cause of the 3-minutes-to-hot regression.

**Evidence.** Lines 500-508: `.filter { $0.framesPerSecond == AppConfig.targetFrameRate }.filter { $0.imageResolution.width * $0.imageResolution.height >= 1280 * 720 }.sorted { area < area }` then `candidates.first`. There is no upper bound. ADR-034 item 1 states the prior bug was that "'nearest 30 fps' could select a 4K@30 capture format — 4× the pixels through the ISP and through every ARKit ML model vs the 1440p default", which establishes that a 4K@30 entry exists in `supportedVideoFormats` on the target iPhone 15 Pro Max. The exact-equality filter also has no fallback: if no 30 fps format ≥720p exists at all, `candidates.first` is nil and ARKit's 60 fps default silently stands, meaning ADR-030's "biggest single lever on heat" is a no-op with no distinguishing signal beyond a log line.

**Failure scenario.** On any device whose only 30 fps world-tracking format is 4K, the app runs the entire perception stack — person segmentation, sceneDepth ML fusion, Depth Anything, the guided-filter post-process — over 8.3 Mpx frames instead of 2.8 Mpx. FT-28's "steady ~30 fps, no thermal warning" bar fails and the HUD line reads `3840×2160@30`, i.e. the field evidence would show the regression but the code has no guard preventing it. On the opposite device class the cap silently doesn't apply and the phone runs 60 fps capture.

**Industry gap.** Production AR frame-rate capping specifies both bounds — a target fps and a maximum pixel area (typically ≤1920×1440) — and asserts/logs loudly when no format satisfies the policy rather than falling through to the platform default. Modern ARKit also exposes `configurableCaptureDeviceForPrimaryCamera` for explicitly clamping `activeVideoMinFrameDuration` when the format list has no suitable entry.

**Proposed direction.** Add an upper area bound (e.g. ≤1920×1440), accept `framesPerSecond <= targetFrameRate` rather than exact equality, and emit an explicit warning when the policy cannot be satisfied.

## ARP-7 — Streetscape building meshes are decoded and generated synchronously on the main actor per GAR frame

**Severity:** high  
**File:** `AugmentMeReality/AR/GeospatialEngine.swift`:409

**Claim.** `makeMeshResource` copies every vertex and triangle in a scalar Swift loop and calls the synchronous `MeshResource.generate(from:)` on the main actor, inside `syncOccluders` which runs from the per-frame `update(with:)` — the same class of main-thread stall ADR-032 declared a hard rule against for USDZ.

**Evidence.** `GeospatialEngine` is `@MainActor` (line 22). `update(with frame:)` calls `syncOccluders(geometries)` at line 225. `syncOccluders` (372-393) calls `makeMeshResource(from: geometry.mesh)` for each newly-seen building. `makeMeshResource` (409-432) runs `for index in 0..<vertexCount { positions.append(...) }` and `for index in 0..<triangleCount { indices.append(x3) }` element-by-element, then `try? MeshResource.generate(from: [descriptor])`. This executes on the main thread at the GAR feed cadence (up to 15 Hz in full tier, every frame during a convergence sprint — `garFeedInterval`, GeoARSessionManager.swift:902-927).

**Failure scenario.** The user walks around a corner in a dense urban block; ARCore streams in a dozen new `GARStreetscapeGeometry` buildings on one update. The main thread spends tens to hundreds of milliseconds building vertex arrays and generating MeshResources, the render loop and all SwiftUI HUD updates stall, and the user sees a hitch and a visible drop below the 30 fps bar precisely at the moment the far-field occluders were supposed to make content disappear behind buildings. Because `MeshResource.generate` failures are swallowed by `try?`, a partial or malformed geometry produces a silently missing occluder instead of a diagnostic.

**Industry gap.** Mesh construction from streamed geometry is done off the main thread as standard practice — either `MeshResource.generate(from:)` on a background queue with the resulting resource handed back to the main actor, or RealityKit's async generation API. ARCore's own iOS Streetscape samples build occluder geometry off the render path. ADR-032 already codified this rule for assets; streetscape meshes were not brought under it.

**Proposed direction.** Move vertex/index extraction and `MeshResource.generate` to a background queue keyed by geometry identifier, and install the resulting entity on the main actor when it lands, exactly as the USDZ loader does.

## ARP-10 — Ground lock is measured under the viewer, then permanently vetoes VPS terrain altitude

**Severity:** medium  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:1487

**Claim.** `snapNearestDropToGround` falls back to a ground estimate taken under the *camera* when neither raycast hits — which is the normal outcome for any drop more than a few metres away — and then writes that value into `groundLockBaseY`, where it overrides Google's terrain-resolved altitude for the rest of the session.

**Evidence.** Lines 1467-1492: an `ARRaycastQuery` with `allowing: .estimatedPlane` straight down from 3 m above the drop, then a `.sceneUnderstanding` mesh raycast with `length: 30`, then `groundY = estimatedGroundY(frame:) ?? (frame.camera.transform.columns.3.y - 1.65)`. `estimatedGroundY` (1950-1961) selects the lowest horizontal plane anchor within `camY - 4 ... camY - 0.5` — a band defined relative to the *camera*, populated by planes ARKit detected near the user. There is no distance guard on the drop. Line 1499 then sets `groundLockBaseY[drop.id] = groundY + 0.005`, and `applyVPSTransform` line 611-613 does `if let lockY = groundLockBaseY[dropID] { transform.columns.3.y = lockY }` — the terrain anchor's Y is discarded unconditionally.

**Failure scenario.** A creator standing at the bottom of a slope taps "Place on ground" for a drop pinned 60 m uphill. Both raycasts miss (no plane and no mesh out there), so the fallback grounds the drop to the elevation under the creator's feet, several metres below the real terrain — and that value is then locked as authoritative, so when Google's terrain anchor resolves with the correct elevation it is overwritten and the drop stays buried in the hillside for the whole session. ADR-027 introduced the lock precisely because "the geo pipeline lifted it again", but it locks a value that may never have been a measurement.

**Industry gap.** A manual ground-truth override should only be established when the measurement that produced it is actually trustworthy — i.e. gated on the raycast that hit real geometry, with distance and hit-type recorded. Promoting a camera-local heuristic to authoritative status, ahead of a service that resolved the real terrain elevation at the drop's own coordinate, inverts the accuracy ordering.

**Proposed direction.** Set `groundLockBaseY` only when the plane or mesh raycast returned a hit near the drop's own XZ, and let VPS terrain win whenever the lock came from the camera-relative fallback.

## ARP-11 — SemanticOcclusionPass mutable state is shared between the main actor and the render thread unsynchronized

**Severity:** medium  
**File:** `AugmentMeReality/AR/SemanticOcclusionPass.swift`:139

**Claim.** `SemanticOcclusionPass` is a plain non-Sendable class whose fields are written from the main actor (`setCallbacksActive`, `uninstall`) and from RealityKit's render thread (`prepare(device:)`, `encode`), with no lock — and `arView.renderCallbacks` is mutated from the main thread while the render thread may be executing the callbacks it holds.

**Evidence.** The class has no isolation annotation (line 45) and is constructed inside `@MainActor GeoARSessionManager.attach` (GeoARSessionManager.swift:273-282). `setCallbacksActive` (139-153) writes `callbacksActive` and assigns `arView.renderCallbacks.prepareWithDevice` / `.postProcess` — called from `updatePowerTier` on the main actor at 2.5 Hz (GeoARSessionManager.swift:882, 886). `prepare(device:)` (161-175) writes `device`, `pipeline`, `textureCache`, `dummyUint/Unorm/Float` from RealityKit's `prepareWithDevice` callback. `encode` (185-324) reads all of those and mutates `inFlightTextures`, `matteTextures` and `matteIndex` on the render thread. `uninstall()` (155-159) writes `pipeline = nil; matteTextures = []` from the main actor. The project builds in Swift 5 language mode (`SWIFT_VERSION = 5.0`), so none of this is diagnosed at compile time.

**Failure scenario.** The governor toggles the pass on and off repeatedly as a person enters and leaves frame (`personLikely` flips on a 5 s timer) or as `passIdleSince` expires. Each toggle mutates `renderCallbacks` from the main thread with no ordering guarantee against an in-flight `encode`. The realistic symptoms are intermittent and hard to attribute: a dropped or garbage post-process frame at the moment of attach/detach, or — if `uninstall()` is ever wired up, which `detach()` already calls — a Swift array exclusivity trap on `matteTextures` while `ensureMatteTextures` is resizing it on the render thread, i.e. a crash against the 99.5% crash-free bar.

**Industry gap.** Post-process passes that are attached and detached at runtime normally either live entirely on the render thread with a single atomic/locked "enabled" flag read inside the callback, or install the callback once at setup and early-out cheaply, rather than mutating the render-callback closures from another thread. Marking the type `@unchecked Sendable` with an explicit lock — the pattern already used correctly for `SemanticFeed` and `MidFieldDepthFeed` in this same file — is the house style that was not applied to the pass itself.

**Proposed direction.** Install the callbacks once and gate the work inside `encode` on a lock-protected or atomic flag, so nothing crossing the main-actor/render-thread boundary is mutated while the GPU path is live.

## ARP-12 — ARKit-owned pixel buffers are handed to background queues without retaining the ARFrame

**Severity:** medium  
**File:** `AugmentMeReality/AR/MidFieldDepthEstimator.swift`:120

**Claim.** Both neural consumers extract `frame.capturedImage` (and `frame.sceneDepth!.depthMap`) and use them on a background queue for the duration of an inference, without holding the `ARFrame`, and the Metal pass's `CVMetalTextureCache` is never flushed — three ways of holding ARKit's capture pool hostage.

**Evidence.** `MidFieldDepthEstimator.update` (lines 116-152) captures `let lidar = frame.sceneDepth?.depthMap` and `let image = frame.capturedImage`, then dispatches to `queue` where a full Depth Anything V2 inference plus a 560-sample `fitInverseDepth` run over both buffers; the `ARFrame` itself is not retained. `PersonSentinel.update` (PersonSentinel.swift:28-61) does the same with `frame.capturedImage` (called at GeoARSessionManager.swift:1805). `SemanticOcclusionPass.makeTexture` (352-367) wraps `frame.capturedImage` in CVMetalTextures held until the command buffer completes, but `CVMetalTextureCacheFlush` is never called anywhere in the file, and on the bail-out paths (line 198, 241, 249) the wrappers created earlier in that frame stay in `inFlightTextures` until the *next* `encode`.

**Failure scenario.** During a full-tier session all three paths hold capture buffers concurrently: the sentinel for ~10–30 ms at 2 Hz, the depth estimator for ~17–50 ms at 5 Hz, and the post-process for at least one frame period. ARKit's capture pool is small; sustained pressure on it manifests as intermittent dropped ARFrames and a sawtooth fps trace that looks like thermal throttling but isn't, making the FT-28/FT-31 heat instrumentation ambiguous. The unflushed texture cache compounds it by retaining IOSurface backing for buffers that are no longer referenced.

**Industry gap.** Apple's guidance is that `ARFrame.capturedImage` is pool-managed and should be retained only briefly; the standard pattern for handing camera pixels to Vision or CoreML is to retain the `ARFrame` for the duration of the work (or copy into an app-owned buffer) and to call `CVMetalTextureCacheFlush(cache, 0)` once per frame after encoding.

**Proposed direction.** Retain the `ARFrame` alongside the extracted buffers for the lifetime of each async request, and add a per-frame `CVMetalTextureCacheFlush` after `addCompletedHandler` is installed.

## ARP-13 — No test coverage on any load-bearing AR logic; one governor test asserts on a dead input

**Severity:** medium  
**File:** `AugmentMeRealityTests/PowerGovernorTests.swift`:78

**Claim.** The AR subsystem's only tests cover `PowerGovernor`'s pure tier table, `perceptualFactor`, and the depth fit; the heading estimator, ENU→AR bearing conversion, deferred-correction state machine, window-mode hysteresis, and the composition of the perception gates are untested — and `testThermalSeriousKeepsTierSubsystemShedsHandleIt` asserts on `thermalSerious`, an input `evaluate` never reads.

**Evidence.** `PowerGovernor.evaluate` (PowerGovernor.swift:58-94) reads `cameraVisible`, `hasRenderedContent`, `contentInView`, `nearestRenderedDistance`, `vpsConverging`, `isLiveEditing`, `thermalCritical` — `inputs.thermalSerious` (declared line 44) appears nowhere in the body. `testThermalSeriousKeepsTierSubsystemShedsHandleIt` (PowerGovernorTests.swift:78-83) therefore passes for a reason unrelated to the policy it claims to pin, and would keep passing if a `.serious` clamp were reintroduced by accident on a different field. Meanwhile a grep for `SemanticOcclusion|GeoARSessionManager|GeospatialEngine|PersonSentinel` across `AugmentMeRealityTests/` matches only `PerceptualSizeTests` and `MidFieldDepthTests` — nothing exercises `updateHeadingCorrection`, `ingestHeadingDelta`, `isInView`, `drainDeferredCorrections`, `updateWindowMode`, or the `personUseful`/`depthUseful`/`passNeeded` composition where ARP-3 and ARP-8 live.

**Failure scenario.** ARP-3's latch, ARP-8's transit gap, and the sentinel gate in ARP-2 are all pure decision logic reachable with no ARKit dependency, and all three would be caught by a table-driven test over the gate inputs. As written, any of them can regress or be reintroduced with a green suite, and the field-test cycle (a person on a real street) is the only detector — which is precisely the loop the ADR log shows repeating for ADR-030/033/034/035/037.

**Industry gap.** Teams shipping this class of AR product extract the scheduling policy into pure functions and pin the full input→output table, including the transitions between modes, exactly as `PowerGovernor` was extracted. The extraction was done for the tier decision but stopped short of the gates that actually determine whether each occluder runs.

**Proposed direction.** Extract the perception-gate composition (person/depth/semantics/pass-attach) into a pure function over an explicit input struct, and pin its transitions — especially semantics-off-while-far-mode-true and transit — with tests.

## ARP-8 — Transit mode keeps LiDAR scene reconstruction running while declaring it untrusted

**Severity:** medium  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:1036

**Claim.** Switching to the transit render path removes `.occlusion` from RealityKit's scene understanding but leaves `config.sceneReconstruction = .mesh` requested, so ARKit continues full LiDAR meshing at vehicle speed through glass — producing garbage anchors that nothing in the transit path consumes, at the largest sustained power draw in the stack.

**Evidence.** `applyRenderPathIfNeeded` case `.transit` (lines 1036-1044) only does `arView.environment.sceneUnderstanding.options.remove(.occlusion)` and `geospatial.setOccludersHidden(true)`; it never touches the configuration. `setPerception(active: tier > .idle, ...)` (line 865) has no render-path term, and `makeConfiguration` sets `config.sceneReconstruction = .mesh` whenever `activePerception` is true (lines 472-474). In transit, `updateWindowMode` returns before any `.sceneUnderstanding` raycast (line 758), `snapNearestDropToGround` is a user action not on this path, and `transitFrameUpdate` (1742-1765) uses only the geo-pose — so no consumer of the mesh exists. `depthUseful` (line 862-864) likewise has no render-path term, so `.sceneDepth` can also be requested in transit even though the mid-depth path explicitly requires `renderPath == .pedestrian` (line 1820).

**Failure scenario.** On a train, the app runs LiDAR scene reconstruction against a window and a moving exterior for the whole journey. The mesh is meaningless (reflections and a pane at 1 m), it is never rendered or raycast, and it burns the sensor plus reconstruction budget continuously — directly against ADR-033's premise that "every expensive subsystem runs only in the moments the scene actually needs it" and against the ≥30 fps / not-`.serious`-at-10-min transit bars.

**Industry gap.** Perception scheduling in shipped AR products is expressed as a single derived requirement set per mode, so that turning off a *use* of a sensor stream also turns off the *request* for it. Splitting the two — removing the RealityKit render option while leaving the ARKit configuration semantic set — is the classic way an on-demand power ledger silently stops holding.

**Proposed direction.** Fold `renderPath` and `windowModeActive` into `setPerception`'s inputs so the scene-reconstruction and scene-depth requests are derived from the same predicate that decides whether their output is used.

## ARP-9 — occlusionActive is a device-capability flag published as a live occlusion status

**Severity:** medium  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:534

**Claim.** `occlusionActive` — documented as "True when LiDAR scene occlusion is active (real objects hide virtual content)" and rendered as the HUD's LiDAR chip — is assigned once from a static capability check and never reflects the many states in which mesh occlusion is provably off.

**Evidence.** Line 526-534: `let occlusionCapable = supportsSceneReconstruction(.mesh) || supportsFrameSemantics(.sceneDepth)`; `occlusionActive = occlusionCapable`. That is the only assignment (grep confirms). Meanwhile `.occlusion` is removed from `sceneUnderstanding.options` in Glass mode (line 797) and in transit (line 1040) without updating the flag, and at `activePerception: false` — which is the state `runGPSCompass` itself installs at line 523 — `config.sceneReconstruction` is never set, so `.occlusion` is inserted at line 529 against a session that has no mesh to occlude with. ARScreen.swift:372 renders the chip straight off this flag.

**Failure scenario.** An engineer reading a field report sees the blue LiDAR chip lit while content draws over a real wall and concludes the mesh occluder is broken, when in fact it was never requested (idle perception) or was deliberately disabled (Glass/Transit). Given BRIEF's occlusion-honesty bar and ADR-044's explicit statement that "the chip keeps it honest", a status indicator that reports capability instead of state undermines the only field instrument for the product's second killer.

**Industry gap.** Occlusion status surfaced to users or field testers is normally derived from the live configuration (is `sceneReconstruction` requested, is `.occlusion` in the options, is a mesh anchor present), not from a one-shot `supportsX` probe. Conflating capability with activity is the standard way an honesty indicator stops being honest.

**Proposed direction.** Recompute the published flag each tick from the applied perception state plus the current `sceneUnderstanding.options`, and keep the capability check as a separate private constant.

## ARP-14 — Every GARSession error is swallowed by try?, collapsing all VPS failures into a stuck status chip

**Severity:** low  
**File:** `AugmentMeReality/AR/GeospatialEngine.swift`:211

**Claim.** `update`, `geospatialTransform`, and `setConfiguration` discard their errors, so ARCore's distinct failure codes (deadline exceeded, not tracking, illegal state, reconfiguration rejected) are indistinguishable from "still searching" both in the HUD and in the logs.

**Evidence.** Line 211: `guard let garFrame = try? garSession.update(frame) else { return }` — no logging, no state change, so a permanently failing feed leaves `state` at whatever it last was. Line 163: `guard let geo = try? garSession.geospatialTransform(transform: transform) else { return nil }`, which silently pushes `relocateNearestDrop` onto the GPS fallback (GeoARSessionManager.swift:1542). Line 176-177: `garSession.setConfiguration(configuration, error: &error); guard error == nil else { return }` — `setSemanticsActive` returns without setting `semanticActive`, without logging, and without any retry, so the ADR-035 semantics toggle can fail permanently and invisibly.

**Failure scenario.** VPS stops producing frames for any reason (quota, transient ARCore error, frames fed out of order). `state` remains `.searching`, so `isConverging` stays true, so the ADR-036 sprint ladder keeps feeding at up to 30 Hz, so the phone heats — and the HUD chip reads "VPS searching…" indefinitely with no line in the metrics log distinguishing this from genuine non-coverage. A field report of "VPS never locked and the phone got hot" is then unattributable.

**Industry gap.** SDK calls whose failure changes system behaviour are logged with their error code at minimum, and repeated failures are counted and surfaced; `try?` on a per-frame SDK entry point that drives a power-scheduling state machine removes the only evidence a field test could produce.

**Proposed direction.** Capture and os_log the GARSession error codes (rate-limited), and transition to `.failed` after a sustained run of update failures so the sprint ladder and the HUD both reflect reality.

---

# Reviewer 3 — Swift Systems Engineering

## Overall assessment (verbatim)

This codebase is unusually thoughtful about the things it has been forced to measure — the Metal pass' CVMetalTexture lifetime, the asset-decode stall, the power governor, the depth alignment fit — and those areas are genuinely well engineered, with lock-guarded hand-off types (SemanticFeed, MidFieldDepthFeed) and pure, testable decision logic. The weakness is systematic and lies everywhere field testing has not yet pointed a finger: app lifecycle, error propagation, and per-drop state ownership. The most serious defect is that an AR session paused by backgrounding is never resumed — there is no ARSessionDelegate and no scene-phase resume path anywhere in the project — and the resume path that does exist destroys the world map and every placement, which contradicts both ADR-013/043 and BRIEF's killers #1 and #2. Concurrency discipline is good where a lock was consciously added and absent where it was not: SemanticOcclusionPass mutates Metal state from the render thread and the main actor with no synchronization, and LocalDropStore performs unserialized read-modify-write from concurrent Tasks. GeoARSessionManager's 2000 lines are not merely long: per-drop state lives in fourteen parallel dictionaries with three incomplete cleanup sites, and that incompleteness already produces a real defect (a leaked liveEditingDrops entry pins the power governor at full tier for the session). Finally, the app is pervasively silent on failure — cloud writes no-op without auth, local writes are `try?`-swallowed, a decode failure quarantines the entire library without telling anyone — which makes the create → share → return loop, the product's whole reason to exist, capable of failing end to end with no signal to either party.

## SWE-1 — AR session never resumes after app backgrounding — frozen viewfinder

**Severity:** critical  
**File:** `AugmentMeReality/App/ARSessionHolder.swift`:74

**Claim.** When the app is backgrounded while the AR fullScreenCover is presented, the ARSession is paused and nothing ever resumes it, leaving a frozen camera image and dead tracking until the user manually closes and re-opens the camera.

**Evidence.** `appDidEnterBackground()` → `suspend()` → `manager.suspendSession()` which calls `arView?.session.pause()` and sets `sessionRunning = false` (ARSessionHolder.swift:74-77, 107-111; GeoARSessionManager.swift:303-310). The only foreground handler is `AugmentMeRealityApp.swift:40-44`, which calls `configure(...)` (no-op after first call, guarded by `if self.locationService == nil`) and `warmWithoutCamera()` (no-op when `arView != nil`). Nothing calls `startIfNeeded()`/`resumeSession()`. The only callers of `cameraDidAppear()` are `ARScreen.onAppear` and `onChange(of: isActive)` (ARScreen.swift:69-91), and `isActive` is hard-coded `true` at the call site (`RootView.swift:29`), so neither fires on scene-phase change. There is also no `ARSessionDelegate`/`sessionWasInterrupted` implementation anywhere in the project (grep: zero hits).

**Failure scenario.** User is in AR looking at a drop. A phone call arrives, or they swipe to the home screen / app switcher for two seconds, then return. The viewfinder shows a frozen last frame, the HUD reads "Paused", `renderFPS` stops updating, the 400 ms tick is cancelled, and no content updates. The user must tap the chevron-down to dismiss the cover and re-open the camera to get a live session back. Against BRIEF's crash-free/quality bar this reads as a hang.

**Industry gap.** Shipping ARKit apps implement `ARSessionObserver` (`sessionWasInterrupted` / `sessionInterruptionEnded` / `session(_:didFailWithError:)`) and re-run the configuration on `UIApplication.didBecomeActiveNotification` or `scenePhase == .active`. Apple's own ARKit sample code and HIG treat interruption recovery as mandatory; ADR-045's own register flags "ARSession interruption/error delegates … untested code" but the code path does not merely lack tests, it does not exist.

**Proposed direction.** Route scene-phase `.active` through `ARSessionHolder` so that a session suspended while `cameraVisible == true` is resumed, and add an `ARSessionDelegate` for interruption/failure recovery.

## SWE-2 — resumeSession() resets tracking and destroys every placement

**Severity:** high  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:312

**Claim.** Every resume path re-runs the world-tracking configuration with `.resetTracking, .removeExistingAnchors` and then calls `resetPlacements()`, discarding the VIO world map, all placed holders, ground locks, VPS ownership, and the converged heading estimate.

**Evidence.** `resumeSession()` (GeoARSessionManager.swift:312-316) calls `runGPSCompass()`, which unconditionally does `arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])` followed by `resetPlacements()` (lines 536-537). `resetPlacements()` (557-595) clears `placedHolders`, `groundLockBaseY`, `vpsOwnedDrops`, `placementBasis`, `headingCorrectionSin/Cos`, and sets `headingSampleCount = 0`. This is the same function used for the cold start, so a warm resume is indistinguishable from a cold one.

**Failure scenario.** User closes the AR cover for 6 seconds (past `pauseGraceSeconds = 5`), re-opens it. Every drop is re-spawned from a fresh GPS fix with a zeroed heading estimate, so content that was VPS-locked and ground-snapped re-appears at a visibly different position and altitude, then re-glides. `markCameraVisible()` sees `placedHolders.isEmpty` and resets TTFO to nil. This is precisely BRIEF killer #1 ("appear into empty spot") and killer #2 ("the user witnesses placement").

**Industry gap.** ARKit's documented resume idiom is `session.run(configuration)` with no options, which preserves the world map and re-localizes against it; `.resetTracking` is reserved for genuine restarts. ADR-033/034 explicitly claims "anchors, world map, and placed content all survive `session.run(config)`" — `setPerception` honors that, `resumeSession` does not.

**Proposed direction.** Separate cold start (reset) from resume (plain `session.run(config)` with no options and no `resetPlacements()`).

## SWE-3 — Cloud writes silently no-op without auth; magic links can be permanently dead

**Severity:** high  
**File:** `AugmentMeReality/Services/FirebaseDropStore.swift`:36

**Claim.** `FirebaseDropStore.save` returns success without writing anything when there is no Firebase user, and no layer above it ever retries, so a drop created before anonymous sign-in completes (or after it fails) is never uploaded — yet the share sheet still hands the user a link.

**Evidence.** `FirebaseDropStore.save` begins `guard let uid = Auth.auth().currentUser?.uid else { return }` (FirebaseDropStore.swift:36-38) — a silent success return, not a throw. `DropLibrary.add` treats a non-throwing cloud save as success and sets `lastSyncError = nil` (DropStore.swift:108-115). `DropLibrary.update` discards the result entirely: `try? await cloud.save(drop)` with no error capture at all (DropStore.swift:126-131). `ShareDropSheet.sendLink()` then does `await library.update(sharedDrop)` and unconditionally sets `showShareSheet = true` (ShareDropSheet.swift:147-150). `AccountService.start()` signs in on a detached `Task` (AccountService.swift:22-34) and on failure only sets `statusText`, which is surfaced only on ProfileScreen. `DropLibrary.refresh` is read-only — nothing ever pushes unsynced local drops later.

**Failure scenario.** First launch with no/poor network: anonymous sign-in fails. The user creates a drop and taps "Send the magic link"; the share sheet opens and they text the link to a friend. `DropSharingService.fetchSharedDrop` returns nil for the recipient, who sees "This drop isn't available". Nothing in the sender's app ever retries the upload, on this launch or any later one — the link is dead forever, and the sender is never told.

**Industry gap.** Standard practice is an outbox/sync queue: local writes are marked dirty and reconciled on auth/connectivity, and share affordances are gated on a confirmed server write. Failing that, the write must at minimum `throw` (never `return`) so the caller can surface it.

**Proposed direction.** Make the missing-uid path throw, propagate the error to the share CTA, and add a dirty-flag reconciliation pass on `refresh`/auth-ready.

## SWE-4 — SemanticOcclusionPass mutable state is shared between the render thread and the main actor with no synchronization

**Severity:** high  
**File:** `AugmentMeReality/AR/SemanticOcclusionPass.swift`:139

**Claim.** `pipeline`, `device`, `textureCache`, `matteTextures`, `matteIndex`, `inFlightTextures` and the dummy textures are written from RealityKit's render thread (`prepareWithDevice` / `postProcess`) and concurrently written from the main actor (`uninstall`, `setCallbacksActive`) with no lock, queue, or actor isolation.

**Evidence.** `prepare(device:)` writes `self.device`, `self.pipeline`, `self.textureCache`, `dummyUint/Unorm/Float` (SemanticOcclusionPass.swift:161-175) and `encode(context:)` writes `inFlightTextures`, `matteTextures`, `matteIndex` (185-324); both are invoked from `arView.renderCallbacks` (143-152), i.e. the render thread. `uninstall()` — called from `GeoARSessionManager.detach()` on the main actor (GeoARSessionManager.swift:291-292) — sets `pipeline = nil; matteTextures = []` (SemanticOcclusionPass.swift:155-159). `setCallbacksActive(_:)` is called every 400 ms from `updatePowerTier` on the main actor (GeoARSessionManager.swift:882, 885) and mutates `callbacksActive` plus RealityKit's callback slots. The class carries no `@unchecked Sendable`, no lock, and no isolation annotation — unlike its own `SemanticFeed`/`MidFieldDepthFeed`, which are correctly `NSLock`-guarded.

**Failure scenario.** Tearing down or backgrounding the AR view while the GPU pass is mid-encode: the main actor executes `matteTextures = []` between the render thread's `guard matteTextures.count == 2` and `matteTextures[matteIndex]` (lines 246-251), producing an index-out-of-range crash, or `pipeline = nil` between the guard and `encoder.setComputePipelineState(pipeline)`. Intermittent, timing-dependent, and effectively undebuggable from a crash log — exactly the class of bug ADR-045 P0-3 already caught once in this file.

**Industry gap.** Post-process callback objects in shipped RealityKit apps either confine all mutable render state to the render thread (main-actor code posts commands, never mutates), or guard it explicitly. Under Swift 6 strict concurrency this code would not compile.

**Proposed direction.** Confine all render-state mutation to the render callbacks (have `uninstall`/`setCallbacksActive` only flip an atomic flag that the render thread reads and acts on), or wrap the state in a lock-guarded box like `SemanticFeed`.

## SWE-5 — Live-edit target is re-resolved per call; nearest-drop change mid-drag edits the wrong drop and leaks liveEditingDrops

**Severity:** high  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:1372

**Claim.** `adjustNearestDrop` resolves its target from `nearestDrop` at each call rather than from a target captured at drag start, and `liveEditingDrops` is never cleaned up when a drop is removed — so a nearest-drop change mid-drag both edits the wrong object and permanently pins the power governor to the `.full` tier.

**Evidence.** `adjustNearestDrop(...)` starts `guard let current = nearestDrop else { return }; let id = current.id` (GeoARSessionManager.swift:1375-1376). Each slider tick and the release-commit are separate calls (ARScreen.swift:471-484, 489-505, 510-526), and `nearestDrop` is recomputed every 400 ms by `updateNearest()` (GeoARSessionManager.swift:1063-1089) with no exclusion for a drag in progress. `liveEditingDrops.insert(id)` happens on every non-commit tick (1386) and is removed only on commit (1429), in `clearRoomDrops` (418) and in `resetPlacements` (578) — it is *not* removed in either drop-removal loop (1287-1298, 1709-1720). `updatePowerTier` feeds `isLiveEditing: !liveEditingDrops.isEmpty` (832) and `PowerGovernor.evaluate` forces `.full` on that input (PowerGovernor.swift:71-74). A stale id also permanently exempts that drop from GPS re-sync (1217), VPS transforms (604), deferred corrections (670, 693) and perceptual scale (1921).

**Failure scenario.** User walks along a street dragging the height slider on drop A; drop B becomes nearest during the drag. `syncSliders()` fires (`ARScreen.swift:565`) and jumps the slider, the release-commit lands on drop B — moving and persisting a drop the user was not editing — while A's id remains in `liveEditingDrops` forever. From that moment the governor never leaves `.full`: person segmentation, scene depth, LiDAR meshing and neural depth all stay on for the rest of the session, and the device reaches thermal `.serious` well inside BRIEF's 10-minute bar.

**Industry gap.** Direct-manipulation gestures in production apps bind to an object identity captured at gesture start and hold it until gesture end; the edit-in-progress set is cleaned up in the same code path that destroys the object. Here the per-drop state lives in nine parallel dictionaries with three different, incomplete cleanup sites.

**Proposed direction.** Capture the edited drop id in an `editingDropID` at drag start, drive all three sliders and the commit from it, and clear all per-drop state through one removal helper used by every removal site.

## SWE-6 — A failing USDZ decode causes an unbounded decode-retry loop

**Severity:** high  
**File:** `AugmentMeReality/AR/DropEntityFactory.swift`:110

**Claim.** `onAssetLoaded` fires even when the decode failed, and the session manager's handler rebuilds the entity, which calls `requestAsset` again — a self-sustaining infinite retry loop that re-decodes the failing asset as fast as RealityKit can fail it.

**Evidence.** `requestAsset` fires `onAssetLoaded?(name)` unconditionally after `loadingAssets.remove(name)`, regardless of whether `entity` was nil (DropEntityFactory.swift:113-120); `preloadAnimatedAssets` does the same (96-105). The handler `assetTemplateDidLoad(_:)` (GeoARSessionManager.swift:1504-1524) then calls `DropEntityFactory.makeEntity(for:fullBright:)` for every matching placed drop, which routes to `animatedModel` → `guard let template = animatedTemplates[assetName] else { requestAsset(assetName); return loadingPlaceholder(...) }` (DropEntityFactory.swift:191-193). Since the failed name is no longer in `loadingAssets` and still absent from `animatedTemplates`, the guard in `requestAsset` (111) passes and a new decode Task starts, closing the cycle.

**Failure scenario.** One bundled `.usdz` is corrupt, was exported in an unsupported flavor, or fails to decode on a particular OS version. A drop using it is placed; the app then spins forever: a continuous stream of `Entity.loadAsync` attempts on a background queue, the content entity torn down and rebuilt on the main actor on every iteration (visible flicker of the placeholder orb), CPU pegged and the device heating — with no log, no user-visible error, and no way to stop it short of killing the app.

**Industry gap.** Asset caches record failures (negative caching with a bounded retry/backoff) and report them; a load callback that cannot distinguish success from failure is not a usable contract. `decodeTemplate` also drops the Combine `.failure` completion on the floor (66-82), so the underlying error is never even logged.

**Proposed direction.** Change the callback to carry success/failure, negative-cache failed names, and log the `loadAsync` completion error.

## SWE-7 — Four stacked fullScreenCovers on one view; onboarding hand-off and deep links present into a busy presenter

**Severity:** high  
**File:** `AugmentMeReality/App/RootView.swift`:28

**Claim.** RootView attaches three `.fullScreenCover` modifiers plus a `.sheet` to the same view, and two flows mutate two of those bindings in the same update — a presentation pattern SwiftUI does not support, so a cover silently fails to appear.

**Evidence.** `RootView.body` chains `.fullScreenCover(isPresented: $router.showCamera)` (RootView.swift:28), `.fullScreenCover(isPresented: $router.showCreate)` (35), `.fullScreenCover` bound to `router.onboardingPhase == .story` (42), `.sheet(item: $receiveDropID)` (55) and a fourth `.fullScreenCover` bound to `reactionSession.phase == .memory` (63). `OnboardingView.startDemo()` calls `router.beginFireworksDemo()` (OnboardingView.swift:150-153), which sets `onboardingPhase = .fireworksDemo` *and* `showCamera = true` in one synchronous body (AppRouter.swift:44-47) — dismissing cover #3 and presenting cover #1 in the same transaction. `MemoryScreen`'s `onSendOneBack` does the same pair (`router.showCamera = false; router.beginCreate()`, RootView.swift:74-75). `.onOpenURL` only sets `receiveDropID` (50-54) with no check of whether a cover is already up.

**Failure scenario.** Onboarding beat 2 ("Light fireworks on my floor") — the single designed magic moment of first run — dismisses the onboarding cover but the camera cover does not present, leaving the user on the tab bar with `onboardingPhase == .fireworksDemo` and a background `Task` that will call `placeRoomDrop(content: .fireworks)` into a session nobody is looking at. Separately, tapping a magic link while the AR camera cover is open sets `receiveDropID` on a view that is already presenting, so the invitation sheet never appears and the deep link is silently lost.

**Industry gap.** Standard practice is a single presentation modifier driven by an enum destination (`.fullScreenCover(item: $router.destination)`), so transitions between destinations are one state change and SwiftUI serializes them. Chaining independent covers on one view is a well-known source of "Attempt to present … which is already presenting" and dropped presentations.

**Proposed direction.** Collapse camera/create/onboarding/memory into one `Destination` enum with a single `fullScreenCover(item:)`, and queue deep links behind whatever is presented.

## SWE-8 — LocalDropStore read-modify-write races across concurrent Tasks — lost drops

**Severity:** high  
**File:** `AugmentMeReality/Services/DropStore.swift`:44

**Claim.** `LocalDropStore.save`/`delete` load the entire array, mutate it and rewrite the file with no serialization, and `DropLibrary` fires them from independent unstructured `Task`s, so overlapping writes lose data.

**Evidence.** `save` is `var drops = (try? await loadDrops(...)) ?? []; drops.removeAll {...}; drops.append(drop); try persist(drops)` (DropStore.swift:44-49) on a non-isolated `final class` — the `await` suspension means the whole read-modify-write runs on the concurrent cooperative pool, not on the main actor. Callers create concurrent tasks: `GeoARSessionManager.adjustNearestDrop` does `Task { await library.update(edited, persist: persist) }` per commit (GeoARSessionManager.swift:1425), `relocateNearestDrop` does the same (1592), `CreateWizard.place()` does `Task { await library.add(drop) }` (CreateWizard.swift:624-626), `ShareDropSheet.sendLink()` awaits `library.update` (ShareDropSheet.swift:148), and `RootView.onOpenURL`'s receive handler does `Task { await library.update(drop, persist: true) }` (RootView.swift:57). Writes use `.atomic` (DropStore.swift:61) so the file is never torn — but the last writer wins over a stale snapshot.

**Failure scenario.** The user releases the height slider and then the rotation slider within a few hundred ms (two `Task`s), or shares a drop while an AR edit commit is in flight. Both tasks read the same on-disk array; the second write clobbers the first. On the AR path this looks like an edit that "didn't stick"; on the create-then-share path the newly created drop can vanish from `drops.json` entirely and only reappear if the cloud copy exists.

**Industry gap.** A file-backed store is normally an `actor` (or serialized on a private queue) so mutations are serialized by construction; this is the textbook Swift-concurrency migration for exactly this shape.

**Proposed direction.** Make `LocalDropStore` an `actor` (or funnel `persist` through a serial executor) so load-mutate-write is atomic per store instance.

## SWE-10 — Firestore reaction listeners are never removed; stop() is dead code

**Severity:** medium  
**File:** `AugmentMeReality/Services/ReactionService.swift`:61

**Claim.** `ReactionService` registers a Firestore snapshot listener per shared drop and never removes any of them — `stop()` has no callers and there is no `deinit` — so listeners accumulate for the process lifetime.

**Evidence.** Listeners are stored in `listeners[drop.id.uuidString]` and only added, guarded by `where listeners[...] == nil` (ReactionService.swift:61-79). `stop()` (96-99) is the only removal path and a project-wide grep for `ReactionService` shows only the `@StateObject` in `RootView.swift:14` and two `@EnvironmentObject` reads — nothing calls `stop()`, and there is no `deinit`. The registration site is `.task(id: "\(account.uid ?? "-")·\(library.drops.count)")` (RootView.swift:110-112), which re-runs on every change of *drop count*, and each run resets `startedAt = Date()` (ReactionService.swift:53).

**Failure scenario.** Over a session the user shares, deletes and re-syncs drops; the listener set only grows (past the `prefix(10)` intent, since the cap applies per invocation, not to the accumulated map). Each is a live Firestore stream: continuous network traffic, battery and per-read billing for drops the user no longer owns. Also, because `startedAt` is reset every time `library.drops.count` changes, a reaction that lands in the same instant as a library refresh fails the `reaction.at > self.startedAt` test and the sender's toast — the loop's payoff moment — is silently dropped.

**Industry gap.** Snapshot listeners are lifecycle-owned: registered and removed in matched pairs, torn down in `deinit` or on the owning view's disappearance. Reconciling a listener set means removing the ones no longer wanted, not only adding new ones.

**Proposed direction.** Diff the desired drop set against `listeners`, remove registrations that fall out, add a `deinit` that calls `stop()`, and track the session cutoff independently of library refreshes.

## SWE-11 — Power governor drives mid-session ARSession reconfiguration; scene mesh is discarded on every tier drop

**Severity:** medium  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:545

**Claim.** `setPerception` re-runs the ARSession configuration whenever a heuristic flips, and because `sceneReconstruction = .mesh` is only set when `activePerception` is true, dropping to the idle tier discards the reconstructed mesh — so occlusion has a multi-second hole every time the tier cycles.

**Evidence.** `setPerception(active:person:depth:)` calls `arView.session.run(makeConfiguration(...))` on any change (GeoARSessionManager.swift:545-555), driven from `updatePowerTier` on the 400 ms tick (865). `makeConfiguration` places `config.sceneReconstruction = .mesh` inside `if activePerception` (468-474), so `active == false` removes it. The `personUseful` input flips on `personSentinel.personLikely`, which decays after 5 s of no detection (PersonSentinel.swift:21-25), and `windowModeActive` (which needs ~1.2 s to enter and ~2.4 s to leave, GeoARSessionManager.swift:779-787) is folded into the same expression (859-864). Meanwhile `arView.environment.sceneUnderstanding.options` keeps `.occlusion`/`.collision` set from `runGPSCompass` (528-534) regardless.

**Failure scenario.** Someone walks in and out of frame near the user, or Glass Mode toggles at a window: each transition re-runs `session.run(config)`, which on device produces a visible tracking hitch, and re-enabling `.mesh` restarts reconstruction from nothing. For several seconds afterwards the LiDAR occluder set is empty while `sceneUnderstanding.options` still requests occlusion and `occlusionActive` still reports true in the HUD — content draws over real geometry, violating BRIEF's "zero draw-over-known-front-surface frames", and `snapNearestDropToGround`'s LiDAR raycast leg (1478-1486) silently finds nothing.

**Industry gap.** ARKit apps that gate perception keep the expensive-but-stateful outputs (scene reconstruction) stable and toggle only the stateless per-frame semantics, and they apply hysteresis to configuration changes measured in tens of seconds, not the 5 s decay of a presence probe. ADR-033's own claim ("anchors, world map, and placed content all survive `session.run(config)`") is true for anchors but not for the reconstruction mesh.

**Proposed direction.** Keep `sceneReconstruction` on for the whole camera-visible session (or shed it only at thermal `.critical`), apply a long hysteresis to the remaining `frameSemantics` toggles, and drive `occlusionActive`/HUD from what is actually configured.

## SWE-12 — GeoARSessionManager entanglement: three couplings that are actively hiding defects

**Severity:** medium  
**File:** `AugmentMeReality/AR/GeoARSessionManager.swift`:808

**Claim.** The manager's responsibilities are not merely co-located, they are cross-wired: power policy owns occlusion arming, per-drop state lives in nine unsynchronized parallel dictionaries with three incomplete cleanup sites, and mutation side effects create order dependencies between public methods.

**Evidence.** (a) `updatePowerTier()` (808-890) is the sole decider for ARSession perception (`setPerception`, 865), Google's semantic NN (`geospatial.setSemanticsActive`, 875) and the Metal pass attach/detach (879-889) — a battery heuristic silently gates an occlusion-honesty product bar, and `windowModeActive` is folded into the same boolean expressions (859-864). (b) Per-drop state is spread across `placedHolders`, `placedDrops`, `markers`, `contentEntities`, `groundDiscs`, `appliedCompensation`, `groundLockBaseY`, `deferredTargets`, `deferredVPSTransforms`, `liveEditingDrops`, `revealedDrops`, `vpsCorrectionTotals`, `vpsOwnedDrops`, `vpsGlideUntil`; `resetPlacements` (557-595) clears twelve of them but not `revealedDrops`, and the two removal loops (1287-1298, 1709-1720) clear only seven — omitting `liveEditingDrops`, `revealedDrops`, `vpsOwnedDrops`, `vpsGlideUntil` and `vpsCorrectionTotals`. (c) `snapNearestDropToGround` must set `groundLockBaseY` *after* `adjustNearestDrop` because that method clears the lock as a side effect — the code says so in a comment (1498-1499). (d) `frameUpdate()` (1778-1888) mixes fps metrics, GAR feeding, the person sentinel, mid-depth arming, semantic arming, transit positioning, deferred corrections, perceptual scale, marker sizing and the reveal burst behind a single `guard mode == .gpsCompass` (1779) — meaning in `.geoTracking` mode none of it runs at all.

**Failure scenario.** Engineer-observable: fixing a bug in one subsystem requires reading all of them. Concretely, the incomplete removal loops already produce SWE-5's governor pin and leave `vpsCorrectionTotals` reporting a removed drop's drift in the HUD forever; `revealedDrops` grows unbounded and is never cleared, even by a session reset. Any new per-drop feature has to remember three separate cleanup sites or leak.

**Industry gap.** At this size the standard shape is a `Drop` render-state struct in one dictionary (one insert, one remove), with placement, correction, occlusion-arming, power and editing as separate collaborators behind narrow protocols. ADR-045's own register already lists "GeoARSessionManager split (~1500-line god object)" as P2 debt; the file has since grown to 2006 lines and the coupling is now load-bearing for correctness, not just readability.

**Proposed direction.** Extract a `PlacedDrop` value type holding all per-drop state so removal is one operation, then split power/occlusion arming and editing into separate types with explicit inputs.

## SWE-13 — No test coverage on any stateful load-bearing code

**Severity:** medium  
**File:** `AugmentMeRealityTests/PerceptualSizeTests.swift`:1

**Claim.** The eleven test files cover only pure functions and one device smoke test; the 2000-line session manager, GeospatialEngine, the occlusion pass, and the entire app-lifecycle state machine have zero coverage.

**Evidence.** The suite tests `GeoMath` (pure), `GeoHash` (pure), `MotionClassifier` (pure with injected clock), `PowerGovernor` (pure with injected clock), `GeoDrop` codable, `LocalDropStore` single-threaded happy path, `MidFieldDepthEstimator.fitInverseDepth` (a `static` pure function), and `GeoARSessionManager.perceptualFactor` — which is the one thing in the manager deliberately marked `nonisolated static` precisely so it could be tested (GeoARSessionManager.swift:1907). Nothing exercises `applyVPSTransform`, `drainDeferredCorrections`, `updateHeadingCorrection`/`ingestHeadingDelta`, `syncGPSPlacements`, `assetTemplateDidLoad`, `adjustNearestDrop`, `updatePowerTier`'s wiring, `setPerception`, or `ARSessionHolder`'s lifecycle. `DropStoreTests` has no concurrency test despite the store being called from concurrent tasks, and `GeoDropCompatibilityTests` (66 lines) tests only missing keys, never a type mismatch.

**Failure scenario.** Every finding above (SWE-1, -2, -5, -6, -8, -9) sits in code with no test that would go red. The heading estimator, the deferred-correction state machine and the VPS ownership handoff — the logic BRIEF's killers #1 and #2 depend on — are validated only by field testing, which is why ADRs 017/027/028 read as successive field-driven patches rather than fixes with regression pins.

**Industry gap.** Load-bearing state machines are normally extracted behind seams (protocol-wrapped `ARSession`/clock/location) and unit-tested; ADR-047 already established that principle for the asset loader by making measurement the regression gate, but it was applied to exactly one bug class.

**Proposed direction.** Extract the correction/heading/ownership state machines as pure types with injected time and sensor inputs, and pin each field-driven ADR (017, 027, 028, 049) with a test.

## SWE-14 — Persistence and share paths swallow errors with `try?`; failures never reach the user

**Severity:** medium  
**File:** `AugmentMeReality/Services/DropStore.swift`:120

**Claim.** `DropLibrary.add`/`update`/`remove` discard local write errors with `try?`, `update` discards cloud errors too without even setting `lastSyncError`, and the only place `lastSyncError` is rendered is the Sent tab — so a failed write is invisible at the moment it happens.

**Evidence.** `add` (DropStore.swift:104-116) and `remove` (133-139) use `try? await local.save/delete`; `update` uses `try?` for *both* local and cloud (126-131). `lastSyncError` is set only in `refresh` and `add` (96-98, 111-113) and is read only in `DropsListScreen.swift:21`. The in-memory `drops` array is mutated *before* the write (105-107, 121-125), so the UI shows success regardless. `CreateWizard.place()` sets `placedDrop` (opening the share sheet) immediately after `await library.add(drop)` with no error check (CreateWizard.swift:624-626), and `ShareDropSheet.sendLink()` sets `showShareSheet = true` after a `try?`-swallowed update (ShareDropSheet.swift:147-150).

**Failure scenario.** Device storage is full, or the container is unwritable: `data.write(to:options:.atomic)` throws, `try?` eats it, the drop appears in the list and the share sheet opens. On the next launch the drop is gone with no explanation. The user has already sent a link to a friend for content that no longer exists locally and (per SWE-3) may never have existed remotely.

**Industry gap.** Writes that a user has committed to (create, share, delete) are error-surfacing in shipped apps — either a retry affordance or an explicit failure state. `try?` on the persistence path of user-authored content is a code smell that this codebase applies uniformly.

**Proposed direction.** Make `add`/`update`/`remove` return or throw a result, surface failures at the originating CTA (create and share), and keep `lastSyncError` for background sync only.

## SWE-9 — Resilient decoding covers missing keys only; one type mismatch still silently wipes the whole library

**Severity:** medium  
**File:** `AugmentMeReality/Models/GeoDrop.swift`:104

**Claim.** ADR-045's fix uses `decodeIfPresent` for every field, which tolerates absent/null keys but still throws on a type mismatch — and because the array is decoded as a whole with no per-element isolation, one bad field in one drop throws, triggers the quarantine, and empties the user's library with no user-visible signal.

**Evidence.** `init(from:)` is a chain of `try c.decodeIfPresent(...)` (GeoDrop.swift:104-126); `decodeIfPresent` returns nil only for an absent key or JSON null and throws `DecodingError.typeMismatch` otherwise. `LocalDropStore.loadDrops` decodes `[GeoDrop].self` in one call and, on any throw, moves the file to `.corrupt` and returns `[]` (DropStore.swift:32-41) with no error propagated, no log, and no UI signal. The only defence is `GeoDropCompatibilityTests`, whose three cases all exercise *missing* keys (`testDecodesPreSharingEraJSON`, `testDecodesMinimalSkeleton`) or an unknown enum *string* — none exercises a wrong-typed value.

**Failure scenario.** A future client (or a hand-edited/partially-migrated record) writes `"heightAboveGround": "3"` or `"facingDegrees": {}` for a single drop. On the next launch the whole array fails to decode, all of the user's drops disappear from the app, the `.corrupt` file is unreachable and is overwritten by the next quarantine, and the user is told nothing — the exact P0 ADR-045 claims to have closed, reached through a different door. Separately, an unknown content type is coerced to `.text3D` (line 110) and re-encoded as `"text3D"` on the next save, permanently downgrading a newer client's drop.

**Industry gap.** Forward-compatible stores decode elements individually (`[FailableDecodable<T>]`, skipping and logging bad rows), preserve unknown keys/values verbatim for round-trip, and never destroy the only copy of user data without surfacing it. A quarantine is a diagnostic, not a migration.

**Proposed direction.** Decode per element with a failable wrapper, keep the raw JSON for unrecognized content/keys so writes round-trip losslessly, and surface a recoverable "couldn't read N drops" state instead of silently emptying.

---

# Reviewer 4 — Backend, Privacy & Release Readiness

## Overall assessment (verbatim)

The backend is a thin, readable layer with good instincts (absent-tolerant config, resilient GeoDrop decoding after the ADR-045 data-loss P0, a local-first store seam), but it is not close to shippable. The security model is the worst area: the Firestore rules as written in README.md let any anonymous user overwrite and then delete any drop in the database, and let them enumerate every link-shared drop — turning the "secret UUID" share model into a public index of home coordinates plus recipient first names. Second, the service layer is fire-and-forget end to end: every Firestore write uses the non-completing `setData(from:merge:)`, so a rules rejection is invisible and the Profile tab reports "Synced" regardless. Third, the Wave 6.2 loop's payoff is broken in normal use — `RootView` keys the reaction listener on `library.drops.count`, which sharing does not change, so the sender is never listening on the drop they just shared; ADR-040 admits the cross-account path was never field-tested, which is exactly why this survived. Release posture is behind where ADR-045's register claims: no account-deletion path at all against anonymous-only identity (device loss = permanent orphaned PII), no PrivacyInfo.xcprivacy, no rules or indexes in source control, and 122 MB of Assets3D still carrying the Apple dev-license samples with zero license records. The geohash utility is well-tested but entirely unused — `loadDrops(near:radius:)` ignores both of its parameters.

## PBS-1 — Firestore update rule lets any signed-in user hijack and delete any drop

**Severity:** critical  
**File:** `README.md`:104

**Claim.** The documented rules permit `update` on `drops/{id}` based only on the *incoming* document's ownerUid, never on the existing document's ownerUid, so any authenticated user can overwrite any drop, reassign ownership to themselves, and then legally delete it.

**Evidence.** README.md:104-105 `allow create, update: if request.auth != null && request.resource.data.ownerUid == request.auth.uid;` — `create` and `update` share one condition and neither references `resource.data.ownerUid`. The delete rule at README.md:106-107 does check `resource.data.ownerUid == request.auth.uid`, which is precisely what the update rule omits. Doc IDs are the drop UUID (FirebaseDropStore.swift:51 `.document(drop.id.uuidString)`), and every link recipient holds that UUID (DropSharingService.swift:17).

**Failure scenario.** Alice shares `https://augmentmereality.web.app/d/<uuid>` with Bob. Bob (or anyone the link is forwarded to) signs in anonymously — zero friction, no email, no review — and issues `setData` on `drops/<uuid>` with `{ownerUid: <bobUid>}` and `merge: true`. The write is accepted. Bob is now the owner and issues a delete, which the delete rule now permits. Alice's birthday drop vanishes from her library on her next refresh with no error, no audit trail, and no way to recover it. The same request applied to a harvested list of IDs (see PBS-2) wipes the entire drops collection.

**Industry gap.** Standard Firestore practice separates create from update precisely because of this: `allow create: if request.resource.data.ownerUid == request.auth.uid;` and `allow update: if resource.data.ownerUid == request.auth.uid && request.resource.data.ownerUid == resource.data.ownerUid;` — the existing doc gates the write and immutable fields are pinned. Leading teams also keep rules in source control with `@firebase/rules-unit-testing` emulator tests asserting the negative cases (a non-owner update must fail).

**Proposed direction.** Split create from update, gate update on `resource.data.ownerUid == request.auth.uid`, and pin `ownerUid` immutable across updates.

## PBS-2 — Link-visibility drops are enumerable: exact coordinates + recipient names harvestable

**Severity:** critical  
**File:** `README.md`:101

**Claim.** The read rule authorizes a `list` query filtered on `visibility`, so any anonymous user can page the entire `drops` collection and harvest every shared drop's exact WGS84 coordinate, recipient first name, sender name, message, and ownerUid — the share-link secrecy model provides no confidentiality at all.

**Evidence.** README.md:101-103 `allow read: if request.auth != null && (resource.data.ownerUid == request.auth.uid || resource.data.visibility in ['link','public']);`. `allow read` covers `get` *and* `list`. `visibility` is written as a top-level field by FirebaseDropStore.swift:48, so `collection("drops").whereField("visibility", isEqualTo: "link")` returns a result set in which every document satisfies the rule — Firestore's documented "secure by query constraint" pattern — and the query is therefore allowed. There is no `limit` requirement in the rule. The returned payload is the full CloudDrop (FirebaseDropStore.swift:16-21), whose nested `drop` map carries `latitude`/`longitude`/`recipientName`/`createdBy`/`message` (GeoDrop.swift:49-73).

**Failure scenario.** An attacker installs the app, gets an anonymous UID with no verification, and runs one paged query for `visibility == 'link'`. They receive a list of every gift anyone has ever shared: the precise coordinate the sender chose (in the hero use case, the recipient's home or workplace), the recipient's first name from `recipientName`, the sender's chosen display name, and the message text. Repeating the query daily yields a growing address book. The UUID entropy in the share URL (122-bit v4) is irrelevant because nothing requires possession of the URL.

**Industry gap.** Capability-URL products (Google Photos share links, Dropbox links) never make the capability set listable — the resource is readable only by exact ID, enforced with `allow get: ...; allow list: if false;`. Firestore's own guidance is to write `get` and `list` rules separately whenever a resource is meant to be unguessable-but-not-public.

**Proposed direction.** Split `allow get` from `allow list` (deny `list` on drops entirely for non-owners), and move link redemption behind a Cloud Function or a per-link secret token stored separately from the drop's visibility field.

## PBS-3 — Sender never receives reactions for the drop they just shared (loop payoff dead)

**Severity:** critical  
**File:** `AugmentMeReality/App/RootView.swift`:110

**Claim.** The reaction listener is re-established only when `library.drops.count` or the uid changes, but the share action mutates a drop in place without changing the count — so the drop the sender just shared is never subscribed to, and no reaction toast ever arrives for it.

**Evidence.** RootView.swift:110-112 `.task(id: "\(account.uid ?? "-")·\(library.drops.count)") { reactionService.listenToMySharedDrops(library.drops, myUid: account.uid) }`. Creation runs `library.add(drop)` (CreateWizard.swift:625) with `visibility` still `"private"` (GeoDrop.swift:64), so when the task fires on the count bump the drop is filtered out by ReactionService.swift:58 `$0.visibility != "private"`. Sharing then runs `library.update(sharedDrop)` (ShareDropSheet.swift:143,149), and `DropLibrary.update` replaces the element at its existing index (DropStore.swift:120-125) — `drops.count` is unchanged, `account.uid` is unchanged, so the `.task(id:)` value is byte-identical and SwiftUI does not restart it. `listenToMySharedDrops` is the only caller of `addSnapshotListener` on reactions.

**Failure scenario.** Sender composes a drop, taps "Send the magic link", texts it to a friend. The friend walks to the spot, sees the surprise, taps ❤️ — `ReactionService.send` writes the doc successfully and the friend sees "Sent to <sender>". The sender's phone shows nothing, then or ever, because no listener was ever attached to that drop. The toast only starts working after some unrelated action changes the drop count (creating another drop, deleting one, or relaunching), and even then only for reactions arriving after that moment. This is the exact P0 class ADR-045 #2 claims to have fixed, reintroduced through the trigger key instead of the slice direction.

**Industry gap.** Derived subscriptions are keyed on the identity of what is being subscribed to, not on a collection's cardinality — the standard key here is the set of subscribed IDs (e.g. `drops.filter(isShared).map(\.id).sorted().joined()`), or the subscription is driven imperatively from the share action itself. Counting as a change-detection proxy is a known anti-pattern precisely because in-place mutation is invisible to it.

**Proposed direction.** Key the task on the sorted set of shareable drop IDs (or call `listenToMySharedDrops` directly from `ShareDropSheet.sendLink`), and add a cross-account field test to FIELDTESTS.md — ADR-040 records the loop as never having been tested across two accounts.

## PBS-4 — All Firestore writes are fire-and-forget; "Synced" is asserted, never verified

**Severity:** high  
**File:** `AugmentMeReality/Services/FirebaseDropStore.swift`:50

**Claim.** Every write path uses the throwing-encode overload `setData(from:merge:)`, which returns as soon as the mutation is staged locally and never surfaces the server's accept/reject — so a rules rejection, quota failure, or bad schema is completely silent while the UI reports success.

**Evidence.** FirebaseDropStore.swift:50-51 `try Firestore.firestore().collection("drops").document(...).setData(from: record, merge: true)` — the `do`/`catch` chain above it can only catch a Codable encoding error; the write completion handler is not requested. Same shape in ReactionService.swift:38-41 (`catch { log.error("Reaction send failed") }` catches encoding only), AccountService.swift:63-64 and AccountService.swift:81-82 (`catch { statusText = "Couldn't save profile" }` likewise). `DropLibrary.add` sets `lastSyncError = nil` on the strength of that non-await (DropStore.swift:109-113), and ProfileScreen.swift:73-74 then renders "Synced — your drops follow you across devices".

**Failure scenario.** A user follows README steps 1–4 but skips or mistypes step 5 (pasting rules v2). Firestore in production mode denies every write. The app shows "Synced — your drops follow you across devices" in Profile, DropsListScreen shows no `lastSyncError` banner, and the user places twenty drops over a month believing they are backed up. On reinstall, `loadDrops` returns an empty set and the entire library is gone. Identically, a receiver taps ❤️ and gets the "Sent to <sender>" confirmation (ReactionSession.swift / ReactionOverlay.swift:115-126) for a write the server rejected.

**Industry gap.** Production Firestore clients use the completion-handler or `async` overloads and treat the callback as the sync signal; a "Synced" indicator is driven by acknowledged writes (or `snapshot.metadata.hasPendingWrites == false`), never by the absence of a local encoding throw. Firebase's own docs flag that the no-completion overloads resolve on local write only.

**Proposed direction.** Switch to the completion/async overloads, propagate the real error into `DropLibrary.lastSyncError`, and derive the Profile sync chip from acknowledged-write state rather than from `firebaseConfigured`.

## PBS-5 — No account deletion path; anonymous-only identity orphans user data permanently

**Severity:** high  
**File:** `AugmentMeReality/Profile/ProfileScreen.swift`:69

**Claim.** There is no delete-account UI or backend anywhere in the codebase, no `signOut`, and no Sign in with Apple linking — so a user who loses or wipes their device loses access to their cloud drops forever while their location data, recipient names, and profile stay in Firestore with no reachable deletion path.

**Evidence.** A repo-wide grep for `currentUser?.delete`, `deleteAccount`, `signOut`, `ASAuthorization`, and `linkWithCredential` returns zero hits in `AugmentMeReality/`. ProfileScreen.swift:69-92 is the only account surface and offers edit-name/handle only. Identity is anonymous-only (AccountService.swift:28 `signInAnonymously`), and all cloud reads are scoped by that UID (FirebaseDropStore.swift:26-29 `whereField("ownerUid", isEqualTo: uid)`). ADR-045 (DECISIONS.md:709-711) lists "account deletion UI+backend (App Store 5.1.1(v))" as an open submission blocker and it remains open.

**Failure scenario.** A user places 30 drops over two months, then upgrades their phone. The new install signs in anonymously and receives a fresh UID; `loadDrops` returns nothing and the Profile still says "Synced — your drops follow you across devices" (ProfileScreen.swift:74) — a claim the architecture cannot honor. Their old documents (exact coordinates of friends' homes, recipient first names, their display name) remain in Firestore forever, reachable by nobody including them, and unerasable on request. A GDPR Art. 17 request cannot be serviced, and App Review rejects under 5.1.1(v) on first submission.

**Industry gap.** Apps with accounts ship an in-app delete that removes auth user + owned documents (typically a callable Cloud Function or the Firebase `delete-user-data` extension) before submission, and anonymous-first products pair the anonymous UID with an early upgrade prompt (SIWA / email link) so identity survives device loss. Advertising "across devices" on a device-bound anonymous UID is a straightforward misrepresentation.

**Proposed direction.** Ship a delete-account flow (delete owned drops + reaction subcollections + users/{uid}, then `Auth.currentUser.delete()`), and correct the Profile copy to "this device" until credential linking exists.

## PBS-6 — Reactions subcollection: writable to any drop by anyone, unmoderated, never cascade-deleted

**Severity:** high  
**File:** `README.md`:108

**Claim.** The reactions rule authorizes any signed-in user to write arbitrary `emoji`/`byName` strings to any drop's reaction subcollection and to read every reaction on every drop, and `FirebaseDropStore.delete` removes only the parent document — so reaction data (uid + display name + timestamps) survives drop deletion forever with no deletion path.

**Evidence.** README.md:108-112: `allow read: if request.auth != null;` (no ownership or visibility predicate) and `allow create: if request.auth != null && request.resource.data.uid == request.auth.uid;` — no check that the drop is link/public, no field-shape constraint, no rate limit, and no `update`/`delete`, so neither the author nor the drop owner can remove a reaction. FirebaseDropStore.swift:54-57 `.document(drop.id.uuidString).delete()` deletes only the doc; Firestore does not cascade subcollections. The reaction payload is rendered straight to the sender's screen at RootView.swift:87 `Text("\(reaction.byName) reacted")` and RootView.swift:85, with `byName` sourced from a free-text profile field (AccountService.swift:78, ReactionService.swift:35).

**Failure scenario.** Two failures. (a) Abuse: an attacker who harvested drop IDs via PBS-2 sets their profile displayName to an abusive string and writes reactions to hundreds of strangers' drops. Each victim gets an unsolicited toast bearing that text, with no block, no report, and no way to delete the reaction — App Review Guideline 1.2 territory, and there is no moderation surface anywhere in the app. (b) Retention: a sender deletes an embarrassing drop; the reactions subcollection with viewer UIDs, display names, and timestamps stays in Firestore indefinitely, readable by any signed-in user, invisible in the console under an absent parent, and unreachable by any erasure request.

**Industry gap.** UGC reaching another user's device requires reporting/blocking/filtering before shipping (App Store 1.2). Subcollection lifecycle is standardly handled by a Firestore `onDelete` Cloud Function or the `delete-user-data` extension, and reaction rules normally constrain document shape (`request.resource.data.keys().hasOnly([...])`, emoji from an allowlist) and gate on the parent's visibility via `get(/databases/$(db)/documents/drops/$(id)).data.visibility`.

**Proposed direction.** Constrain reaction writes to a fixed emoji set and to drops the caller may read, allow authors and drop owners to delete, add a cascade-delete function, and add block/report before any stranger-reachable reaction ships.

## PBS-7 — Cache-first profile snapshot re-seeds and destroys the user's saved profile

**Severity:** high  
**File:** `AugmentMeReality/Services/AccountService.swift`:42

**Claim.** The profile snapshot listener treats a cache-sourced `exists == false` as "first run" and writes a starter profile, without checking `snapshot.metadata.isFromCache` — so any launch with an empty local cache overwrites the server profile with "New Dropper" and zeroed counters.

**Evidence.** AccountService.swift:42-53: `doc.addSnapshotListener { snapshot, _ in ... if let snapshot, snapshot.exists, let profile = ... { self.profile = profile } else if self.profile == nil { await self.seedProfile(uid: uid) } }`. Firestore delivers a cache event first; with no cached entry that event has `exists == false` and `metadata.isFromCache == true`, which this code cannot distinguish from a genuinely absent document. `seedProfile` (AccountService.swift:56-69) then writes `handle: "guest-\(uid.prefix(6))"`, `displayName: "New Dropper"` and, via the `UserProfile` defaults (UserProfile.swift:11-15), `momentsDelivered: 0` / `reactionsReceived: 0` with `merge: true` — which covers every field in the document.

**Failure scenario.** A user sets their display name to "Adnan" and handle to "@adnan". Weeks later they reinstall the app (or clear storage), and the anonymous UID is restored from the keychain. On launch the listener fires from an empty cache with `exists == false`, `seedProfile` runs, and the queued write lands on the server — their name reverts to "New Dropper", handle to "guest-xxxxxx", and any counters reset. Because the write is fire-and-forget (PBS-4), nothing reports it. The same happens on any cold launch in airplane mode.

**Industry gap.** The canonical guard is `guard !snapshot.metadata.isFromCache else { return }` before treating non-existence as authoritative, or a server-source `getDocument(source: .server)` for the seed decision, or — best — seeding server-side on user creation via an Auth `onCreate` Cloud Function so the client never decides whether a profile exists.

**Proposed direction.** Gate the seed branch on a server-sourced read (or `!metadata.isFromCache`) and move first-run profile creation to a Cloud Function triggered on auth user creation.

## PBS-8 — Recipients can re-share a received drop and trigger cross-owner deletes

**Severity:** high  
**File:** `AugmentMeReality/Drops/DropsListScreen.swift`:26

**Claim.** Received drops land in the same `library.drops` list as owned drops with no role gating, so the "Sent" tab offers Share and swipe-to-delete on someone else's drop — re-sharing forwards the sender's exact coordinates under the recipient's name, and delete issues an unguarded cross-owner Firestore delete whose failure is swallowed.

**Evidence.** DropsListScreen.swift:26-49 iterates all of `library.drops` and attaches both `Share` (`sharingDrop = drop`, line 30/38) and `.onDelete` (line 43-48) with no `receivedViaLink` check — while HomeScreen.swift:53-62 does distinguish the two roles, proving the field is available. `ShareDropSheet` then builds the message with `senderName: account.profile?.displayName` (ShareDropSheet.swift:136), i.e. the *recipient's* name, over a drop that is already `visibility: "link"` and readable by any signed-in user. `DropLibrary.remove` (DropStore.swift:133-139) calls `cloud.delete(drop)` unconditionally, and `FirebaseDropStore.delete` (FirebaseDropStore.swift:54-57) has no ownership guard — the only thing stopping it is the delete rule, and the `try?` at DropStore.swift:137 discards the denial.

**Failure scenario.** Alice sends Bob a birthday drop pinned at Bob's house. Bob opens "Sent", swipes the received drop, taps Share, and forwards the link to a group chat with the message "🎁 Bob left a surprise for you". Every recipient can now fetch Bob's home coordinates, attributed to Bob rather than Alice, with Alice having no visibility and no revoke. Separately, Bob swipes-to-delete his local copy and the app fires a delete against Alice's Firestore document; combined with PBS-1's ownership takeover, that delete succeeds.

**Industry gap.** Role is normally carried in the model and enforced at the UI seam (received items live in a separate section with view-only affordances) *and* at the client store boundary — the same `if let owner = drop.ownerUid, owner != uid { return }` guard that `save` already has (FirebaseDropStore.swift:38) is simply missing from `delete`. Forwardable capability links additionally need sender-controlled revoke.

**Proposed direction.** Filter `receivedViaLink` drops out of the Sent list (or give them a view-only row), mirror the ownership guard into `delete`, and stop swallowing the cloud delete error.

## PBS-10 — Security rules and indexes exist only as a README code block, not in source control

**Severity:** medium  
**File:** `web/firebase.json`:1

**Claim.** The Firestore security rules — the entire authorization boundary — are not a versioned, deployable, testable artifact; they live as a markdown fence in README.md that a human must paste into the console, and `firebase.json` declares only hosting, so `firebase deploy` can never ship them.

**Evidence.** web/firebase.json contains a single `hosting` key with no `firestore` section (`rules`/`indexes`). `find` across the repo returns no `firestore.rules` and no `firestore.indexes.json`. The rules exist only at README.md:92-116, and ADR-040 (DECISIONS.md:833-834) states "**User must paste the new rules — the receive flow fails without them.**" `FirebaseIntegrationTests.swift` exercises only the owner happy path via `FirebaseHealthcheck.run()` — it asserts a round-trip succeeds and never asserts that a non-owner write *fails*, so PBS-1 and PBS-2 are untestable in CI by construction.

**Failure scenario.** The rules in the live project drift from the rules in README with nobody able to tell. If the operator picked "test mode" at database creation (the console's default offer), the effective rules are `allow read, write: if true` until a timestamp expires — every drop and every user profile world-writable — and nothing in the repo, the tests, or the app would report it. Conversely a typo while pasting silently breaks the receive flow, which surfaces to users only as ReceiveScreen's generic "This drop isn't available".

**Industry gap.** Rules and composite indexes are code: they live in the repo, deploy through `firebase deploy --only firestore:rules,firestore:indexes` in CI, and are covered by `@firebase/rules-unit-testing` emulator tests that assert the *denials* (non-owner update denied, cross-user list denied, reaction write to an unreadable drop denied). A security boundary that depends on manual console paste has no integrity guarantee.

**Proposed direction.** Add `firestore.rules` and `firestore.indexes.json` to the repo, wire them into `firebase.json`, and add emulator tests that assert every negative case in PBS-1/PBS-2/PBS-6.

## PBS-11 — loadDrops silently ignores near/radius; the tested geohash layer is entirely unused

**Severity:** medium  
**File:** `AugmentMeReality/Services/FirebaseDropStore.swift`:23

**Claim.** `FirebaseDropStore.loadDrops(near:radius:)` discards both parameters and unconditionally fetches the caller's whole drop collection with no limit and no pagination; `GeoHash.queryBounds` — the geo-query machinery ADR-039 claims shipped — has no production caller.

**Evidence.** FirebaseDropStore.swift:23-33: the signature takes `near`/`radius`, the body uses neither, and issues `.whereField("ownerUid", isEqualTo: uid).getDocuments()` with no `.limit(to:)`. `DropLibrary.refresh` dutifully passes `AppConfig.nearbyQueryRadius` (DropStore.swift:94) into that void. A repo-wide grep for `queryBounds` finds only its definition (GeoHash.swift:81) and its test (GeoHashTests.swift:49) — no call site. FirebaseDropStore.swift:45-47 still writes a precision-9 geohash on every save that nothing ever reads. ADR-039 (DECISIONS.md:855-858) describes "Geo-queries: self-contained GeoHash utility ... GeoFire prefix-range pattern" as delivered.

**Failure scenario.** Two consequences. Cost: a user with 300 drops pays 300 document reads on every launch refresh and every manual pull (DropsListScreen.swift:60, MapScreen.swift:106) to render a list that only ever needs the nearest handful — read amplification that scales linearly with library size and does nothing useful. Capability: there is no code path by which anyone discovers anyone else's drop by location, so Wave 7's public layer has no foundation despite the ADR claiming the geo-query work is done, and a reviewer reading the ADR would budget zero for it. The 9-range fan-out cost of `queryBounds` (up to 9 separate Firestore range queries per map view, GeoHash.swift:93-95) has never been exercised or measured.

**Industry gap.** A protocol method that names its parameters and then ignores them is a lie at the seam; the standard shape is either an honest `loadMyDrops()` signature or an implementation that applies `queryBounds` with `.order(by: "geohash").start(at:).end(at:)` per range plus a `.limit(to:)` and cursor-based pagination. Firestore geo-queries also require a declared composite index, which does not exist here (see PBS-10).

**Proposed direction.** Either narrow the protocol to what the store actually does, or implement the bounded query with limits and cursors, and correct ADR-039's claim about what shipped.

## PBS-12 — 122 MB of Assets3D still ships Apple dev-license samples with no license records

**Severity:** medium  
**File:** `CONTENT-PIPELINE.md`:76

**Claim.** The Apple AR Quick Look samples CONTENT-PIPELINE requires be removed before submission are still bundled, alongside ~122 MB of USDZ that violates the document's own ≤5 MB per-object budget by up to 6×, with no attribution or license record anywhere in the repo.

**Evidence.** `AugmentMeReality/Assets3D/` contains `toy_drummer.usdz` (13.9 MB) and `hummingbird.usdz` (20.8 MB) — named in CONTENT-PIPELINE.md:75-76 ("Replace the Apple sample models (toy_drummer, hummingbird) before submission — they're dev-license only") and README.md:68 ("dev/demo use only, replace before shipping") — plus `Castle.usdz` (31.2 MB), `HeilRanch.usdz` (26.6 MB), `livingroom.usdz` (5.0 MB), `shelter.usdz` (5.8 MB), `Happy_Birthday1.usdz` (9.1 MB), `Space_Station_Scene_HD.usdz` (8.5 MB), `Dragon_Attack_Aftermath.usdz` (3.6 MB), `Game_pirate_adventure_map.usdz` (2.8 MB). Total 122 MB, plus 48 MB of CoreML. CONTENT-PIPELINE.md:11 sets "File size ≤ 5 MB (hero ≤ 10 MB)". `find -iname "*licen*"` returns nothing and a grep for `attribut|credit` across `AugmentMeReality/` returns zero hits, though CONTENT-PIPELINE.md:51 requires "CC-BY needs in-app credits screen". `DropEntityFactory.swift:190-191` loads any bundled asset by name, so all of these are user-reachable, not dev-only.

**Failure scenario.** Submission is blocked or the app is pulled: the Apple sample assets are licensed for development only and are shipped in the binary as selectable user content. The ~170 MB of resources also pushes the download well past the point where users on cellular hit an install prompt, against a BRIEF that treats cold-start and app size as product features. And with no license inventory, nobody can answer "where did Space_Station_Scene_HD come from and may we ship it?" — an unanswerable question at review time.

**Industry gap.** Shipping teams keep an asset manifest (source URL, license, attribution string, date) in the repo, gate it in CI, and enforce per-asset size budgets at build time; dev-only samples live behind a debug configuration or outside the bundle entirely. On-demand resources / asset packs are the standard tool once a catalog exceeds tens of MB.

**Proposed direction.** Delete the Apple samples and any asset without a recorded license, add an ASSETS.md manifest plus a build-time size gate, and move the remaining catalog behind on-demand resources.

## PBS-13 — No privacy manifest, no link revoke or expiry, and false privacy copy on the invite

**Severity:** medium  
**File:** `web/public/index.html`:47

**Claim.** `PrivacyInfo.xcprivacy` is absent as ADR-045 registered, and beyond the register two related gaps exist: a shared link can never be revoked or expired, yet both the invite page and the receive screen tell the user it is a "One-time link".

**Evidence.** `find . -name "*.xcprivacy"` returns nothing; ADR-045 (DECISIONS.md:710) lists "app privacy manifest (PrivacyInfo.xcprivacy, required-reason APIs)" as an open submission blocker, and GeoARSessionManager.swift:112,117 use `UserDefaults` (a declared required-reason API, category CA92.1). web/public/index.html:47 renders "One-time link · your camera stays private · the session ends itself" and ReceiveScreen.swift:97 repeats "One-time link · your camera stays private". Nothing in the codebase enforces single use: `fetchSharedDrop` (DropSharingService.swift:47-57) is an unconditional read with no redemption counter, no TTL field exists on `GeoDrop` (GeoDrop.swift:45-77), and there is no path to set `visibility` back to `"private"` — `ShareDropSheet` only ever sets it to `"link"` (ShareDropSheet.swift:143). `ITSAppUsesNonExemptEncryption` is also absent from Config/Info.plist and the pbxproj INFOPLIST_KEYs.

**Failure scenario.** The build is rejected at upload for the missing privacy manifest, and every TestFlight/App Store upload additionally stalls on the export-compliance prompt. Substantively worse: a sender who realizes they pinned a drop at their friend's home address and shared it too widely has no revoke — the only available action is deleting the drop, which destroys the gift. Meanwhile both surfaces have told them the link was one-time, so they reasonably believe it already expired. That is a materially false privacy representation in shipped UI, and it is repeated on a public web page.

**Industry gap.** Apple has required `PrivacyInfo.xcprivacy` with required-reason API declarations for App Store submission since May 2024. Capability links in shipping products carry a redemption/TTL model and a revoke control, and privacy copy is written to match what the system actually enforces — claiming single-use for a permanently valid URL is the kind of statement that draws regulatory attention independent of App Review.

**Proposed direction.** Add the privacy manifest and `ITSAppUsesNonExemptEncryption`, implement link revoke (set visibility back to private) plus an optional expiry, and remove or correct the "One-time link" copy in both places until the behavior matches.

## PBS-14 — Invite page is a hard dead end for non-installers; profile counters are permanently zero

**Severity:** medium  
**File:** `web/public/index.html`:63

**Claim.** The receive path has no universal link and no App Store fallback: the invite page's only CTA fires a custom scheme that errors out in Safari when the app is absent, and the sender-side reward for a successful loop — the profile's trophy counters — is never written by any code and therefore reads 0 forever.

**Evidence.** web/public/index.html:63-66 sets the CTA href to `"augmentme://drop/" + id` with no store fallback and no `encodeURIComponent`; the only alternative offered is web/public/index.html:44 "Ask the sender for a TestFlight invite — the App Store link is coming." There is no `.well-known/apple-app-site-association` under `web/public/`, and web/firebase.json declares no rewrite for one, so `https://augmentmereality.web.app/d/<uuid>` cannot open the app directly even though DropSharingService.swift:37-41 already parses that form. Separately, `momentsDelivered` and `reactionsReceived` (UserProfile.swift:14-15) are read at ProfileScreen.swift:55,60 and written by nothing — a repo-wide grep finds no increment, and ADR-039 (DECISIONS.md:851) defers them to Cloud Functions that do not exist.

**Failure scenario.** The intended growth loop is: recipient taps link → sees the wow → installs. Actual behavior for a recipient without the app: the page loads, they tap the single gold "Reveal in AR" button, and Safari shows "Safari cannot open the page because the address is invalid." There is no store link, no AR Quick Look preview (ADR-038's headline researched call, DECISIONS.md:867-869), and no way forward — the invite converts at zero. Meanwhile the sender who did complete a loop opens Profile and sees "Moments delivered 0 / Reactions received 0", which reads as a broken app rather than a trophy shelf.

**Industry gap.** Deep-link landing pages detect installation via a timed fallback (or use Universal Links with an AASA file plus a store redirect) so a non-installer lands on the App Store rather than an error dialog; App Clips or an AR Quick Look USDZ preview is the standard way to deliver the payload before the install wall. Denormalized counters are maintained by a server-side trigger from day one, not displayed as zeros against a TODO.

**Proposed direction.** Add an AASA file and store-redirect fallback on the invite page (and the AR Quick Look preview ADR-038 specified), and either drive the counters from a Firestore trigger or hide them until they are real.

## PBS-9 — Reaction listeners are never removed and grow without bound; startedAt reset drops reactions

**Severity:** medium  
**File:** `AugmentMeReality/Services/ReactionService.swift`:51

**Claim.** `ReactionService.stop()` is never called anywhere, listeners are added but never pruned when a drop leaves the top-10 window or is deleted, and `startedAt` is reset on every invocation — so listener count and Firestore read cost grow monotonically for the app's lifetime while in-flight reactions are silently discarded.

**Evidence.** ReactionService.swift:96-99 defines `stop()`; a repo-wide grep finds no caller. ReactionService.swift:56-61 computes `mine = drops.filter{...}.prefix(10)` and adds a listener `for drop in mine where listeners[drop.id.uuidString] == nil` — nothing ever calls `.remove()` on a registration for a drop that has fallen out of the window, been unshared, or been deleted. ReactionService.swift:53 sets `startedAt = Date()` at the top of every call, and the delivery filter at ReactionService.swift:73 is `reaction.at > self.startedAt`. The only caller re-invokes on every drop-count change (RootView.swift:110).

**Failure scenario.** A prolific sender with 40 shared drops relaunches; as the library loads and the count changes, successive invocations register listeners for whichever 10 drops happen to be at the head of the list at each moment, and none are ever released — the app ends up holding dozens of live Firestore snapshot listeners, contradicting ADR-040's stated "sender listens on up to 10 of their link-drops" and its cost model. Meanwhile, a reaction that arrives in the same second the user creates a new drop is filtered out by the freshly reset `startedAt` and is never shown — and because there is no sender-side reaction inbox anywhere in the app, it is unrecoverable.

**Industry gap.** Snapshot listeners are lifecycle-bound resources: standard practice is to diff the desired subscription set against the active set each tick (add new, remove stale), tear everything down on background/scene-inactive, and drive "new since last seen" from a persisted watermark rather than an in-memory timestamp that resets on every re-subscribe.

**Proposed direction.** Reconcile the listener dictionary against the current top-10 set (removing stale registrations), call `stop()` on background, and persist a last-seen watermark instead of resetting `startedAt`.

---

# Reviewer 5 — Industry Researcher

## Overall assessment (verbatim)

Against current documented practice, this project sits in an unusual place: the hard parts are unusually right and the ordinary parts are unusually wrong. I verified the load-bearing mathematics independently — the ENU↔AR convention, the EUS yaw extraction, the circular EMA, the projection-matrix depth decode — and the reviewers are correct that these are sound. The one geodesy claim I could settle numerically settles against the code: `metersPerDegreeLatitude = 111_319.49` is exactly 2πa/360, the meters per degree of *longitude* at the equator; the true meridional value is 110 574.28 m at the equator, so the north axis is over-scaled by 0.674% at low latitudes (13 m at the declared 2 km radius) decaying to 0.055% at 51.5°N — a bug that passes every test run in northern Europe and worsens toward the tropics, and which the test suite structurally cannot see because it round-trips through GeoMath's own inverse. Nearly every platform-behavior claim also survives contact with primary sources: Apple documents `trueHeading` as negative until a location fix exists (making the magnetic substitution a cold-start declination injection of 13–15° in major US cities), documents `resetTracking` as a restart rather than the resume idiom, documents `ARCamera.projectionMatrix` defaults of zNear 0.001 / zFar 1000 (so the top half of a 2 km visibility radius is outside the frustum), documents `confidenceMap` as a filter to apply before quantitative use of depth, and warns explicitly about camera-pool exhaustion when pixel buffers are held. The depth-estimation literature confirms the most severe math finding: affine-invariant inverse depth is valid only across the interval the reference samples spanned, so fitting on 0.4–4 m of LiDAR and evaluating out to 60 m is extrapolation with an unconstrained saturation ceiling. I found only two places where a reviewer overreached, and both matter: ARCore's iOS SDK has been \"robust to tracking resets\" since 1.38, so the GARSession does not need recreating across an ARKit reset (the app-level state desync is still real); and the fix proposed for camera-buffer pressure — retaining the ARFrame — is backwards, since retaining frames is the documented cause of the drops, not the cure. The security and compliance findings are the most serious and the least ambiguous: Firebase's own \"rules are not filters\" documentation confirms that a `list` query constrained on `visibility` is an *allowed* full-collection page, turning the secret-UUID share model into a public index of coordinates and recipient names, and the update rule's omission of `resource.data.ownerUid` is the exact anti-pattern Firebase's rules-structure guide warns against. Combined with no in-app account deletion (5.1.1(v), enforced since 2022), no privacy manifest (required since May 2024, and the app uses a required-reason API), no UGC reporting or blocking (1.2), and shipped copy claiming \"One-time link\" for a permanently valid URL, the app is not submittable in its current state regardless of how good the occlusion gets. My prioritization for this team: fix the Firestore rules and ship them from source control with denial tests first; fix the two dead-occluder bugs (Vision orientation, non-LiDAR capability branch) second, since they are small and the person occluder is currently off for most users; fix the session-resume path third, since a frozen viewfinder reads as a hang; then bound the depth alignment to its support and correct the heading substitution. The architectural theme underneath most of the rest — derived state written inside the branch its own precondition guards, and per-drop state spread across fourteen dictionaries with three incomplete cleanup sites — is what will cause these fixes to regress if it is not addressed, and the team has already demonstrated the right pattern once in `PowerGovernor`.

## Theme 1: People-occlusion capability branching and Vision orientation (the occluder is off on most devices)

**Verdict:** confirms  
**Covers findings:** ARP-1, ARP-2  
**Effort:** small

**Industry-standard practice.** Apple's documented model is that `.personSegmentation` yields only a stencil (`ARFrame.segmentationBuffer`), while `.personSegmentationWithDepth` additionally yields `estimatedDepthData` and is the semantic that drives RealityKit/ARKit built-in People Occlusion. Both are A12+ features and neither requires LiDAR; `.sceneDepth` is the LiDAR-only semantic. Apple's guidance (Explore ARKit 4, WWDC20-10611) is explicit that an app requesting `.personSegmentationWithDepth` automatically also receives `sceneDepth` on devices that support it, i.e. depth availability is the branch point, not an assumption. Separately, Vision is documented as orientation-sensitive: `VNImageRequestHandler(cvPixelBuffer:)` without an orientation argument defaults to `.up`, and `ARFrame.capturedImage` is delivered in landscape sensor orientation, so a portrait-locked rear-camera app must pass `.right`. Every Apple Vision-on-ARKit sample and the recurring Apple Developer Forums answers on this point construct the handler with an explicit `CGImagePropertyOrientation` derived from the interface orientation.

**Named examples.** Apple ARKit sample code ("Effecting People Occlusion in Custom Renderers", WWDC20 Explore ARKit 4); Niantic Lightship ARDK, which branches occlusion mode on available depth source and falls back to its own network depth on non-LiDAR hardware; Snap's Lens Studio segmentation textures, which are consumed in display orientation rather than sensor orientation.

**Recommended approach.** Two independent fixes, both small. (1) Gate `wantsPersonOcclusion` (and the `personOcclusionEnabled` flag on the Metal pass) on `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`, and make the `.personSegmentationWithDepth` branch reachable whenever the custom path's depth prerequisite is unmet so RealityKit's built-in occlusion carries non-LiDAR devices. Do not request `.personSegmentation` on a device that can never composite it — that is pure thermal cost. (2) Pass `orientation: .right` (or map from `UIInterfaceOrientation`) into `VNImageRequestHandler` in `PersonSentinel`, and add a fixture test that runs the sentinel over a stored portrait ARKit frame containing a person and asserts `personLikely` becomes true. This second bug is the single most common Vision-on-ARKit integration defect and would not surface in any test that does not use a real capture buffer.

**Sources.**
- https://developer.apple.com/videos/play/wwdc2020/10611/
- https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/personsegmentationwithdepth
- https://developer.apple.com/documentation/arkit/arframe/segmentationbuffer
- https://developer.apple.com/documentation/vision/vnimagerequesthandler
- https://developer.apple.com/forums/thread/785200
- https://www.nianticspatial.com/docs/nsdk/how-to/ar/setup_real_world_occlusion/

---

## Theme 2: ARSession lifecycle: no session delegate, no resume path, and a hard tracking reset on every resume

**Verdict:** partially-confirms  
**Covers findings:** ARP-4, ARP-5, SWE-1, SWE-2  
**Effort:** medium

**Industry-standard practice.** Apple documents `resetTracking` as "an option to reset the device's position from the session's previous run" — i.e. a deliberate restart, not the resume idiom. The documented resume path is to call `run(_:)` again with the same configuration and no options, and to return `true` from `ARSessionObserver.sessionShouldAttemptRelocalization(_:)` so ARKit "attempts to reconcile its knowledge of the user's environment from before the interruption with current camera and sensor data". Apple's own session-lifecycle article and every ARKit sample implement `sessionWasInterrupted`, `sessionInterruptionEnded`, `session(_:didFailWithError:)` and `session(_:cameraDidChangeTrackingState:)`; error surfacing and interruption recovery are stated app responsibilities, not framework behaviour. The one sub-claim that does NOT hold up: ARP-4 asserts ARCore's iOS guidance requires recreating the GARSession across an ARKit tracking reset. The ARCore iOS 1.38.0 release notes (2023-06-21) state plainly "ARCore is now robust to tracking resets", and the current GARSession docs only require that every ARFrame be fed to `update(_:)`. So the GARSession does not need tearing down — but the app-level bug is real anyway, because `resetPlacements()` clears local placement state while `GeospatialEngine.requestedDrops`/`resolvedDrops` survive, so anchors are never re-requested and stale corrections are applied against a moved world origin.

**Named examples.** Apple ARKit samples ("Managing Session Life Cycle and Tracking Quality", "Saving and Loading World Data"); Google's ARCore iOS Geospatial sample app, which keeps one GARSession alive for the ARSession's lifetime and feeds every frame; IKEA Place and Adobe Aero both relocalize rather than reset on foreground.

**Recommended approach.** Split cold start from resume: `resumeSession()` should call `arView.session.run(currentConfiguration)` with no options and no `resetPlacements()`. Adopt `ARSessionDelegate` on `GeoARSessionManager`, implement all four observer callbacks, return `true` from `sessionShouldAttemptRelocalization`, surface `didFailWithError` to the HUD, and gate placement on `frame.camera.trackingState == .normal` so `basisCameraPosition` is never captured during `.limited(.initializing)`. Route `scenePhase == .active` through `ARSessionHolder` so a session suspended while `cameraVisible == true` is actually resumed — today nothing calls `startIfNeeded()`/`resumeSession()` on foreground, which is the frozen-viewfinder bug. Keep the GARSession alive across the reset but call `invalidateAnchor`/clear `requestedDrops` so anchors are re-requested in the new frame. Medium effort, and it is the highest-value single change in the AR layer: it removes both a hang and a re-placement flash that directly violate the project's own killer #1.

**Sources.**
- https://developer.apple.com/documentation/arkit/arsession/runoptions/2875727-resettracking
- https://developer.apple.com/documentation/arkit/arsessionobserver/sessionshouldattemptrelocalization(_:)
- https://developer.apple.com/documentation/arkit/arsessionobserver
- https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality
- https://cocoapods.org/pods/ARCore/changelog
- https://developers.google.com/ar/reference/ios/interface_g_a_r_session

---

## Theme 3: Metric alignment of a relative-depth network: extrapolation outside data support, non-robust fitting, unconstrained sign

**Verdict:** confirms  
**Covers findings:** MATH-1, MATH-7, MATH-8  
**Effort:** medium

**Industry-standard practice.** MiDaS-lineage models (including Depth Anything V2, which predicts disparity) produce *affine-invariant inverse depth*: the literature describes it as "a universal representation in which each value represents a linear interpolation between the scene's near and far planes", meaning the scale/shift pair is valid only over the depth interval the reference samples actually covered. The standard evaluation and deployment protocol is least-squares alignment over pixels with valid ground-truth depth spanning the range of interest, and BenchDepth and the MDEC challenge papers both note that least-squares fitting in disparity space treats far estimates very differently from near ones — far depth is barely constrained by near samples, which is precisely the 1/b saturation the reviewer identifies. Where the reference is sparse and noisy (LiDAR, SfM points), the documented practice is RANSAC or trimmed/Huber regression rather than OLS, because a two-parameter fit has unbounded sensitivity to a single bad correspondence. On the input side, Apple documents `ARDepthData.confidenceMap` explicitly for this purpose: "challenging surfaces, such as those which are highly reflective or those with high absorption, can lower the accuracy of the depth" and the per-pixel `ARConfidenceLevel` exists so apps "filter depth based on the requirements of your application" — the WWDC20 sample filters to `.high` before quantitative use. Nothing in the literature validates an alignment on in-sample R² alone, and no published pipeline accepts a negative slope on a disparity→inverse-depth fit, because the model's polarity is a fixed property that should be pinned by a fixture.

**Named examples.** Intel ISL MiDaS / Ranftl et al. affine-invariant protocol; Depth Anything V2 (disparity output, evaluated in disparity space); ZoeDepth and Metric3Dv2 metric heads; SfM-guided monocular depth (CVPR'25) which uses RANSAC linear regression for scale/shift against sparse points; Apple's WWDC20 "Explore ARKit 4" LiDAR sample, which filters on `.high` confidence; Niantic Lightship, which publishes an explicit max occlusion distance rather than extrapolating.

**Recommended approach.** Four changes, all in `MidFieldDepthEstimator.fitInverseDepth` plus the shader clamp. (1) Filter LiDAR samples to `confidenceMap == .high` before accumulating. (2) Replace OLS with RANSAC or a Huber/trimmed estimator and gate acceptance on the robust residual scale, not in-sample R². (3) Change `abs(a) > 1e-9` to `a > 1e-6` and add a fixture asserting the bundled CoreML model's near pixel exceeds its far pixel (this pins the disparity-vs-depth convention of the third-party conversion). (4) Most important: clamp the emitted metric range to the inverse-depth interval the accepted samples actually spanned, plus a small margin, and treat everything outside it as unknown rather than as a surface — publish `1/b` with its standard error and disarm the mid-field occluder when the content distance falls outside the supported band. Add the regression test the reviewer proposes: a fit whose samples cover only 0.4–4 m must matte nothing at 50 m.

**Sources.**
- https://ar5iv.labs.arxiv.org/html/2307.14460
- https://arxiv.org/html/2507.15321v1
- https://arxiv.org/html/2503.14483v1
- https://developer.apple.com/documentation/arkit/ardepthdata/confidencemap
- https://developer.apple.com/documentation/arkit/arconfidencelevel
- https://developer.apple.com/videos/play/wwdc2020/10611/

---

## Theme 4: Depth-buffer conventions, content-presence epsilon, and the far clipping plane at kilometre range

**Verdict:** confirms  
**Covers findings:** MATH-2  
**Effort:** small

**Industry-standard practice.** ARKit's `ARCamera.projectionMatrix` is documented as equivalent to `projectionMatrix(for:viewportSize:zNear:zFar:)` with default `zNear = 0.001` and `zFar = 1000` metres; content beyond 1 km is outside the frustum unless the app supplies its own projection. An app declaring a 2 km visibility radius therefore has a documented, not speculative, hole in the top half of its own range. On the encoding side, the graphics literature is unambiguous that a validity threshold should never be expressed as a bare epsilon in nonlinear NDC: depth precision is distributed as 1/z, so a fixed NDC epsilon corresponds to a wildly different metric distance depending on near/far and on whether the pipeline is forward-Z or reverse-Z. The current recommendation for large-world rendering is reverse-Z with a float depth buffer (near→1, far→0), optionally with an infinite far plane, which Metal supports natively; Reed and the NVIDIA depth-precision analyses show this makes finite-vs-infinite far plane practically irrelevant for precision up to ~1 km. A pass should determine its clear convention once at setup rather than writing a presence test that is deliberately ambiguous between conventions and therefore rejects real content at both ends.

**Named examples.** Apple ARKit `ARCamera.projectionMatrix` defaults; Unity AR Foundation, which exposes `Camera.farClipPlane` and requires apps rendering geo-anchored content at km scale to raise it; Google's ARCore Geospatial samples, which set a far plane matched to the content radius; Niantic Lightship, which documents an explicit occlusion max-distance rather than relying on buffer semantics.

**Recommended approach.** Small-to-medium. Set the render camera's far plane explicitly from `AppConfig.arVisibilityRadius` (or adopt a reverse-Z infinite-far projection) so 500 m–2 km drops are actually inside the frustum; today FT-15's own range has nothing to evaluate above 1 km. Then linearize before testing: decode `contentDistance` in metres first and gate on `contentDistance > 0 && contentDistance < farPlane`, replacing `hasContent = depth > 1e-6 && depth < 1 - 1e-6`. Record the clear value and convention once at pass setup and assert it in a unit test over a synthetic depth texture. Without this, all three occluders are silently skipped for far content and FT-16 cannot pass for the far half of its stated range.

**Sources.**
- https://developer.apple.com/documentation/arkit/arcamera/projectionmatrix
- https://developer.apple.com/documentation/arkit/arcamera/2923539-projectionmatrixfororientation
- https://www.reedbeta.com/blog/depth-precision-visualized/
- https://developer.nvidia.com/blog/visualizing-depth-precision/
- https://www.realtech-vr.com/understanding-perspective-projection-variants-0%E2%86%921-1%E2%86%920-reversed-z-and-infinite-depth-why-modern-engines-should-care/

---

## Theme 5: Magnetic heading silently substituted for true heading with no declination model

**Verdict:** confirms  
**Covers findings:** MATH-3  
**Effort:** small

**Industry-standard practice.** Apple's `CLHeading.trueHeading` documentation states directly: "A negative value indicates that the heading could not be determined" and "This property contains a valid value only if location updates are also enabled for the corresponding location manager object. Because the position of true north is different from the position of magnetic north on the Earth's surface, Core Location needs the current location of the device to compute the value of this property." That is exactly the cold-start window in which this app seeds its ENU→AR rotation from one compass sample. Substituting `magneticHeading` under the name `trueHeading` therefore injects the local magnetic declination into the world alignment. NOAA/BGS WMM2025 gives declination of roughly +14.9° in Seattle and about −12.5° in New York — a 27° spread across one country. `CLHeading.headingAccuracy` describes magnetometer uncertainty only and carries no declination information, so the app's reliability gate is blind to this error by construction. Standard practice in location-AR is to treat magnetic and true heading as distinct quantities: either refuse magnetic-only samples for world alignment, or correct them with a WMM/IGRF declination model, and propagate a "magnetic-only" flag into both the estimator's noise model and the UI.

**Named examples.** NOAA NCEI / BGS World Magnetic Model 2025 (the reference model shipped in aviation and marine navigation); Google Maps Live View and ARCore Geospatial, which use VPS optical heading and treat compass heading as a low-confidence prior; Apple Maps AR walking directions, which requires a location fix before aligning.

**Recommended approach.** Small. Publish heading as a value type carrying `degrees`, `accuracy`, and an explicit `isTrueNorth` flag; never coerce magnetic into the true-north slot. Refuse magnetic-only samples for the ENU→AR correction (or apply a declination model — a compact WMM2025 coefficient table is a few hundred lines and evaluates in microseconds), and force a re-sync the moment the first true-north sample arrives. Also fix the coupled defect: because `headingConverged` widens the re-sync threshold to 15°, a sub-15° declination error becomes permanently uncorrectable in areas where VPS never localizes — the convergence threshold should not be able to lock in an uncorrected bias.

**Sources.**
- https://developer.apple.com/documentation/corelocation/clheading/trueheading
- https://developer.apple.com/documentation/corelocation/clheading/headingaccuracy
- https://www.ncei.noaa.gov/products/world-magnetic-model
- https://www.ncei.noaa.gov/news/world-magnetic-model-2025-released

---

## Theme 6: Transit geo-pose: open-loop dead reckoning with a hard reset at every GNSS fix

**Verdict:** confirms  
**Covers findings:** MATH-4  
**Effort:** medium

**Industry-standard practice.** Vehicle-grade positioning is universally a filtered estimate, not a memoryless extrapolation from the latest fix. The standard architecture is a loosely-coupled INS/GNSS Kalman or invariant-EKF that carries position and velocity state, treats each GNSS fix as an innovation weighted by its reported covariance (with innovation consistency checks to reject outliers), and lets the propagated covariance — not a hardcoded time cap — decide when the estimate stops being trustworthy. The published literature on GNSS outages (tunnels, urban canyons) reports that smoothing and INS propagation reduce position uncertainty by up to ~95% over outages of up to 180 s versus open-loop extrapolation. Recomputing content position from `latestFix + course × speed × min(elapsed, 8)` on every render frame means each ~1 Hz fix (5–15 m independent horizontal error) injects a full position step; the reviewer's arithmetic — an 8 m step at 200 m being ~2.3° of bearing, once per second — is straightforward and correct. Freezing at an 8 s cap while the camera keeps moving converts the drop into a camera-locked sticker, because the rendered position is `camPos + constant offset`.

**Named examples.** Loosely-coupled INS/GNSS invariant-EKF for autonomous vehicle positioning (Sensors/PMC 2023); commercial INS/GNSS units (Inertial Labs, VectorNav) which publish exactly this degradation model; Google Maps Live View, which fuses VPS, GNSS and IMU and hides content when the fused covariance exceeds a threshold rather than at a fixed timeout.

**Recommended approach.** Medium. Introduce a small constant-velocity (or constant-acceleration) filter with a position+velocity state fed by `CLLocation.coordinate/course/speed`, using `horizontalAccuracy`/`speedAccuracy` as measurement noise and gating innovations on a chi-square test. Render from the filter estimate so fix arrivals slew over a time constant rather than teleporting, and drive both the degradation UI and the decision to stop rendering from the growing covariance rather than a magic 8 s. Feeding Core Motion device-motion (or even just the ARKit VIO delta, which is a genuine velocity source at vehicle speeds through a window) as the propagation input is a meaningful upgrade over course×speed and is cheap on iOS.

**Sources.**
- https://pmc.ncbi.nlm.nih.gov/articles/PMC10346868/
- https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10383582/
- https://inertiallabs.com/3-ways-to-maintain-autonomous-navigation-during-gnss-blackouts/
- https://developer.apple.com/documentation/corelocation/cllocation/horizontalaccuracy

---

## Theme 7: No terrain elevation model: remote content's ground height derived from the local viewer, and a camera-local ground lock that vetoes VPS

**Verdict:** confirms  
**Covers findings:** MATH-5, ARP-10  
**Effort:** medium

**Industry-standard practice.** ARCore's Geospatial API exists precisely because remote ground height is not derivable locally. It defines three anchor types: WGS84 anchors (altitude above the WGS84 ellipsoid — Google documents explicitly that "ground level is not at zero"), Terrain anchors (altitude relative to the ground, with the terrain height resolved server-side from Google Maps elevation data), and Rooftop anchors (relative to building height, falling back to terrain when no building exists). The documented contract is that you supply lat/lon and a height above ground, and the service resolves the absolute elevation; you then persist that resolution with the anchor. Deriving a remote drop's world Y from `camPos.y − 1.5` assumes viewer and drop share a ground plane, which is defensible over tens of metres and indefensible over the 2 km radius this app declares — at 1 km, a 60 m elevation difference is 3.4° of vertical error, an order of magnitude larger than the Earth-curvature term (0.31 m at 2 km) that ADR-015 does account for. The related ARP-10 defect inverts the accuracy ordering: a fallback ground estimate measured under the *camera* (from plane anchors in a `camY − 4 … camY − 0.5` band) is promoted to authoritative and then unconditionally overwrites Google's terrain-resolved altitude for the rest of the session.

**Named examples.** ARCore Geospatial Terrain and Rooftop anchors (iOS/Android/Unity); Google Maps Live View, which places all signage against server-resolved terrain; Niantic Lightship VPS, which stores mesh-derived ground elevation with each wayspot; USGS 3DEP / Mapbox Terrain-RGB as the standard DEM fallbacks.

**Recommended approach.** Medium. Add an `altitude` (and `altitudeSource`) field to `GeoDrop`; persist the terrain/rooftop altitude the moment ARCore first resolves it, and use stored-drop-altitude minus resolved-viewer-altitude for the transit vertical instead of `camPos.y − 1.5`. Where no VPS resolution has ever occurred, fall back to a DEM lookup at creation time rather than to the viewer's floor. For the ground lock: only write `groundLockBaseY` when a plane or mesh raycast actually hit near the drop's own XZ, record the hit type and distance, and let a VPS terrain anchor win whenever the lock came from the camera-relative fallback. Also correct the seated-passenger eye height assumption (the fixed 1.5 m) since transit is the only mode where the user is seated.

**Sources.**
- https://developers.google.com/ar/develop/ios/geospatial/anchors
- https://developers.google.com/ar/develop/java/geospatial/anchors
- https://developers.google.com/ar/reference/ios/category/GARSession(Geospatial)
- https://developers.google.com/ar/develop/geospatial/terrain-anchors

---

## Theme 8: Tangent-plane geodesy: wrong meters-per-degree constant, and a test suite that cannot detect it

**Verdict:** confirms  
**Covers findings:** MATH-6, MATH-11  
**Effort:** small

**Industry-standard practice.** I verified the arithmetic rather than taking the finding on trust. 2πa/360 for WGS84 (a = 6 378 137 m) is 111 319.4908 m — that is the meters per degree of *longitude at the equator*, exactly the constant in `GeoMath.metersPerDegreeLatitude`. The correct meridional value M(φ)·π/180 is 110 574.28 m at the equator, 110 772.89 at 25°, 111 131.78 at 45°, 111 257.83 at 51.5°. Using 111 319.49 for the north axis therefore over-scales by 0.674% at the equator, 0.493% at 25°, and 0.055% at 51.5°N — the error is largest in the tropics and nearly vanishes in northern Europe, so it will pass any test run in London and degrade progressively toward the equator. Meanwhile the east axis (`111319.49 · cos φ`) is exact at the equator and under-estimates the true prime-vertical value by 0.168% at 45° and 0.205% at 51.5°, so the two axes are anisotropic and bearings are rotated. At the declared 2 km radius the north error reaches ~13 m at low latitudes — larger than the VPS accuracy the whole Tier-C stack exists to deliver, and it is written back into shared coordinates by ADR-041's inverse-ENU. On testing: the geodesy suite constructs its expected values by calling GeoMath's own inverse, so the constant cancels identically and the assertions hold for *any* value of it. That is a convention test, not an accuracy test. The standard is to validate against an independent reference — GeographicLib/Karney's published test set (500 000 WGS84 geodesics), or on iOS simply `CLLocation.distance(from:)`, which is already in the test target and already used by `DropLibrary.drops(near:within:)`.

**Named examples.** GeographicLib (Karney 2013, J. Geodesy 87:43–55) — the reference implementation and test vectors; Apple `CLLocation.distance(from:)`, a WGS84 geodesic available free in the test target; PROJ / GeographicLib LocalCartesian for ENU; Google S2 and H3, both of which document their spherical-approximation error budgets explicitly.

**Recommended approach.** Small. Replace the single scalar with latitude-dependent meridional and prime-vertical radii of curvature evaluated at the tangent-plane origin (M(φ) and N(φ) are five lines each), or route the conversion through ECEF→ENU. Then add accuracy tests that compare `enuOffset` magnitude and `bearing` against `CLLocation.distance(from:)` at 0°, 25° and 51.5° latitude with a stated tolerance, keeping the existing round-trip tests but relabelling them as convention checks. State the residual error at 2 km in the docstring — the current docstring's claim of accuracy "well under GPS error" is false at low latitudes.

**Sources.**
- https://geographiclib.sourceforge.io/geod.html
- https://geographiclib.sourceforge.io/html/java/net/sf/geographiclib/Geodesic.html
- https://developer.apple.com/documentation/corelocation/cllocation/distance(from:)
- https://en.wikipedia.org/wiki/Geographic_coordinate_system#Length_of_a_degree

---

## Theme 9: Perceptual size compensation: a distance-dependent power law applied to a distance-independent derivation

**Verdict:** partially-confirms  
**Covers findings:** MATH-10  
**Effort:** medium

**Industry-standard practice.** The perception literature does support a real, distance-dependent effect — but not the one ADR-049 wrote down. Surveys of depth perception in HMDs and handheld AR consistently report egocentric distance *compression*: virtual distances are underestimated relative to real ones, and the compression grows with distance, while size judgements are comparatively accurate and follow a size-constancy law when the scene is cue-rich (Kelly et al., "Size and shape constancy in consumer virtual reality"; the Royal Society Phil. Trans. B study on familiar size in VR vs the real world). So a distance-dependent gain has a defensible perceptual basis. What does not hold is the ADR's own internal logic: it derives a constant angular demagnification ratio of 0.20–0.25 "at every distance", and a constant ratio is corrected by a constant gain (or equivalently a wider virtual FOV), not by `(d/8)^0.35` capped at 12×. The implemented law applies zero correction inside 8 m — where the same demagnification supposedly holds — and 6.9× at 2 km. The reviewer's failure case is also real and is a documented perceptual cost: breaking size constancy between two co-visible objects of equal true scale, and against familiar real referents (a 2 m figure rendering 3.9 m tall beside a 60 m-distant doorway) destroys the very familiar-size cue the literature says observers rely on, and makes two viewers of the same shared drop see different world sizes.

**Named examples.** Kelly, Cherep et al., "Size and shape constancy in consumer virtual reality" (Behav Res Methods 2020); Royal Society Phil Trans B 378:20210464 on familiar size in VR vs real world; the HMD depth-perception survey literature (Distance Estimation in VR and AR); Google Maps Live View, which renders navigation arrows at true world scale and uses a separate always-legible label layer; Pokémon GO, which scales distant PokéStop markers as HUD elements while creatures stay at world scale.

**Recommended approach.** Medium, mostly because it needs a decision rather than code. Pick one of two coherent positions and document which. (a) If the defect really is a fixed optical demagnification, apply the constant gain uniformly including inside d₀ — this preserves relative size and depth ordering exactly. (b) If the intent is to compensate measured distance compression, re-derive the exponent from the compression curve rather than borrowing size-constancy exponents (which describe observer behaviour and would be double-counted if applied as a rendering gain on top of an observer who already applies them), and re-scope the law explicitly to the marker/legibility layer that ADR-008 already permits for orbs, leaving world-scale objects at true scale. Either way add a test asserting that two drops of equal true scale render at equal world size regardless of viewer distance, and check a screenshot from two distances against a real referent of known height.

**Sources.**
- https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7406483/
- https://royalsocietypublishing.org/rstb/article/378/1869/20210464/42742/Familiar-size-affects-perception-differently-in
- https://www.researchgate.net/publication/330477517_A_Survey_on_Depth_Perception_in_Head_Mounted_Displays_Distance_Estimation_in_Virtual_Reality_Augmented_Reality_and_Mixed_Reality
- https://arxiv.org/pdf/2008.05505

---

## Theme 10: Matte compositing quality: posterior-as-alpha, a mislabelled bilateral filter, and a frame-rate-coupled temporal EMA

**Verdict:** confirms  
**Covers findings:** MATH-13, MATH-14, MATH-9  
**Effort:** medium

**Industry-standard practice.** Three separate but co-located issues. (1) A segmentation posterior is not a coverage fraction. Standard compositing converts a label posterior to a hard decision at a threshold and derives the soft edge from the *boundary* (distance transform, matting, or guided edge refinement); using the confidence directly as alpha conflates "I am unsure this is a building" with "this pixel is half building", and because low-confidence regions are spatially correlated (shadowed or backlit facades) the result is whole-surface ghosting rather than dither noise that averages out. Niantic Lightship's occlusion extension likewise combines depth with semantics via explicit suppression *regions*, not by weighting alpha with classifier certainty. (2) The refinement kernel is a joint-bilateral filter, not the guided filter of He, Sun & Tang. That matters substantively, not just nominally: the guided filter's ε/local-variance formulation self-adapts to local contrast, which is exactly the property that fails here — a fixed luma σ of 0.129 with σ_s ≈ R degenerates to an unweighted box blur precisely in the low-contrast night/matching-background case the brief calls out. He et al. state the guided filter "has better behavior near the edges" than the bilateral filter and has a theoretical connection to the matting Laplacian, which is why it is the standard choice for matte refinement. (3) A temporal filter with a bare per-invocation alpha is only valid when render and measurement rates are fixed and equal. Capture is pinned at 30 fps while ARView renders on the display link; RealityKit is currently reported to cap at 60 fps even on ProMotion, so the practical over-iteration is 2×, not 4× — the finding's magnitude is overstated but its substance holds: attack retention drops from 0.40 to 0.16 per measurement, so single-frame stencil noise passes through largely unfiltered.

**Named examples.** He, Sun & Tang, "Guided Image Filtering" (ECCV 2010 / TPAMI 2013) — the canonical matte-refinement filter; Niantic Lightship Occlusion Extension (depth + semantics with explicit suppression regions and occlusion stabilization); Apple's People Occlusion pipeline, which upsamples the stencil against the luma guide and thresholds the label; Google MediaPipe Selfie Segmentation, which documents a threshold plus boundary feather rather than posterior-as-alpha.

**Recommended approach.** Small each. (1) Threshold the semantic label decision on confidence (accept/reject) and derive the feather from the label boundary, so an accepted building pixel occludes fully and an unconfident one does not occlude at all — a half-opacity ghost through a wall fails the project's own "zero draw-over-known-front-surface" bar while being invisible to any test that checks only for fully-drawn content. (2) Either implement the actual guided filter (local mean/variance with ε regularizer) or set σ_s ≈ R/2 and derive the range σ from local luma variance; rename the code and ADR-030 to match whatever ships. (3) Pass the captured-frame timestamp into the uniforms and either advance the EMA only on a new capture timestamp, or convert the tuned alphas to time constants and compute `alpha = 1 − exp(−dt/τ)` per invocation — otherwise the tuned constants are not reproducible across devices or thermal states.

**Sources.**
- https://link.springer.com/content/pdf/10.1007/978-3-642-15549-9_1.pdf
- https://pubmed.ncbi.nlm.nih.gov/23599054/
- https://www.nianticspatial.com/docs/nsdk/how-to/ar/setup_real_world_occlusion/
- https://developer.apple.com/documentation/realitykit/arview/renderoptions-swift.property
- https://developer.apple.com/forums/thread/746624

---

## Theme 11: Firestore security rules: cross-user takeover, enumerable "secret" links, unmoderated reactions, and rules that live in a README

**Verdict:** confirms  
**Covers findings:** PBS-1, PBS-2, PBS-6, PBS-8, PBS-10  
**Effort:** medium

**Industry-standard practice.** All four sub-claims check out against current Firebase documentation. (a) Firebase's rules-structure guide is explicit that `request.resource` is the *pending* document and `resource` is the *existing* one; an update rule that checks only `request.resource.data.ownerUid == request.auth.uid` authorizes any signed-in user to rewrite any document and reassign ownership to themselves. The documented ownership pattern splits create from update: `allow create: if request.resource.data.ownerUid == request.auth.uid;` and `allow update: if resource.data.ownerUid == request.auth.uid && request.resource.data.ownerUid == resource.data.ownerUid;`. (b) `allow read` expands to `get` *and* `list`. Firestore's "Securely query data" page states "security rules are not filters — queries are all or nothing" and gives the exact pattern in play here: a rule keyed on a document field is satisfied by a client query constrained on that field ("The query constraint .where("published","==",true) guarantees that resource.data.published is true for any result. Therefore, this query satisfies the security rules and is allowed to read data."). So `whereField("visibility", isEqualTo: "link")` is an *allowed* full-collection page, and the 122-bit UUID in the share URL provides no confidentiality at all. The same page documents `allow list: if request.query.limit <= 10;` as the mechanism for bounding query size — which this ruleset does not use. (c) A reactions rule of `allow read: if request.auth != null` with an unconstrained `create` and no `update`/`delete` means unmoderated, unremovable UGC on strangers' documents, and Firestore does not cascade subcollection deletes when the parent document is deleted. (d) Rules and composite indexes are deployable, testable artifacts; keeping them only as a markdown fence means the live ruleset can silently be the console's 30-day "test mode" (`allow read, write: if true`) with nothing in the repo or CI able to detect it.

**Named examples.** Firebase's own rules-structure and securely-query-data guides; capability-URL products (Google Photos share links, Dropbox links) which never make the capability set listable; `@firebase/rules-unit-testing` emulator suites as shipped in Firebase's quickstart repos; the Firebase `delete-user-data` extension for subcollection cascade.

**Recommended approach.** Medium, and this is the highest-severity work in the whole review. Split create from update and gate update on `resource.data.ownerUid == request.auth.uid` with `ownerUid` pinned immutable. Split `allow get` from `allow list` and deny `list` on `drops` for non-owners entirely — link redemption should be an exact-ID `get` (or better, move it behind a Cloud Function / per-link secret token stored separately from the `visibility` field so the capability is not a queryable attribute). Constrain reaction writes with `request.resource.data.keys().hasOnly([...])` and an emoji allowlist, gate them on the parent's readability via a `get()` on the drop, allow authors and drop owners to delete, and add a cascade-delete trigger. Mirror the ownership guard that `FirebaseDropStore.save` already has into `delete`, and stop the recipient-side re-share path (`receivedViaLink` drops should be view-only in the Sent list — `HomeScreen` already distinguishes the roles, proving the field exists). Finally, add `firestore.rules` and `firestore.indexes.json` to the repo, wire them into `firebase.json`, deploy them from CI, and write `@firebase/rules-unit-testing` emulator tests that assert the *denials* — non-owner update denied, cross-user list denied, reaction write to an unreadable drop denied. The existing `FirebaseIntegrationTests` only exercises the owner happy path, so these vulnerabilities are untestable today by construction.

**Sources.**
- https://firebase.google.com/docs/firestore/security/rules-structure
- https://firebase.google.com/docs/firestore/security/rules-query
- https://docs.cloud.google.com/firestore/native/docs/security/rules-query
- https://firebase.google.com/docs/firestore/security/rules-conditions
- https://firebase.google.com/docs/rules/unit-tests
- https://firebase.google.com/docs/firestore/solutions/delete-collections

---

## Theme 12: Silent failure across the whole write path: unacknowledged Firestore writes, cache-first profile seeding, no-op saves without auth, and library-wiping decode

**Verdict:** confirms  
**Covers findings:** PBS-4, PBS-7, SWE-3, SWE-14, SWE-9  
**Effort:** medium

**Industry-standard practice.** Firestore's iOS SDK applies local latency compensation: `setData` without a completion handler returns as soon as the mutation is staged locally, and the Firebase iOS SDK issue tracker documents at length that the completion handler is not invoked at all while offline. The documented way to know a write reached the server is the completion/async overload plus, for a durable indicator, `snapshot.metadata.hasPendingWrites == false` via `addSnapshotListener(includeMetadataChanges: true)`. An app that renders "Synced — your drops follow you across devices" on the strength of a non-throwing local encode is asserting something the SDK never told it. The same metadata flag is the fix for the profile-seeding bug: Firestore delivers a cache event first, and a cache-sourced `exists == false` is indistinguishable from genuine absence unless you check `snapshot.metadata.isFromCache` — treating it as "first run" and writing a starter profile with `merge: true` overwrites the user's real display name and counters on any cold launch with an empty cache. The canonical fix is either that guard, a server-source read for the seed decision, or (best) seeding server-side from an Auth `onCreate` Cloud Function so the client never adjudicates existence. On the local side, a `guard let uid = ... else { return }` that returns success on a missing user, and `try?` on the persistence path for user-authored content, mean the create→share→receive loop can fail end to end with no signal to either party; the standard shape is an outbox/dirty-flag queue reconciled on auth and connectivity, with share affordances gated on a confirmed server write. And forward-compatible stores decode array elements individually (failable wrapper, skip-and-log) rather than letting one type mismatch throw and quarantine the entire library.

**Named examples.** Firebase iOS SDK issues #2167 and #3303 documenting the offline completion-handler behaviour; Firebase's "Access data offline" guide on `hasPendingWrites`; the Firestore "View changes between snapshots" guide for `includeMetadataChanges`; standard mobile outbox patterns as used by Notion, Bear and Things for offline-authored content.

**Recommended approach.** Medium. Switch every Firestore write to the completion/async overload, propagate the real error into `DropLibrary.lastSyncError`, and derive the Profile sync chip from acknowledged-write state (or `hasPendingWrites`) rather than from `firebaseConfigured`. Make `FirebaseDropStore.save`'s missing-uid path *throw* rather than return, and add a dirty-flag reconciliation pass that pushes unsynced local drops on `refresh`/auth-ready — today a magic link created before anonymous sign-in completes is dead forever, on this launch and every later one, while the share sheet still opens. Gate the profile seed on `!snapshot.metadata.isFromCache` (or move it to an Auth onCreate function). Make `add`/`update`/`remove` return a result and surface failures at the originating CTA. Decode drops per-element with a failable wrapper, preserve unknown keys and content types verbatim so a newer client's drop is not silently downgraded to `.text3D` on re-save, and replace the silent quarantine with a recoverable "couldn't read N drops" state.

**Sources.**
- https://firebase.google.com/docs/firestore/manage-data/enable-offline
- https://firebase.google.com/docs/firestore/query-data/listen
- https://github.com/firebase/firebase-ios-sdk/issues/3303
- https://github.com/firebase/firebase-ios-sdk/issues/2167
- https://firebase.google.com/docs/functions/auth-events

---

## Theme 13: App Store and privacy compliance: account deletion, privacy manifest, UGC moderation, and privacy copy that overstates what the system enforces

**Verdict:** confirms  
**Covers findings:** PBS-5, PBS-13, PBS-6, PBS-14  
**Effort:** large

**Industry-standard practice.** Every compliance claim in these findings checks out against current Apple documentation. (a) Guideline 5.1.1(v), in force since 30 June 2022 and still among the most common 2026 rejection causes, requires apps that support account creation to let users initiate deletion of the account *and its personal data* from within the app; disabling or deactivating is explicitly insufficient. The app has a user-editable profile (displayName, handle) backed by a `users/{uid}` document, so it plainly supports account creation in the reviewer-facing sense, and it ships no `signOut`, no delete path, and no credential linking at all. (b) `PrivacyInfo.xcprivacy` has been required for App Store submission since 1 May 2024, and `UserDefaults` is a required-reason API needing category `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` — the app uses `UserDefaults` and ships no manifest. `ITSAppUsesNonExemptEncryption` is likewise absent, which stalls every TestFlight/App Store upload on the export-compliance prompt. (c) Guideline 1.2 requires, for any app with user-generated content reaching other users: a filter for objectionable material, a reporting mechanism with action within 24 hours, the ability to block abusive users, and published contact info. Reactions carry a free-text `byName` straight to a stranger's screen with no block, report, or filter. (d) The "One-time link" copy on both the web invite page and `ReceiveScreen` describes behaviour nothing enforces — there is no redemption counter, no TTL, and no path to set `visibility` back to private. Apple treats privacy representations as reviewable claims independent of the underlying behaviour, and a materially false single-use claim on a permanently valid URL is exposure well beyond App Review. (e) The invite page fires a custom `augmentme://` scheme with no App Store fallback and no AASA file, so a recipient without the app gets Safari's "address is invalid" dialog — the growth loop converts at zero. Apple's documented mechanism is a Universal Link (HTTPS URL + `/.well-known/apple-app-site-association` + Associated Domains entitlement) which opens the app when installed and falls through to the web page, which can then redirect to the App Store; App Clips and AR Quick Look are the standard ways to deliver the payload before the install wall.

**Named examples.** Apple App Review Guidelines 5.1.1(v) and 1.2; Apple Developer News "Account deletion requirement starts June 30"; Apple's required-reason API documentation; Firebase `delete-user-data` extension; Universal Links / Associated Domains as used by every major share-link product (Spotify, Notion, Figma), all of which redirect non-installers to the App Store rather than firing a bare custom scheme.

**Recommended approach.** Large in aggregate, but each piece is small and all of it is submission-blocking. Ship a delete-account flow (delete owned drops + reaction subcollections + `users/{uid}`, then `Auth.currentUser.delete()`), ideally via the Firebase `delete-user-data` extension or a callable function so the deletion is server-authoritative; pair anonymous-first auth with an early Sign in with Apple / email-link upgrade so identity survives device loss, and until that exists correct the Profile copy from "across devices" to "this device" — the current claim is one the architecture cannot honour. Add `PrivacyInfo.xcprivacy` declaring CA92.1 and the app's data-collection types (precise location, name, user content), plus `ITSAppUsesNonExemptEncryption`. Add block/report/filter before any stranger-reachable reaction ships. Implement link revoke (set `visibility` back to private) and an optional expiry, and delete or correct the "One-time link" copy in both places until the behaviour matches. Add an AASA file plus a store-redirect fallback on the invite page, and either drive the profile trophy counters from a Firestore trigger or hide them rather than showing permanent zeros.

**Sources.**
- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/news/?id=12m75xbj
- https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk
- https://firebase.google.com/docs/extensions/official/delete-user-data
- https://developer.apple.com/documentation/xcode/supporting-associated-domains

---

## Theme 14: Concurrency discipline: render-thread vs main-actor state in the Metal pass, and unserialized read-modify-write in the local store

**Verdict:** confirms  
**Covers findings:** ARP-11, SWE-4, SWE-8  
**Effort:** small

**Industry-standard practice.** Under Swift 6 language mode both of these are compile errors, not style notes: strict concurrency surfaces exactly this class of cross-isolation mutation as a diagnostic, and the documented remedies are (a) confine mutable render state to the render thread and have main-actor code only flip a lock-protected or atomic flag that the callback reads, or (b) wrap the state in an explicitly locked, `@unchecked Sendable` box. The project already applies pattern (b) correctly to `SemanticFeed` and `MidFieldDepthFeed` in the same file, so the house style exists and was simply not applied to the pass itself — that internal inconsistency is stronger evidence than any external source. For the file-backed store, the canonical Swift-concurrency migration for a load-mutate-write sequence called from multiple unstructured `Task`s is to make the type an `actor` (or serialize it on a private queue): actors "isolate state and serialize access via a private executor, eliminating simultaneous mutations". `.atomic` file writes prevent a torn file but do nothing about last-writer-wins over a stale in-memory snapshot, which is the actual defect — two slider commits a few hundred ms apart, or a create racing a share, silently lose one write.

**Named examples.** Swift 6 strict-concurrency migration guidance (swift.org migration guide, Xcode 16 data-race safety); Apple's RealityKit post-process sample, which installs `renderCallbacks` once at setup; the project's own `SemanticFeed`/`MidFieldDepthFeed` as the correct in-repo precedent.

**Recommended approach.** Small. For `SemanticOcclusionPass`: install the render callbacks once at setup and gate the work inside `encode` on an atomic/lock-protected `enabled` flag, so `setCallbacksActive` and `uninstall` never mutate `pipeline`, `matteTextures` or `arView.renderCallbacks` while the GPU path is live — the realistic crash (main actor executing `matteTextures = []` between the render thread's `guard matteTextures.count == 2` and `matteTextures[matteIndex]`) is an index-out-of-range against the project's 99.5% crash-free bar, and it is timing-dependent and effectively undebuggable from a crash log. For `LocalDropStore`: make it an `actor` so load-mutate-write is atomic per instance, and add a concurrency test that fires N overlapping saves and asserts all N survive. Turning on `SWIFT_STRICT_CONCURRENCY = complete` (still in Swift 5 mode) as a warning-only step will surface the remaining instances of both patterns without a full Swift 6 migration.

**Sources.**
- https://www.swift.org/migration/documentation/migrationguide/
- https://developer.apple.com/documentation/swift/updating-an-app-to-use-strict-concurrency
- https://developer.apple.com/documentation/realitykit/arview/rendercallbacks-swift.struct
- https://developer.apple.com/documentation/swift/actor

---

## Theme 15: Frame budget: main-thread mesh generation, camera-buffer pool pressure, and capture-format policy with no upper bound

**Verdict:** partially-confirms  
**Covers findings:** ARP-7, ARP-12, ARP-6, ARP-8, SWE-11  
**Effort:** medium

**Industry-standard practice.** Mesh generation: Apple's RealityKit performance guidance and the async `MeshResource(from:)` initializer exist precisely because "generating a MeshResource is highly computationally intensive" and the async form "shifts the heavy lifting off the caller's execution context"; synchronous asset/mesh work on the main thread "blocks ARKit's tracking and mapping". Running a scalar vertex/index copy plus `MeshResource.generate(from:)` for a dozen streamed Streetscape buildings inside a per-frame `@MainActor` update is squarely against that — ARP-7 confirmed. Capture format: `recommendedVideoFormatFor4KResolution` returns 3840×2160@30 and 4K mode is available on iPhone 11 and up, so a filter that takes the *smallest* 30 fps format with only a lower area bound can indeed land on 4K when that is the only 30 fps entry; and an exact-equality `framesPerSecond == 30` filter with no fallback silently leaves ARKit's 60 fps default standing — ARP-6 confirmed. Buffer lifetime: ARP-12's *mechanism* is partly wrong and worth correcting. `frame.capturedImage` is a `CVPixelBuffer`, a CoreFoundation type that Swift ARC retains on assignment, so the buffer cannot be recycled out from under a background inference — the risk is the opposite one, and it is well documented: "when a client retains that pixelBuffer for longer periods, AVFoundation's pool of available buffers gets empty and CoreMedia starts dropping camera frames"; ARKit warns when a delegate retains more than 10 ARFrames and the camera starts dropping at 15–20. So the *symptom* the finding predicts (intermittent dropped ARFrames, a sawtooth fps trace mistaken for thermal throttling) is real and confirmed, but the proposed fix — retaining the ARFrame for the duration of each async request — makes the pool pressure worse, not better. The correct fix is bounded concurrency plus copying into an app-owned buffer for long-lived work, and `CVMetalTextureCacheFlush(cache, 0)` once per frame after encoding, since a non-zero CVMetalTexture use count prevents the IOSurface from being recycled. Perception scheduling: deriving a sensor *request* from a different predicate than the sensor's *use* (removing `.occlusion` from `sceneUnderstanding.options` in transit while leaving `sceneReconstruction = .mesh` requested) is the standard way an on-demand power ledger stops holding — confirmed. But SWE-11's related point cuts the other way and should be honoured: scene reconstruction is stateful and expensive to rebuild, so toggling it on a 5 s presence probe creates a multi-second occlusion hole; it should be shed on mode change or thermal pressure, not on a person walking in and out of frame.

**Named examples.** Apple "Improving the Performance of a RealityKit App"; Apple Developer Forums guidance on the "ARSessionDelegate is retaining N ARFrames" warning and AVFoundation TN2445 on frame drops; `CVMetalTextureCacheFlush` documentation; Google's ARCore iOS Streetscape Geometry sample, which builds occluder geometry off the render path; ARKit 6 (WWDC22-10126) on explicit 4K format selection.

**Recommended approach.** Medium. Move Streetscape vertex/index extraction and `MeshResource` generation to a background task keyed by geometry identifier and install the entity on the main actor when it lands — the same rule ADR-032 already codified for USDZ; stop swallowing generation failures with `try?`. Add an upper pixel-area bound (≤1920×1440) to the video-format policy, accept `framesPerSecond <= targetFrameRate` rather than exact equality, and log loudly when no format satisfies the policy instead of falling through to the platform default. Bound concurrent inference to one in-flight request per consumer, copy pixels for anything that outlives a frame, and add a per-frame `CVMetalTextureCacheFlush` after the completion handler is installed. Fold `renderPath` and `windowModeActive` into `setPerception`'s inputs so `sceneReconstruction`/`sceneDepth` requests derive from the same predicate that decides whether their output is consumed — while keeping reconstruction stable for the whole camera-visible session rather than cycling it on a presence probe.

**Sources.**
- https://developer.apple.com/documentation/realitykit/improving-the-performance-of-a-realitykit-app
- https://developer.apple.com/forums/thread/695404
- https://developer.apple.com/library/archive/technotes/tn2445/_index.html
- https://developer.apple.com/documentation/corevideo/cvmetaltexturecacheflush(_:_:)
- https://developer.apple.com/documentation/arkit/arconfiguration/recommendedvideoformatfor4kresolution
- https://developer.apple.com/videos/play/wwdc2022/10126/

---

## Theme 16: Derived-state and subscription hygiene: latching flags, count-keyed subscriptions, unremoved listeners, stacked presentations, swallowed SDK errors, and untested decision logic

**Verdict:** confirms  
**Covers findings:** ARP-3, ARP-9, ARP-13, ARP-14, SWE-5, SWE-7, SWE-10, SWE-12, SWE-13, PBS-3, PBS-9, PBS-11  
**Effort:** medium

**Industry-standard practice.** This cluster is one failure mode wearing six masks: state that should be *derived* is instead *written inside a branch that its own precondition guards*, so it can rise but never fall. `semanticMatteArmed` is written only when `geospatial.semanticActive` is true, so in the 15–55 m band where semantics switches off while `farMode` is still true, the flag freezes and the post-process pass stays attached for the session — reintroducing exactly the bandwidth/heat regression ADR-035 was written to remove. `occlusionActive` reports a one-shot `supportsX` capability probe as a live occlusion status, which is how an honesty indicator stops being honest. `liveEditingDrops` is never cleared on drop removal, so one stale id pins the power governor to `.full` forever. On the SwiftUI side, Apple's `.task(id:)` restarts only when the id value changes, so keying a subscription on `library.drops.count` cannot observe an in-place mutation — sharing a drop changes `visibility` without changing the count, so the sender is never subscribed to the drop they just shared and the loop's payoff never fires. That is a textbook derived-subscription anti-pattern; the correct key is the identity of what is being subscribed to (the sorted set of shareable drop ids), or an imperative call from the share action. Firestore listeners are lifecycle-bound resources whose documented contract is matched add/remove pairs — "detach listeners you no longer need" — and `stop()` with no callers and no `deinit` means unbounded growth in reads and billing. Stacking four `fullScreenCover`/`sheet` modifiers on one view and mutating two bindings in one synchronous transaction is a known SwiftUI limitation; the standard shape is a single `fullScreenCover(item:)` driven by a `Destination` enum so transitions are one state change SwiftUI can serialize. `try?` on a per-frame SDK entry point (`GARSession.update`) that drives a power-scheduling state machine removes the only evidence a field test could produce. And `loadDrops(near:radius:)` ignoring both parameters while the tested `GeoHash.queryBounds` has no production call site is a lie at the seam — a protocol method that names parameters and discards them.

**Named examples.** Apple's `.task(id:)` documentation on restart semantics; Firebase "Listen to realtime updates" on detaching listeners; SwiftUI enum-destination presentation as used in Point-Free's Composable Architecture navigation and Daniel Saidi's cover-context pattern; the project's own `PowerGovernor` extraction, which proves the team already knows how to make scheduling policy pure and testable — the extraction simply stopped short of the gates that decide whether each occluder runs.

**Recommended approach.** Medium, and it is the change that makes everything else above stay fixed. Extract the perception-gate composition (person / depth / semantics / pass-attach / render-path) into a pure function over an explicit input struct and compute every flag unconditionally each tick — then pin the full input→output table with tests, especially the semantics-off-while-far-mode-true transition and transit. Extract a `PlacedDrop` value type holding all per-drop state so removal is one operation rather than three incomplete cleanup sites across fourteen parallel dictionaries. Recompute `occlusionActive` each tick from the applied perception state plus the current `sceneUnderstanding.options`, keeping the capability probe as a separate private constant. Re-key the reaction subscription on the sorted set of shareable drop ids (or call it directly from `ShareDropSheet.sendLink`), reconcile the listener dictionary by diffing desired against active, add a `deinit`/background teardown, and persist a last-seen watermark instead of resetting `startedAt`. Capture `editingDropID` at drag start so a nearest-drop change mid-drag cannot commit to the wrong object. Collapse camera/create/onboarding/memory into one `Destination` enum with a single `fullScreenCover(item:)` and queue deep links behind whatever is presented. Log GARSession error codes (rate-limited) and transition to `.failed` after sustained update failures. Either narrow the store protocol to `loadMyDrops()` or actually implement the bounded geohash query with `.limit(to:)` and cursors, and correct ADR-039's claim about what shipped. Finally, add the cross-account field test FIELDTESTS.md is missing — ADR-040 records the loop as never having been exercised across two accounts, which is precisely why PBS-3 survived.

**Sources.**
- https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:)
- https://firebase.google.com/docs/firestore/query-data/listen
- https://developer.apple.com/documentation/swiftui/view/fullscreencover(item:ondismiss:content:)
- https://danielsaidi.com/blog/2020/10/28/an-easier-way-to-handle-full-screen-covers-in-swiftui
- https://developers.google.com/ar/reference/ios/interface_g_a_r_session

---
