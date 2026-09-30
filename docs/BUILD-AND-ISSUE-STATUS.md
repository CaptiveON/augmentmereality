# Build and issue handoff

Updated 30 September 2026. Read this file first when resuming work. It supersedes
the next-step lists in earlier phase reports; their results remain historical evidence.

## Current state

- **32 issues: 27 open, 5 closed** — #3, #21, #25, #26 and #28. This review found no additional issue whose full acceptance is complete.
- **Latest validated app:** source `dbe04cf`, [PR #41](https://github.com/CaptiveON/augmentmereality/pull/41), whose merge record resolves the exact main merge commit. Subsequent ledger documentation does not constitute another app build.
- **Last recorded phone installation:** signed Release `1b433e7` (phase 3). Phase 4 and issue 11 were not installed. These are archived receipts, not a fresh query of the phone.
- **#11 phone-free implementation is complete; next implementation: #12**, general live foreground depth and arbitration with static occlusion. Its code and synthetic ordering tests can be built without the phone. #11 remains open for physical alignment, buffer pressure and thermal acceptance.
- **Hosted CI is deferred** at the owner’s request because Actions credits are exhausted. Keep workflow/check definitions intact and use local validation. No hosted CI pass is claimed.
- Physical thermal and visual acceptance stays last. Simulator tests and successful installation do not establish that overheating is solved.

The [machine-readable build history](build-history.json) and [issue snapshot](issue-status.json)
contain full commits, evidence paths and every issue’s implemented/remaining scope. GitHub
[#1](https://github.com/CaptiveON/augmentmereality/issues/1) is the live umbrella tracker.

## Verified build history

This ledger covers every verified repair candidate since September 29. Earlier baseline
and release builds are indexed below. It does not invent a delivered build for each failed
compiler attempt; intermediate failures and limitations remain in the phase evidence.

All six candidates passed local Debug and unsigned Release compilation using Xcode 26.6
(17F113), SDK 26.5. The columns below are test **passes**; minimum-lane skips are explicit.
Opt-in native Firebase emulator tests skipped on minimum iOS passed in the current lane.
TSan counts cover selected suites and do not prove every physical renderer interleaving.

| Source / merged PR | Work | Current / minimum iOS | TSan | Phone delivery |
| --- | --- | --- | --- | --- |
| [`243eed4`](IMPLEMENTATION-STATUS-2026-09-29.md) / [#36](https://github.com/CaptiveON/augmentmereality/pull/36) | Recovery, fixed scale, geodesic/frame math, bounded preparation, transit freshness, storage incidents and unsupported counters | 246 / 245 (1 skipped) | Not recorded | [Installed](implementation-evidence/build-deliveries/243eed4.json) |
| [`eb63a99`](IMPLEMENTATION-STATUS-2026-09-30.md) / [#36](https://github.com/CaptiveON/augmentmereality/pull/36) | Scene budgets, owned streetscape snapshots, render leases and AR executor boundaries | 267 / 266 (1 skipped) | 30 | [Installed](implementation-evidence/build-deliveries/eb63a99.json) |
| [`684f6b4`](IMPLEMENTATION-STATUS-2026-09-30-PHASE2.md) / [#37](https://github.com/CaptiveON/augmentmereality/pull/37) | Latest-wins VPS corrections and checked storage ownership | 283 / 282 (1 skipped) | 105 | [Installed](implementation-evidence/build-deliveries/684f6b4.json) |
| [`1b433e7`](IMPLEMENTATION-STATUS-2026-09-30-PHASE3.md) / [#38](https://github.com/CaptiveON/augmentmereality/pull/38) | Placement provenance and owner/recipient permissions | 318 / 317 (1 skipped) | 128 | [Installed](implementation-evidence/build-deliveries/1b433e7.json) |
| [`0210d6a`](IMPLEMENTATION-STATUS-2026-09-30-PHASE4.md) / [#39](https://github.com/CaptiveON/augmentmereality/pull/39) | Vertical support, camera readiness and bounded owner-library paging | 366 / 364 (2 skipped) | 174 | Not installed |
| [`dbe04cf`](IMPLEMENTATION-STATUS-2026-09-30-ISSUE11.md) / [#41](https://github.com/CaptiveON/augmentmereality/pull/41) | Capture/depth contracts, bounded render association, owned inference copies and GPU matte lifetime | 392 / 390 (2 skipped) | 200 | Not installed |

`eb63a99` retained 19 Release storage warnings and 19 Swift 6 SIL errors.
`684f6b4` resolved those; phase 2 onward records zero app diagnostics in the complete
Release and whole-app Swift 6 SIL checks. Production language mode remains Swift 5.
Phase 4’s Debug test-host compile was incremental; Release compiled all 16 checked
ownership boundaries. Do not describe the incremental Debug log as a full compile gate.

Phase 4 additionally passed 8 rules drift, 60 current-rules and 6 historical-rules tests,
and root/unsupported-camera launch checks on iOS 26.5 and 17.0.1. Its native paging
test verifies that a pending local deletion cannot falsely complete an owner sweep.
See the [phase 4 evidence](implementation-evidence/2026-09-30-phase4/verification.json).

Issue 11 adds 26 contract/real-Metal regressions. Both simulator root and
unsupported-camera smoke checks passed, with all four screenshots inspected.
Release compiled all 20 required ownership boundaries; whole-app Swift 6 SIL
had zero diagnostics. TSan runtime linkage was confirmed with no reported races.
The [issue 11 evidence](implementation-evidence/2026-09-30-issue11/verification.json)
records the exact 120-file source fingerprint, checks and remaining phone gates.
RealityKit association remains approximate and GAR semantic timing remains opaque.

All four recorded phone deliveries use app version `0.9.0`, bundle build `1`; those
values alone do not identify a revision. The sanitized receipts preserve source commit,
embedded source hash, executable SHA-256 and installation outcome. Their manifest
source hashes include a different source inventory from the app/test validation
fingerprints; compare each within its own schema. Device identifiers, signing/installation
identifiers and configuration contents are excluded. No delivery receipt is a field pass.

Earlier records:

- [September 8 AR baseline](AR-BASELINE-2026-09-08.md), with [U](ar-baseline-evidence/2026-09-08/U-build-manifest.json), [I](ar-baseline-evidence/2026-09-08/I-build-manifest.json) and [Q](ar-baseline-evidence/2026-09-08/Q-build-manifest.json) build manifests.
- [September 11 perception policy and interrupted physical validation](AR-PERCEPTION-POLICY-2026-09-11.md), with [Release manifest](ar-perception-evidence/2026-09-11/release-build-manifest.json). Later recovery fixes do not retroactively turn that physical run into a pass.
- [Firestore release runbook](../web/FIRESTORE-RELEASE.md), [September 8 client build](../web/rules-releases/2026-09-08-after-rollout/client-build.json), and [September 29 read-only live export](../web/rules-releases/2026-09-29-readonly/release.json). Controlled live/client acceptance remains under #2.

## Issue-by-issue remaining work

“Implemented” below means the recorded code and local tests exist. Issues retain their
original acceptance requirements; an open issue may need code, service evidence, a
product decision, physical testing, or several of these. Dependencies can have usable
implemented contracts while their independent field-acceptance gate remains open.

| Issue / state | Built so far | Work possible without phone | Remaining acceptance / reason to keep open |
| --- | --- | --- | --- |
| [#1](https://github.com/CaptiveON/augmentmereality/issues/1) — Umbrella | Five issues closed; six verified app candidates indexed. Issue 11 phone-free implementation verified; physical acceptance remains open. | Implement #12 next using the capture contract; coordinate dependent #13/#14 and #18 work and preserve build/acceptance evidence. | All release and physical gates on child issues; umbrella remains open. |
| [#2](https://github.com/CaptiveON/augmentmereality/issues/2) — Service/client acceptance | Reviewed v3 rules deployed September 8; September 29 read-only export matched the reviewed source. | Complete next-day live rules/access checks and reconcile the release runbook; local emulator/client regressions can support but cannot replace the physical offline trial. | Repeat true-offline receive and deletion/relaunch on a physical phone after cellular fallback invalidated the prior result; controlled live service acceptance also remains open. |
| [#3](https://github.com/CaptiveON/augmentmereality/issues/3) — Closed | Baseline instrumentation and measured baseline recorded. | None within this issue. | Later fixes still need fresh final physical acceptance under #32. |
| [#4](https://github.com/CaptiveON/augmentmereality/issues/4) — Implemented; field acceptance open | Unified perception demand, prompt critical/hidden admission controls and room recovery after lost relocalization. | Maintain the existing policy and recovery regressions; react to field failures. | Repeat background/recovery, hidden/critical producer traces and sustained Release thermal/frame pacing. Prior stopped/warmth run is not a pass. |
| [#5](https://github.com/CaptiveON/augmentmereality/issues/5) — Implemented; field acceptance open | Fixed authored world scale and grounding footprint; asset replacement preserves physical size. | Existing scale/edit/projection regressions are available. | Measured 5–60 m approach/retreat/orbit, scale edit/reopen and second-device size/contact. |
| [#6](https://github.com/CaptiveON/augmentmereality/issues/6) — Implemented; field acceptance open | Independent WGS84 fixtures, checked conversion/write-back and common-frame drift comparison. | Keep geodesic and rotated-basis regressions passing. | Heading walks, actual tracking displacement and reopened geographic placement checks. |
| [#7](https://github.com/CaptiveON/augmentmereality/issues/7) — Implemented; field acceptance open | Latest-wins versioned corrections, edit/anchor invalidation, placement provenance and uncertainty-gated geographic save. | Maintain stale-result, edit and provenance coverage. | Physical correction/glide behavior, degraded localization and second-device/reopen placement comparison. |
| [#8](https://github.com/CaptiveON/augmentmereality/issues/8) — Mixed: compiler work verified; field/migration open | AR/SDK/render ownership, bounded GPU leases, checked storage isolation; full Swift 6 SIL compile passes. Issue 11 adds explicit source-buffer leases and single-command matte history ordering. | Review remaining migration scope and production/test-target language-mode rollout. Production remains Swift 5; single-command GPU history ordering is implemented. | Physical callback/Metal teardown under overlapping work, memory/frame pacing and thermal validation. |
| [#9](https://github.com/CaptiveON/augmentmereality/issues/9) — Implemented policies; profiling open | Bounded decoder/cache, scene content admission, owned mesh snapshots and localization submission limits; bounded inference copy pools with saturation fallback. | Tune only from measured decoded/GPU costs; current source-file/work budgets are proxies. | Heavy assets/dense scenes, decoded RAM/GPU residency, memory pressure, startup and sustained heat/frame pacing. |
| [#10](https://github.com/CaptiveON/augmentmereality/issues/10) — Implemented; field acceptance open | Persisted vertical reference, WGS84 datum gates, measured bounded support, atomic pose/contact-cue updates and unresolved fallback. | Keep codec, invalid-metadata, support and anchor-intent regressions passing. | Slopes, steps, multiple floors/roofs and second-device/reopen heights. |
| [#11](https://github.com/CaptiveON/augmentmereality/issues/11) — Implemented; field acceptance open | Immutable capture/session/stream/calibration and raster contracts, explicit units/confidence/ownership, bounded approximate render association and rejection, owned inference copies, GPU completion leases and 26 synthetic regressions. | Maintain contract and real Metal regression coverage; dependent #12/#13/#14 and #18 implementation can consume the new contract. | Target-phone capture/render/semantic/depth alignment during pans, viewport/orientation changes, resume and thermal changes; delayed moving foreground; real buffer pressure/Metal scheduling and sustained heat/frame pacing. Exact render provenance and GAR internal semantic timing remain unavailable. |
| [#12](https://github.com/CaptiveON/augmentmereality/issues/12) — Next phone-free implementation | Foreground/static-mesh arbitration remains open. | Use the implemented #11 contract for general live foreground depth and arbitration with every static occlusion stage; add synthetic ordering and fallback tests. Physical dependency acceptance remains separate. | Real hands/people/vehicles and moving/static edge occlusion on the final device build. |
| [#13](https://github.com/CaptiveON/augmentmereality/issues/13) — Implementation pending | Capture contract distinguishes confidence meanings from foreground coverage and resets rejected/failed history; full motion-aware history/reprojection and confidence-versus-coverage fusion remain open. | Use #11 capture contract and dependent occlusion work to implement reset/reprojection/history and distinct confidence versus edge coverage. | Fast pans, moving foreground, disocclusion, ghosting and thermal/lifecycle transitions. |
| [#14](https://github.com/CaptiveON/augmentmereality/issues/14) — Implementation pending | Robust relative-to-metric fit remains open. | Use the implemented #11 sample contract to build confidence-qualified robust positive-disparity fitting and deterministic outlier/degenerate fixtures. Current metric support remains below 5 m. | Real metric-depth agreement, failure behavior and edge ordering across supported ranges. |
| [#15](https://github.com/CaptiveON/augmentmereality/issues/15) — Implementation and asset work pending | Preparation budgets exist; representative asset optimization/physical behavior not complete. | Audit/optimize representative assets and define behavior/geometry/animation budgets with automated checks. | Device appearance, animation behavior, decoded residency and sustained performance comparison. |
| [#16](https://github.com/CaptiveON/augmentmereality/issues/16) — Implementation and appearance work pending | Contact-cue relocation fixes are present; full lighting/color/shadow work remains. | Implement lighting/reflection/contact-shadow/color policies and bounded asset behavior. | Compare real lighting/materials, camera color and contact across representative scenes. |
| [#17](https://github.com/CaptiveON/augmentmereality/issues/17) — Implemented; field acceptance open | Epoch/selection readiness with distinct capture, asset and hero scene-update proxy; honest wait/retry/recovery and stale liveness revocation. | Maintain readiness, failure, epoch and bounds-sampling regressions. | Actually presented hero on cold/cached opens, interruption/resume, return-to-camera and usable controls. A scene-update proxy is not presented pixels. |
| [#18](https://github.com/CaptiveON/augmentmereality/issues/18) — Draft only; integration pending | Registry/lifecycle draft archived outside app/test targets; parser check only, no Xcode build or integration. | The #11 code dependency is available. Integrate the archived draft by migrating all seven maps together and testing actual manager/holder transitions; fix idempotent cleanup and stale completions. Coordinate ownership if #12 touches the manager. | Ground snap, two-finger edit, late VPS correction and return-to-camera field cases. |
| [#19](https://github.com/CaptiveON/augmentmereality/issues/19) — Local repair verified; CI/device gates open | Minimum-iOS loader repair and minimum/current lanes; both simulator roots and unsupported-camera launches pass. | Retain local minimum/current checks; resume hosted matrix when credits return. No hosted pass is claimed. | Physical minimum-supported OS, clean first launch and signed Release launch acceptance. |
| [#20](https://github.com/CaptiveON/augmentmereality/issues/20) — Release implementation pending | Asset rights/catalog release gate remains open. | Verify rights for each shipping asset, remove unverified assets, record licenses and implement local/CI catalog checks. | Rights evidence and final shipping catalog; no phone required for the rights/gate implementation. |
| [#21](https://github.com/CaptiveON/augmentmereality/issues/21) — Closed | Owned/received UI and direct-command/storage authorization, filtered deletion and legacy ownership covered. | None within the resolved ownership scope. | Separate live rollout/account lifecycle issues remain open. |
| [#22](https://github.com/CaptiveON/augmentmereality/issues/22) — Release implementation pending | Moderation and authoritative reaction cleanup remain open. | Implement report/block and durable cleanup with emulator/service tests. | Deploy and verify authoritative behavior, retries and orphan cleanup; service access required. |
| [#23](https://github.com/CaptiveON/augmentmereality/issues/23) — Release implementation/product decision pending | Account deletion and recoverable identity remain open. | Implement verifiable deletion/retry and settle recoverable identity versus an explicit device-bound anonymous policy; add safe linking/migration only if that option is chosen. | Controlled service/end-to-end account lifecycle acceptance; product/service decisions may be needed. |
| [#24](https://github.com/CaptiveON/augmentmereality/issues/24) — Release inventory/declarations pending | Verified data inventory and privacy/sharing copy remain open. | Trace actual SDK/data behavior, inventory retention/recipients and update declarations/copy. | Confirm final service configuration and distribution declarations; phone is not needed for the inventory work. |
| [#25](https://github.com/CaptiveON/augmentmereality/issues/25) — Closed | Durable incident acknowledgement, unreadable-byte preservation, unknown/count-only incidents and warning precedence covered. | None within the resolved storage-incident scope. | Broader release acceptance remains tracked separately. |
| [#26](https://github.com/CaptiveON/augmentmereality/issues/26) — Closed | Explicit owner-library API, 64-document paging, immutable cursor, pending-owner/outbox and account guards; native emulator coverage. | None within the resolved bounded owner-query scope. | Loopback timings do not claim production latency; separate live rollout gates remain open. |
| [#27](https://github.com/CaptiveON/augmentmereality/issues/27) — Release implementation and service work pending | Invite/install/access-revocation flow remains open. | Implement link routing, fallback/AASA/hosting behavior and truthful revocation; add route/authorization tests. | Installed/uninstalled end-to-end links, hosting verification and device access/revocation behavior. |
| [#28](https://github.com/CaptiveON/augmentmereality/issues/28) — Closed via supported alternative | Unsupported delivery/reaction totals removed from Profile; legacy fields remain compatible. | No aggregate producer required while unsupported totals stay hidden. | Any future authoritative totals need their own producer/security/reconciliation work. |
| [#29](https://github.com/CaptiveON/augmentmereality/issues/29) — Implemented; field acceptance open | Filtered transit, timestamped/fresh location and heading, explicit unknown/stale motion and provisional magnetic guidance. | Keep noise, stale fix, recovery and heading-provenance regressions passing. | Real passenger route, tunnel/recovery, heading source transitions and measured latency/uncertainty. |
| [#30](https://github.com/CaptiveON/augmentmereality/issues/30) — Experiment deferred | No replacement SDK/model has been selected. | Prepare comparison criteria/fixtures after dependencies #3, #11–#13 and #15; #14 is related depth-fit work, not a listed prerequisite. Do not migrate from assumptions. | Native NSDK/compact metric depth comparison on target phone with quality/cost/thermal measurements. |
| [#31](https://github.com/CaptiveON/augmentmereality/issues/31) — Experiment deferred | Prepared-site localization not evaluated. | Prepare candidate/site comparison after baseline placement work. | Site capture/provider access and repeatable real-world placement comparisons; phone/site work required. |
| [#32](https://github.com/CaptiveON/augmentmereality/issues/32) — Final release gate open | Local builds/tests and older physical baselines exist; final app acceptance is incomplete. | Assemble final artifact/evidence checklist after implementation and service gates. | Final signed iPhone build: thermal/frame pacing, startup, placement, occlusion, interactions and release gates. Overheating is not certified solved. |

## Next batch: #12 without phone participation

The #11 capture/sample contract is implemented and locally verified. Its physical
acceptance remains open; dependent code work can use the contract without claiming
those field gates passed. #12 is the next engine implementation, followed by its
#13 history work; #14's robust fit can use the same sample contract independently
where file ownership allows.

1. Trace every static occlusion stage, including RealityKit mesh materials before
   postprocessing, and define how fresh live depth takes precedence or falls back.
2. Admit general foreground depth independently of person semantics and virtual
   object range, within actual sensor/confidence support and bounded demand policy.
3. Test asymmetric foreground/virtual depth ordering, stale meshes, missing or
   rejected live depth, source transitions and unsupported coverage using production
   policies and real shader fixtures where applicable.
4. Run the applicable local minimum/current, Release, ownership and sanitizer gates;
   preserve the exact source and evidence. Keep real hands, people, vehicles,
   foliage/glass edges, frame pacing and heat acceptance for the phone.
5. #18 integration can now consume #11's code contract. Avoid overlapping manager
   edits with #12 unless explicit file ownership isolates the work.

The [#18 draft handoff](drafts/placed-object-state/HANDOFF.md) and source text are archived
outside the app/test source trees. They have not been integrated or Xcode-built/tested.
The known repeated VPS invalidation after unload/remove must be resolved before use.

Release-track work such as #20’s asset rights/catalog gate can proceed independently
if it does not overlap the engine batch. #22–#24 and #27 also contain phone-free work,
but service configuration or product decisions can be separate blockers. #30/#31 need
a repaired baseline and measured device/site comparisons before choosing alternatives.

## Update protocol for every subsequent batch

- Preserve the three pre-existing untracked user documents; do not stage or edit them as part of unrelated work: `AR-TECHNOLOGY-RESEARCH-2026-09-07.md`, `IMPLEMENTATION-PLAN-2026-09-08.md`, `TECHNICAL-AUDIT-2026-09-07.md`.
- For each verified candidate, append source commit/fingerprint, toolchain, configuration, test counts/skips/failures, compile diagnostics, evidence paths and PR/merge commit to `build-history.json` and this table. Keep failures and limitations in the phase record; do not overwrite historical claims with later results.
- For each installation, preserve a sanitized receipt with executable/source identity and outcome. Update “last recorded phone install” only from actual installation evidence. Record physical measurements separately.
- Update `issue-status.json`, this table and the affected GitHub issue body with implemented work, remaining code/service/phone gates and durable links. Close only when the issue’s acceptance is satisfied; record closure evidence and update counts.
- Put compact verification summaries, hashes and useful unfinished drafts in the repository. `/tmp` logs may expire and must never be the sole handoff. The compact summaries here are not substitutes for raw logs if a future investigation needs to reproduce a result.
- Keep current local source state distinct from the latest validated artifact. A documentation-only handoff does not require another app build or phone install.
- Use separate file ownership for parallel work; the owner’s requested agent setting is GPT-6 Sol with ultra reasoning.
