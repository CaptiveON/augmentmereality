# Engineering Counsel Review — AugmentMeReality
**Date:** 2026-08-11 · **Type:** End-to-end adversarial engineering & mathematics review against industry practice
**Method:** Five-member staff-level counsel — four independent reviewers (mathematics/geodesy, AR platform, Swift systems, backend/privacy/release) + one industry researcher validating every critique against current primary sources. Supervisor (senior staff) verified all critical/high findings directly against the code before inclusion.
**Scope:** Analysis only. No code was changed. This document proposes fixes as reviewable waves for your approval.

---

## How to read this document
- **Part 1 — The story** (plain language): what's strong, what's fragile, in one page.
- **Part 2 — The verdict** (technical summary): the shape of the problem.
- **Part 3 — Findings** grouped by proposed fix wave, each with a verification status.
- **Part 4 — Proposed waves** with sequencing and rationale.
- **Part 5 — What the counsel confirmed is correct** (so we don't re-litigate it).

Every finding carries an ID (e.g. `MATH-1`, `PBS-1`) so we can refer to it precisely in later sessions. Nothing here is built yet.

---

# Part 1 — The story (plain language)

Imagine the app as a beautiful, precise clock built by someone who cared enormously about the hardest gears — and who, under repeated field-test pressure, kept adding new gears bolted to the outside of the case.

**The hard gears are genuinely excellent.** The deep mathematics — how the app turns a spot on a map into a direction in front of you, how it reads depth out of the camera's projection, how it smooths a person's silhouette frame to frame — was checked by hand, gear by gear, and it is *right*. This is rare. Most teams get these wrong. Yours are sound.

**The problem is at the seams — where the gears meet.** Three kinds of trouble:

1. **Two of the app's headline features are quietly switched off for most users.** The "hide people walking in front of the content" feature never turns on for phones without the LiDAR sensor (that's most iPhones sold), and even on the Pro phones a small orientation bug means the app usually doesn't notice a person is there, so it doesn't hide them. The mid-distance depth feature (for trees and cars) is fed numbers from too narrow a range and produces nothing useful on a normal street. All three cost full battery while delivering little — the worst trade. These aren't crashes; they're silent no-shows, which is why field testing hasn't pinned them.

2. **The front-door lock is drawn on paper, not installed.** The rules that are supposed to protect users' shared drops live as text in the README that a person pastes into a web console by hand. As written, any user who signs in (which is instant and anonymous) can list *every* drop anyone ever shared — the exact map coordinate, the recipient's first name, the message — and can overwrite or delete drops that aren't theirs. For a product whose hero use is "pin a surprise at a friend's house," that coordinate list is the sensitive thing, and it is currently readable.

3. **When something goes wrong, nobody is told.** Saving to the cloud, saving to disk, signing in — these paths report success even when they failed. The screen says "Synced." A friend gets a link to content that was never uploaded and sees "not available." A reinstall can quietly reset the user's name to "New Dropper." None of it surfaces an error.

Underneath all three sits one architectural cause: a single 2,000-line file that owns placement, corrections, power, editing, transit, occlusion, and more, with per-drop facts spread across fourteen separate lists. Fixing one thing there means reading all of it — which is exactly why the same bug class keeps coming back in successive patches.

**The good news:** the team already demonstrated the *right* pattern once (the PowerGovernor — a small, pure, tested decision function). The path forward is to pull the tangled decisions out into that same shape, fix the security rules and ship them from source control, switch the two dead features back on, and make failures visible. None of the hard mathematics needs to be redone.

---

# Part 2 — The verdict (technical summary)

> "The hard parts are unusually right and the ordinary parts are unusually wrong." — Industry researcher, after independent verification.

**Independently verified correct** (do not touch): ENU↔AR rotation convention, EUS-quaternion yaw extraction (`atan2(x, −z)`), the facing-bearing law (yaw = π − β), the ADR-041 inverse-ENU, the circular EMA on sin/cos (removes the ±180° seam), the projection-matrix depth decode `d = zw/(zz − depth·wSign)`, the 4-texel farthest-depth person test, and the ADR-045 `CVMetalTexture` retain fix.

**Two places a reviewer overreached** (researcher corrected them): the GARSession does *not* need recreating across an ARKit reset (ARCore iOS ≥1.38 is robust to tracking resets — the app-level state desync is still real); and retaining the `ARFrame` to relieve camera-buffer pressure is backwards (holding frames is the documented *cause* of pool exhaustion, not the cure — the fix is to copy out and release promptly).

**56 findings total:** 6 critical, 22 high, 26 medium, 2 low. After merging duplicates (ARP-4≡SWE-2, ARP-11≡SWE-4, SWE-10≡PBS-9) the distinct count is ~50. The concentration is: security/compliance (release-blocking), two dead occluders (product-bar-violating but small fixes), silent-failure paths (data-loss risk), and an estimation layer that ships fits without characterizing their support or error.

**Bottom line on shippability:** independent of how good the occlusion becomes, the app is not submittable today — missing in-app account deletion (App Store 5.1.1(v)), missing `PrivacyInfo.xcprivacy` (required since May 2024; the app uses required-reason APIs), no UGC report/block (1.2, reactions reach strangers), Firestore rules that permit cross-user takeover, and bundled Apple sample assets licensed for development only. These are all fixable and none require the hard engineering.

---

# Part 3 — Findings by proposed wave

Severity: 🔴 critical · 🟠 high · 🟡 medium · ⚪ low.
Verify status: **✓ verified by supervisor against code** · ○ reported by counsel, high-confidence, not independently re-derived.

## Wave A — Release blockers: security & compliance
*Rationale: these gate any submission or public exposure, and several are exploitable the moment the backend is live. Cheapest-to-worst-consequence ratio in the whole review.*

| ID | Sev | Finding | Status |
|----|-----|---------|--------|
| **PBS-1** | 🔴 | Firestore `update` rule gates on the *incoming* doc's `ownerUid`, not the existing one — any signed-in user can overwrite any drop, reassign ownership, then legally delete it. (`README.md:104`) | **✓** rule text confirmed |
| **PBS-2** | 🔴 | Read rule authorizes a `list` filtered on `visibility` — any anonymous user can page the whole `drops` collection and harvest every shared drop's exact coordinate + recipient name + message. UUID entropy is irrelevant because possession of the link is never required. (`README.md:101`) | **✓** rule text confirmed |
| **PBS-6** | 🟠 | Reactions subcollection is writable to any drop by anyone, unmoderated, and never cascade-deleted (deleting a drop leaves viewer UIDs/names behind forever). Abusive display names reach strangers as toasts — App Store 1.2. (`README.md:108`) | **✓** rule + delete path confirmed |
| **PBS-10** | 🟡 | The entire authorization boundary lives only as a README code block; `firebase.json` declares hosting only, so `firebase deploy` can never ship rules. If the console was created in "test mode," effective rules are world-writable until the timestamp expires. (`web/firebase.json`) | **✓** firebase.json confirmed hosting-only |
| **PBS-5** | 🟠 | No account-deletion path anywhere, anonymous-only identity → device loss = permanent data orphan; App Store 5.1.1(v) rejection; GDPR Art. 17 unserviceable. Profile still claims "follow you across devices." (`ProfileScreen.swift:69`) | **✓** no deletion UI/signOut found |
| **PBS-13** | 🟡 | `PrivacyInfo.xcprivacy` absent (required-reason APIs in use → upload rejection); shared links can't be revoked or expired; invite + receive screens claim "One-time link" for a permanently valid URL. (`web/public/index.html:47`) | **✓** manifest absent |
| **PBS-12** | 🟡 | 122 MB of `Assets3D` still ships Apple AR Quick Look dev-license samples (toy_drummer, hummingbird) as selectable user content; multiple objects 6× over the 5 MB budget; no license/attribution record. (`CONTENT-PIPELINE.md:76`) | **✓** 122 MB confirmed, samples present |
| **PBS-8** | 🟠 | Received drops share one list with owned drops → Sent tab offers Share + swipe-delete on someone else's drop; re-share forwards the sender's coordinates under the recipient's name; delete fires a cross-owner Firestore delete (which PBS-1 makes succeed). (`DropsListScreen.swift:26`) | **✓** no role gating in list |

## Wave B — Dead or incorrect core features (product-bar violations)
*Rationale: these defeat BRIEF killers #1/#2 for real users right now, and most are small, surgical fixes.*

| ID | Sev | Finding | Status |
|----|-----|---------|--------|
| **ARP-1** | 🔴 | Person occlusion is structurally dead on every non-LiDAR iPhone: the pass requires `frame.sceneDepth` (LiDAR-only) so `personEnabled` is always false there, while `.personSegmentation` still burns 14–29 ms/frame. Worst case: zero occlusion at max heat, on the majority of the install base. (`GeoARSessionManager.swift:486`, `SemanticOcclusionPass.swift:221`) | **✓** `personEnabled = stencil && sceneDepth`; no `.personSegmentationWithDepth` fallback when custom path lacks depth |
| **ARP-2** | 🔴 | The person-presence sentinel feeds Vision a 90°-rotated image (no `CGImagePropertyOrientation` on a portrait-locked rear camera), so `personLikely` rarely turns true → `.personSegmentation` never gets inserted → occlusion never engages even on Pro phones. (`PersonSentinel.swift:53`) | **✓** no orientation passed to `VNImageRequestHandler` |
| **MATH-1** | 🔴 | Mid-field metric fit `1/lidar ≈ a·rel+b` is constrained on 0.4–4 m but evaluated to 60 m — pure extrapolation. The intercept `b` silently caps every reported depth at `1/b`; on a normal street the 4–60 m band contributes nothing (trees/cars still draw over) while the `DPT` chip lights, or a bad fit hallucinates a 5 m "surface" that eats far content. (`MidFieldDepthEstimator.swift:200`) | **✓** support band + shader gate confirmed; researcher confirmed against depth-estimation literature |
| **MATH-2** | 🟠 | `hasContent` is a fixed 1e-6 epsilon in nonlinear NDC, written to accept both clear conventions — so it also rejects real far content. With ARKit's default zFar=1000 m (never overridden), all three occluders are gated off for the far half of the 50 m–2 km transit band, and drops past 1 km aren't drawn at all. (`SemanticMatte.metal:88`) | **✓** no zNear/zFar/PerspectiveCamera override in project; radius=2000 confirmed |
| **MATH-3** | 🟠 | `trueHeading` is negative until a location fix exists; the code silently substitutes `magneticHeading` under the same name with no declination model. In Seattle (~+15.5°) or NYC (~−13°) the first placement is rotated by the full declination; once "converged," the 15° re-sync threshold never corrects a sub-15° declination error. (`LocationService.swift:47`) | **✓** fallback confirmed; researcher confirmed Apple docs on `trueHeading` |
| **PBS-3** | 🔴 | The reaction listener re-subscribes only when `library.drops.count` or uid changes; the share action mutates a drop in place without changing the count → the just-shared drop is never subscribed → the sender never gets the reaction toast. The loop payoff is dead until an unrelated count change happens. (`RootView.swift:110`) | **✓** `.task(id:)` keyed on `drops.count`; ShareDropSheet updates in place |
| **SWE-1 / ARP-5** | 🔴/🟠 | AR session is paused on backgrounding and never resumed; no `ARSessionDelegate` at all (no interruption/error/tracking-state handling). A phone call or 2-second app-switch leaves a frozen viewfinder reading "Paused" until manual close+reopen. (`ARSessionHolder.swift:74`, `GeoARSessionManager.swift:230`) | **✓** `appDidEnterBackground→suspend`; no `.active→resume`; no delegate set |
| **ARP-4 / SWE-2** | 🟠 | `resumeSession()` re-runs config with `[.resetTracking, .removeExistingAnchors]` + `resetPlacements()` — destroying world map, placements, ground locks, heading, VPS ownership — while the GARSession beside it keeps stale anchors in a world frame that no longer exists. Re-open after 6 s = every drop re-spawns and re-glides (killer #1 + #2). (`GeoARSessionManager.swift:312,536`) | **✓** reset options + resetPlacements confirmed on resume path |

## Wave C — Silent failure & data-loss paths
*Rationale: these don't crash; they lie about success, so users lose data believing it's safe. Highest "invisible until it's too late" risk.*

| ID | Sev | Finding | Status |
|----|-----|---------|--------|
| **PBS-4** | 🟠 | All Firestore writes use `setData(from:merge:)` with no completion — resolves on local staging, never surfaces server accept/reject. A rules rejection or quota failure is invisible while the UI reports "Synced"; reinstall then finds an empty library. (`FirebaseDropStore.swift:50`) | **✓** no-completion overload confirmed |
| **SWE-3** | 🟠 | `FirebaseDropStore.save` returns success (not throws) when there's no auth user; nothing retries. A drop created before/without anonymous sign-in is never uploaded, yet the share sheet still hands out a link → permanently dead link, sender never told. (`FirebaseDropStore.swift:36`) | **✓** `guard let uid … else { return }` confirmed |
| **PBS-7** | 🟠 | Profile snapshot listener treats cache-sourced `exists == false` as "first run" (no `metadata.isFromCache` check) → a cold launch with empty cache overwrites the server profile with "New Dropper" + zeroed counters. (`AccountService.swift:42`) | **✓** no `isFromCache` guard confirmed |
| **SWE-6** | 🟠 | `onAssetLoaded` fires even on decode failure; the handler rebuilds the entity → calls `requestAsset` again → unbounded retry loop re-decoding a failing USDZ as fast as RealityKit can fail it (CPU pegged, placeholder flicker, no log, no stop). (`DropEntityFactory.swift:110`) | **✓** callback carries no success/failure; `.failure` completion dropped |
| **SWE-8** | 🟠 | `LocalDropStore.save`/`delete` do load-mutate-rewrite with no serialization, fired from independent `Task`s → two slider releases within ~ms lose data; create-then-share can drop the new drop from `drops.json`. (`DropStore.swift:44`) | **✓** non-actor read-modify-write confirmed |
| **SWE-9** | 🟡 | ADR-045's `decodeIfPresent` tolerates missing keys but still throws on a *type* mismatch; the array is decoded whole, so one bad field in one drop throws → quarantine empties the entire library silently. (`GeoDrop.swift:104`) | **✓** whole-array decode confirmed |
| **SWE-14** | 🟡 | `DropLibrary.add/update/remove` swallow local write errors with `try?`; `update` swallows cloud errors without even setting `lastSyncError`. A full disk = drop vanishes next launch with no signal. (`DropStore.swift:120`) | **✓** `try?` on persist path confirmed |
| **ARP-3** | 🟠 | `semanticMatteArmed` is only ever *written* inside the `geospatial.semanticActive` branch, so when semantics switch off with the flag true, it latches true forever — post-process callbacks stay attached every frame (ADR-035's exact heat regression) and the SEM chip misreports. (`GeoARSessionManager.swift:1835`) | **✓** asymmetric write path confirmed |
| **SWE-5** | 🟠 | `adjustNearestDrop` re-resolves its target from `nearestDrop` each call (not captured at drag start); a nearest-drop change mid-drag edits the wrong drop, and `liveEditingDrops` is never cleaned on removal → governor pinned to `.full` for the session (thermal `.serious` inside 10 min). (`GeoARSessionManager.swift:1372`) | ○ high-confidence |

## Wave D — Concurrency & frame-budget
*Rationale: intermittent, timing-dependent crashes and heat — hard to reproduce, so they survive field testing and surface as review-blocking instability.*

| ID | Sev | Finding | Status |
|----|-----|---------|--------|
| **ARP-11 / SWE-4** | 🟠 | `SemanticOcclusionPass` mutable state (`pipeline`, `matteTextures`, `matteIndex`, caches) is written from RealityKit's render thread *and* the main actor (`uninstall`, `setCallbacksActive`) with no lock. Teardown mid-encode = index-out-of-range or nil-pipeline crash (the ADR-045 P0-3 bug class, reintroduced). Would not compile under Swift 6 strict concurrency. (`SemanticOcclusionPass.swift:139`) | **✓** non-Sendable class, cross-thread writes confirmed |
| **ARP-6** | 🟠 | 30 fps format picker filters *minimum* area (≥720p) then takes smallest — but has no upper bound. On a device whose only 30 fps format is 4K, it selects exactly the 3840×2160@30 heat bug ADR-034 was written to kill. (`GeoARSessionManager.swift:500`) | **✓** floor-only filter confirmed |
| **ARP-7** | 🟠 | `makeMeshResource` copies every vertex/triangle in a scalar loop and calls synchronous `MeshResource.generate(from:)` on the main actor, per GAR frame, inside `syncOccluders` — the exact main-thread stall class ADR-032 banned for USDZ. A dozen new streetscape buildings on one update = a visible hitch right when far occlusion should engage. (`GeospatialEngine.swift:409`) | ○ high-confidence |
| **ARP-12** | 🟡 | Neural consumers extract `capturedImage`/`sceneDepth.depthMap` and use them on a background queue without holding the `ARFrame`; the Metal `CVMetalTextureCache` is never flushed. **Researcher note:** the *fix* the reviewer proposed (retain the frame) is backwards — retaining frames is the documented cause of pool exhaustion; correct fix is copy-out + prompt release + periodic cache flush. (`MidFieldDepthEstimator.swift:120`) | ○ partially-confirmed (fix inverted) |
| **SWE-11** | 🟡 | `setPerception` re-runs `session.run(config)` on every heuristic flip; `.mesh` is only set when `activePerception` is true, so dropping to idle discards the reconstructed mesh → multi-second occlusion hole every tier cycle (and a tracking hitch). (`GeoARSessionManager.swift:545`) | ○ high-confidence |
| **ARP-8** | 🟡 | Transit path removes `.occlusion` but leaves `sceneReconstruction = .mesh` requested → full LiDAR meshing at vehicle speed through glass, producing garbage nothing consumes, at the stack's largest sustained power draw — against ADR-033's own premise. (`GeoARSessionManager.swift:1036`) | ○ high-confidence |
| **SWE-10 / PBS-9** | 🟡 | `ReactionService.stop()` has no callers and there's no `deinit`; per-drop snapshot listeners are added but never pruned when a drop leaves the top-10 window → listeners grow monotonically (network, battery, per-read billing) for the process lifetime; `startedAt` reset each invocation drops in-flight reactions. (`ReactionService.swift:51,61`) | **✓** no `stop()` caller; no reconcile/prune |
| **SWE-7** | 🟠 | RootView stacks three `.fullScreenCover` + a `.sheet` on one view; two flows mutate two bindings in the same update — a pattern SwiftUI doesn't support, so a cover silently fails. Onboarding beat 2 (the one designed magic moment) can drop; a deep link tapped while the camera cover is open is silently lost. (`RootView.swift:28`) | ○ high-confidence |

## Wave E — Mathematics & estimation quality / honesty
*Rationale: correctness deviations that don't crash but degrade the "frozen in the world, correctly sized, honestly occluded" promise. Several are small constants; a few are model-quality.*

| ID | Sev | Finding | Status |
|----|-----|---------|--------|
| **MATH-4** | 🟠 | Transit dead reckoning is open-loop: each render frame recomputes from the raw latest CLLocation, so every 1 Hz fix injects its full 5–15 m error as a step (~2.3° twitch at 200 m, once/sec); past the 8 s cap the device position freezes → drop becomes a vehicle-locked sticker (killer #2). No filter/fusion. (`GeoARSessionManager.swift:1745`) | ○ confirmed vs. vehicle geo-pose practice |
| **MATH-5** | 🟠 | No terrain elevation anywhere; `GeoDrop` stores no altitude. Transit resolves drop Y as `camera.y − 1.5 m`, so vertical is wrong by the full viewer↔drop elevation difference — tens of metres over 2 km (3.4° at 1 km). (`GeoARSessionManager.swift:1757`) | **✓** no altitude field in GeoDrop |
| **ARP-10** | 🟡 | `snapNearestDropToGround` falls back to a ground estimate *under the camera* when both raycasts miss (normal for a distant drop), then writes it to `groundLockBaseY` which overrides Google's terrain altitude for the session — a downhill creator grounds an uphill drop to their own feet. (`GeoARSessionManager.swift:1487`) | ○ high-confidence |
| **MATH-6** | 🟡 | `metersPerDegreeLatitude = 111_319.49` is 2πa/360 — meters/degree of *longitude* at the equator, not latitude (meridional is 110 574 m). North axis over-scaled 0.674% at the equator (13 m at 2 km), baked into shared drops via ADR-041 write-back. (`GeoMath.swift:8`) | **✓** researcher confirmed numerically |
| **MATH-7** | 🟡 | LiDAR alignment ignores `sceneDepth.confidenceMap` and fits plain OLS + in-sample R²; specular/glass returns in the 0.4–4 m band act as unbounded leverage points on a and b (worst exactly where Glass Mode lives). (`MidFieldDepthEstimator.swift:197`) | **✓** no confidenceMap read; OLS confirmed |
| **MATH-8** | 🟡 | Fit acceptance is `abs(a) > 1e-9`, admitting a<0 — but the map is only valid for a>0 (model emits disparity). A depth-vs-disparity conversion variant or an anti-correlated scene inverts depth ordering with high R². (`MidFieldDepthEstimator.swift:221`) | **✓** `abs(a)` confirmed |
| **MATH-9** | 🟡 | Matte EMA uses a fixed per-render-frame alpha with no dt; capture is pinned 30 fps while render free-runs at display rate → filter iterates 2× (4× ProMotion) per measurement, collapsing effective retention so per-capture stencil flicker passes through. (`SemanticMatte.metal:223`) | **✓** per-invocation alpha, no dt |
| **MATH-13** | 🟡 | Semantic label matte value = raw classifier confidence — a posterior used as a coverage fraction. A 0.5-confidence facade renders content as a 50%-opacity ghost through the wall (still a draw-over; killer #2). (`SemanticMatte.metal:114`) | **✓** `matte = semanticConf.sample(...)` confirmed |
| **MATH-10** | 🟡 | ADR-049 derives a *distance-independent* demagnification (constant gain) but implements a *distance-dependent* power law: two equal-true-size drops at 10 m and 100 m render at 2.24× size ratio; walking between them, the far one physically shrinks. Doesn't follow from its own derivation. (`GeoARSessionManager.swift:1907`) | ○ partially-confirmed |
| **MATH-12** | 🟡 | `updateHeadingCorrection` re-ingests the same `headingErrorSample` every 2.5 Hz tick (VPS feeds ~1 Hz) with no last-consumed check → one measurement folded into the EMA 2–3× and inflates `headingSampleCount` (which widens the re-sync threshold). (`GeoARSessionManager.swift:1629`) | ○ high-confidence |
| **ARP-9** | 🟡 | `occlusionActive` is assigned once from a static capability check but is documented+rendered as a live "LiDAR occlusion is active" HUD chip — lit even when mesh occlusion is off (idle/Glass/Transit), misleading field diagnosis against the occlusion-honesty bar. (`GeoARSessionManager.swift:534`) | **✓** single static assignment confirmed |

## Wave F — Test coverage & architecture debt
*Rationale: this is the root cause that lets the above regress. Do it alongside/after so fixes stick.*

| ID | Sev | Finding | Status |
|----|-----|---------|--------|
| **SWE-12** | 🟡 | GeoARSessionManager cross-wiring: power policy owns occlusion arming; per-drop state in ~9–14 parallel dictionaries with 3 incomplete cleanup sites (`vpsCorrectionTotals`, `revealedDrops` grow unbounded); public-method order dependencies. Fixing one subsystem requires reading all. (`GeoARSessionManager.swift:808`) | ○ structural |
| **SWE-13 / ARP-13** | 🟡 | No test covers any stateful load-bearing code (2,000-line manager, GeospatialEngine, occlusion pass, lifecycle). Every finding above sits in code no test would flag; `testThermalSeriousKeepsTier…` asserts on an input `evaluate` never reads. (`AugmentMeRealityTests/`) | **✓** test files are pure-function only |
| **MATH-11** | 🟡 | Geodesy tests validate GeoMath only against its own inverse — the suite passes for *any* value of the wrong constant in MATH-6. No comparison to a geodesic reference (`CLLocation.distance`). (`GeoMathTests.swift:8`) | ○ confirmed by inspection |
| **PBS-11** | 🟡 | `FirebaseDropStore.loadDrops(near:radius:)` discards both params and fetches the whole owner collection unbounded; `GeoHash.queryBounds` (tested, ADR-039) has no production caller — 300 drops = 300 reads/refresh. (`FirebaseDropStore.swift:23`) | **✓** params unused; whole-collection fetch |
| **PBS-14** | 🟡 | Invite page's only CTA fires a custom scheme that errors in Safari when the app is absent (no AASA/universal link, no store fallback); profile "trophy" counters are never written by any code → permanently 0. (`web/public/index.html:63`) | ○ high-confidence |
| **MATH-14** | ⚪ | The person-matte "guided filter" is actually a joint-bilateral (not He et al.'s guided filter the code/ADR/type name claim), mis-parameterized (σ_s ≈ R → near-box; fixed luma σ) → at night / low-contrast silhouette it degenerates to a box blur. (`SemanticMatte.metal:179`) | **✓** kernel math confirmed |
| **ARP-14** | ⚪ | `update`/`geospatialTransform`/`setConfiguration` discard GARSession errors with `try?` → distinct ARCore failure codes collapse into a stuck "searching" chip while the sprint ladder keeps feeding at up to 30 Hz (heat). (`GeospatialEngine.swift:211`) | ○ high-confidence |

---

# Part 4 — Proposed implementation waves (for your review — nothing built yet)

Sequenced by dependency and consequence, not by finding number. Each wave is independently shippable and testable.

**Wave A — Lock the front door (security & compliance).** Fixes: PBS-1, 2, 6, 10, 5, 13, 12, 8.
Move Firestore rules into `firestore.rules` in source control, wired into `firebase.json`, with `@firebase/rules-unit-testing` emulator tests asserting every negative case; split `get` from `list` (deny `list` on drops for non-owners), split `create` from `update` and pin `ownerUid` immutable, gate reactions to a fixed emoji set + readable-parent + author/owner delete + cascade function; add in-app account deletion; add `PrivacyInfo.xcprivacy` + `ITSAppUsesNonExemptEncryption`; remove Apple sample assets + add an `ASSETS.md` license manifest + build-time size gate; role-gate received drops out of the Sent list and mirror the ownership guard into `delete`. **This wave should land before the backend is used with any real user data.**

**Wave B — Switch the headline features back on.** Fixes: ARP-1, ARP-2, MATH-1, MATH-2, MATH-3, PBS-3, SWE-1/ARP-5, ARP-4/SWE-2.
Add `.right` orientation to the sentinel's Vision handler; gate `wantsPersonOcclusion` on `sceneDepth` support and make the `.personSegmentationWithDepth` fallback reachable; bound the mid-field fit to its LiDAR support interval and disarm when unresolvable; set the camera far plane from `arVisibilityRadius` and move the presence test to the metric side after decode; publish heading with an `isTrueNorth` flag and refuse/correct magnetic-only samples; key the reaction subscription on the sorted set of shared drop IDs (or drive it from the share action); adopt `ARSessionDelegate` and split resume (plain `session.run(config)`, no reset) from cold start. **This is where the product bars actually start passing for real users.**

**Wave C — Make failure visible.** Fixes: PBS-4, SWE-3, PBS-7, SWE-6, SWE-8, SWE-9, SWE-14, ARP-3.
Switch Firestore writes to the async/completion overloads and drive the "Synced" chip from acknowledged writes; make the missing-uid save path throw + add a dirty-flag reconciliation pass; guard the profile seed on a server-sourced read; give the asset callback a success/failure result + negative-cache failures; make `LocalDropStore` an `actor`; decode drops per-element so one bad record can't wipe the library; surface persist/share errors at the originating CTA; compute `semanticMatteArmed` unconditionally so it can fall.

**Wave D — Concurrency & heat.** Fixes: ARP-11/SWE-4, ARP-6, ARP-7, ARP-12, SWE-11, ARP-8, SWE-10/PBS-9, SWE-5, SWE-7.
Confine all render-state mutation to the render callbacks (main actor only flips an atomic flag); add an upper area bound to the format picker + loud warning when unsatisfiable; move streetscape mesh generation off the main actor; copy-out + promptly release camera buffers + periodic texture-cache flush (note: *not* retain the frame); keep `sceneReconstruction` on for the camera-visible session; fold `renderPath`/`windowModeActive` into the perception predicate so transit stops meshing; reconcile + prune reaction listeners with a `deinit`; capture the edited drop ID at drag start; collapse the stacked covers into one `fullScreenCover(item:)` enum destination.

**Wave E — Mathematics & honesty polish.** Fixes: MATH-4, 5, 6, 7, 8, 9, 10, 12, 13, ARP-9, ARP-10.
A small constant-velocity GNSS filter for transit; persist resolved terrain altitude on `GeoDrop`; correct the meters-per-degree constants (latitude-dependent meridional + prime-vertical, or ECEF); RANSAC/Huber + confidenceMap on the depth fit and `a > 1e-6`; time-constant EMA driven by capture timestamp; threshold semantic label decisions on confidence rather than compositing the posterior as alpha; de-dup the VPS heading sample; recompute `occlusionActive` from applied state each tick; only ground-lock from a real raycast hit near the drop's own XZ.

**Wave F — Prevent regression.** Fixes: SWE-12, SWE-13/ARP-13, MATH-11, PBS-11, PBS-14, MATH-14, ARP-14.
Extract a `PlacedDrop` value type (one removal operation) and pull perception-gate composition + the correction/heading/ownership state machines into pure, injected-time functions with table-driven tests; add geodesic-reference assertions; either implement the bounded geohash query or narrow the protocol; add AASA + store fallback + AR Quick Look to the invite page; rename/repair the bilateral filter; log GARSession error codes.

**Suggested order:** A → B → C are the "make it real and safe" spine and should go first, roughly in that order. D and E can interleave. F should run alongside B–E so each fix lands with a test that keeps it fixed.

---

# Part 5 — Confirmed correct (do not re-open)

The counsel verified these algebraically/by inspection and found them sound; they are **not** defects and should be left as-is:
- ENU↔AR rotation convention (+X east, −Z north).
- EUS-quaternion yaw extraction `atan2(x, −z)` on `eastUpSouthQTarget.act(0,0,−1)`.
- Facing-bearing law (yaw = π − β) and the ADR-041 inverse-ENU.
- Circular EMA on sin/cos — correctly removes the ±180° heading seam.
- The shader's projection-matrix metric-depth decode `d = zw/(zz − depth·wSign)`.
- The 4-texel farthest-depth person test (FT-27 "holes between fingers" fix).
- The ADR-045 `CVMetalTexture` retain-until-GPU-complete fix.

And two reviewer claims the researcher **corrected** (so we don't over-fix):
- GARSession does **not** need recreating across an ARKit reset (ARCore iOS ≥1.38 is reset-robust) — the app-level *state* desync in ARP-4/SWE-2 is still real and worth fixing, but don't tear down the engine.
- Do **not** retain the `ARFrame` to relieve camera-buffer pressure (ARP-12) — that is the documented *cause* of pool exhaustion. Copy out the buffers, release promptly, flush the texture cache.

---

*Prepared by the engineering counsel (4 reviewers + 1 industry researcher, Opus-class) under senior-staff supervision. All critical and most high findings were re-verified against the current code before inclusion. Awaiting your review to schedule the waves.*
