# Implementation order and evidence — 29 September 2026

This working record reconciles the live GitHub backlog with the code at
`18f27d3`. The September 7 audit is historical: issue #3 instrumentation and
most issue #4 workload policy already exist. The user authorized implementation
without phone participation. Simulator results are not physical thermal or
visual evidence. Three GPT-6 Sol agents with ultra reasoning handle separate
file groups; the coordinating agent integrates and verifies the combined build.

## Priority and dependency order

| Order | Issues | Work and reason |
|---|---|---|
| 0 | #2 | Verify the deployed authorization policy first. Read-only verification on September 29 confirms the active source exactly matches reviewed v3 (`cd613a6…457b6`). The September 8 deployment remains active. No backend writes or deployment were needed. Device/client acceptance remains separate. |
| 1 | #4, #5, #6, #9, #29 | Repair the recorded background-recovery loss, fixed physical sizing, common-frame/geodesic placement, stale motion input, and avoidable preparation/localization work. These directly affect reliable camera use and unnecessary cost. |
| 1, parallel | #25, #28 | Preserve unreadable-data evidence and durable acknowledgement; show storage problems ahead of sync progress. Hide counters without an authoritative producer. These have no AR dependency. |
| 2 | #7, #8, #10, #17, #18, #19 | Latest-wins VPS corrections and placement uncertainty, safe concurrency, vertical references/support, readiness/recovery, consolidated placed-object state, minimum/current OS launch. Keep physical acceptance distinct from executable desk checks. |
| 3 | #11, #12, #13, #14 | Define synchronized capture/depth contracts, trusted live foreground ordering, motion-aware history, then robust confidence-qualified depth fitting. Do not widen the calibrated depth band to mask missing coverage. |
| 4 | #15, #16 | Measured hero-asset budgets, explicit content behavior, lighting/contact shadows and camera-color comparison. Implement content rules and preparation independently; reserve appearance judgments for device evidence. |
| 2, parallel release track | #20, #21, #22, #23, #24, #26, #27 | Asset rights/catalog gating, owner/recipient permissions, moderation and durable deletion, account lifecycle/privacy, bounded owner reads, invite/install/revocation truth. These need independent implementation and some service/product configuration; they are not automatically phone-blocked. |
| Last: measured experiments | #30, #31 | Alternative depth providers and prepared-site localization require a corrected baseline and real-world comparisons before adoption. No vendor or model migration is assumed. |
| Last: physical release acceptance | #32 and field criteria above | Sustained Release heat/presentation measurements, real depth/occlusion, heading walks, second-device placement, minimum-iOS physical launch and final field regressions. These cannot be certified on a simulator. |

Issue #1 remains the umbrella tracker. No issue is closed merely because its
implementation compiles. Remaining implementation work is not described as
phone-blocked just because eventual visual/thermal acceptance needs a phone.

## Current batch

The following changes are implemented locally and covered by the final checks.
The source audit/research/plan files that were already untracked at the start of
this session remain untouched. GitHub issues remain open where their acceptance
criteria include missing physical or release evidence.

| Issue | Result in this batch | Remaining scope |
|---|---|---|
| #4 | Room content survives the cold fallback after failed background relocalization; restoration waits for a fresh normal frame. | Real-world registration and sustained thermal acceptance. Recovery after a lost world map is approximate. |
| #5 | Physical content/grounding footprint no longer grow with viewing distance; authored edits and asset replacement retain physical size. | Measured approach/retreat/orbit on a phone. |
| #6 | WGS84 checked placement and write-back; drift compares geographic and AR displacement using the saved heading basis. | Heading-walk/device accuracy checks. |
| #9 | Demand-driven bounded decoder/cache, hero priority, stalled-load deadline, frame deduplication, global mesh-work slots, diagnostic errors. | Total live-scene/geometry budget, remaining SDK ownership and device profiling. |
| #19 | Reproduced and repaired the iOS 17 loader crash; explicit minimum/current CI lanes and launch markers. | Remote CI/download availability, clean first launch, Release launch and physical minimum-OS evidence. |
| #25 | Durable incident acknowledgement and preserved unreadable bytes; count-only/unknown incidents; warning priority and failure reporting. | Broader release review; automated storage regressions pass. |
| #28 | Removed unsupported delivery/reaction totals from Profile; compatible legacy fields retained. | An authoritative aggregate producer is deliberately deferred. |
| #29 | Fresh timestamped location/heading/speed, explicit unknown motion, filtered transit with stale/reacquiring suppression, provisional magnetic guidance. | Real passenger routes and heading-source transitions. |

Related narrow repairs consume each VPS heading sample once (#7) and refresh
the grounding disc's local height on relocation (#16). These do not complete
the larger correction-provenance, surface-support or lighting issues.

### Final verification

The [machine-readable verification record](implementation-evidence/2026-09-29/verification.json)
and [source fingerprint](implementation-evidence/2026-09-29/tested-source.json)
identify the tested uncommitted source tree based on `18f27d3`.

| Check | Result |
|---|---|
| iOS 26.5, Xcode 26.6 / SDK 26.5 | **246 passed, 0 failed**, including the native Firebase emulator contract. |
| iOS 17.0.1, same toolchain | **245 passed, 0 failed, 1 skipped**. The native emulator opt-in test ran in the current-OS lane instead. |
| Debug simulator / unsigned Release iPhone build | Both passed on final source; no install to a phone. |
| Launch checks, both runtimes | Root and unsupported-camera appearance markers passed. System permission dialogs persisted despite CLI revocation; they were subsequently declined through Simulator UI. Current-OS Home and unsupported-camera screens were visually verified without the dialog. |
| Other checks | 9 rules-verifier tests, 6 baseline parser tests, 3 simulator-selector tests, both drift locks and `git diff --check` passed. |

Real Firebase integration tests were excluded; tests used a disposable local
emulator and a host without real service configuration. Full `.xcresult` and
build logs are retained under `/tmp/amr-sep29`; summaries and log hashes are
checked into the evidence directory. No remote CI pass is claimed. Existing
Swift concurrency migration warnings remain; this is not a completed #8 audit.

### Resource policy

Whole-catalog delayed preloading is removed. Asset demand comes from the current
scene/selected content, with one decoder, at most eight queued identifiers, and
an LRU cache of at most three templates / 24 MiB of source-file cost. The source
cost is a catalog proxy, **not a measured decoded-memory ceiling**. A larger
on-demand template is exposed only during synchronous clone delivery and then
released. Existing live clones survive eviction and memory pressure. Hiding the
camera, critical thermal state and critical-recovery dwell close admission;
irrelevant late results cannot publish. Already-running SDK decode work has a
bounded publisher deadline; this is not a promise of instantaneous SDK teardown.

GAR receives each monotonic capture timestamp at most once per SDK session.
The existing convergence/maintenance cadence is preserved. Streetscape jobs
share eight total outstanding slots across updates and lifecycle invalidation;
obsolete jobs release their slot only when they finish. Runtime update,
transform and semantic-configuration failures retain rate-limited domain/code
diagnostics. This does not complete the active-scene budget or SDK ownership
work in #8/#9.

### Security evidence

The [fresh release export](../web/rules-releases/2026-09-29-readonly/release.json)
records the exact active ruleset, source hash and repeated release-identity
check. It does not read user documents. App Check's API omitted an enforcement
mode, so its enforcement is still unknown. Existing authorization behavior and
client distribution gates remain in [the release runbook](../web/FIRESTORE-RELEASE.md).

## Phone-dependent checks, intentionally last

- Re-run the recorded background/relocalization scenario and confirm room
  content returns with an honest recovered placement, including multiple drops.
- Measure first 0–10 seconds and a 15-minute Release session with controlled
  brightness, asset and starting thermal state; distinguish warmth from iOS
  thermal state. Preserve the existing FPS/p95/ten-minute thermal targets.
- Approach, retreat and orbit fixed-size content; validate contact, heading,
  transit transitions, hands/foreground depth and fast pans on real hardware.
- Verify shared placement uncertainty on another device and launch on physical
  minimum-supported iOS before claiming device compatibility.
- Repeat the required ground-snap, held-finger editing and return-to-camera
  scenarios in `FIELDTESTS.md` against the final tested revision.

There is no claim yet that overheating is solved or that the app is ready for
production release. The batch removes identifiable faults and records the
remaining implementation and measurement gates explicitly.
