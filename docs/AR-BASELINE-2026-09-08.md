# Physical AR baseline — September 8, 2026

Issue [#3](https://github.com/CaptiveON/augmentmereality/issues/3), implementation
[PR #35](https://github.com/CaptiveON/augmentmereality/pull/35),
[measurement protocol](AR-BASELINE-PROTOCOL.md).

**Validation in progress.** Both completed traces record thermal failure. The
recorder-disabled implementation run began cool/Nominal and reached Serious
after 3 minutes 6 seconds, with the text visibly present. The unchanged build
began Fair and had an operator-reported content-visibility failure. Instrumentation
overhead and the remaining physical readiness scenarios are pending; no heat or
visual improvement is claimed.

## Exact builds and retained evidence

| Class | Source SHA | Executable SHA-256 |
| --- | --- | --- |
| U, unchanged preimplementation checkout | `a4aeff7f9d1b6fd4e3cf9a57bd88eecda192df35` | `095dcf54650da57be5feeb4f9c68f5cd60e2a7c4e57dd2876e4201b4540709a8` |
| I-off / I-on, same instrumented binary | `d5d7a7f3c5693e6b17b7d04774c8db353a4ffa41` | `ae7da1a2471b4ef0c4f0e4910282d034bf9b6ea4d4ce2cca1a329492a2c78d3a` |

Both are signed Release builds from clean app-source trees. U is the checkout
immediately before implementation, distinct from issue #3's historical source
reference `9612f8211547d358f2511be5ccd632f0580dce02`. I embeds verified source
commit/hash, clean status and Release configuration. U has no embedded issue #3
metadata; its preserved build/installation manifests identify the executable.
The experiment flags are absent for default-workload comparisons.
Both archived apps identify version **0.9.0 (1)**, Xcode **26.6 / 17F113**, SDK
**iphoneos26.5 / 23F81a**, and deployment target 17.0. Device validation here is
on iOS 26.6; this is not minimum-OS validation. `artifact-info.json` preserves
these values read directly from the archived apps' Info.plists.

The durable local artifact root is
`/Users/captiveon/Documents/AR-Baselines/issue-3-2026-09-08/`.
`builds/U/` and `builds/I/` retain each app, dSYM and source/asset/build manifest.
These app bundles contain the existing service configuration and remain local.
Measurement artifacts are retained under `runs/`, with the original acquisition
paths under `/tmp/augmentme-issue3-evidence/` also recorded in generated summaries.
The [checked-in evidence](ar-baseline-evidence/2026-09-08/) includes the U build
manifest, thermal intervals, CPU summary/extraction script and operator conditions.

## U-steady: observed failure, not a cool-start acceptance run

Device: iPhone 15 Pro Max (iPhone16,2), iOS 26.6 (23G71). Time Profiler attached
wirelessly to an already launched Release process, PID 9552. Trace start was
**20:15:26.112 UTC**, end **20:31:28.082 UTC**, duration **961.970 seconds**.
Instruments 16.0 (17F113), deferred Time Profiler, 1 ms CPU sampling, no waiting
thread sampling; the template also records device thermal state. This was an
external profiling run, not an unprofiled thermal measurement or a cold launch.

The operator confirmed the phone stayed **unplugged** and **screen recording was
off throughout**. Xcode had copied device symbols before the run. Cool/nominal
state was not reverified afterward: the first recorded state was already Fair.
Ambient temperature, case, brightness, battery percentage, Low Power Mode and
auto-brightness were not measured for U. They must not be inferred from later runs.

The requested scene was Playground camera, initially empty, followed by one
Playground → 3D text placement (`ROOM TEST`, default style/scale, no USDZ asset).
The source-defined fixture uses system heavy font size 0.6, extrusion depth 0.12,
center alignment, scale 1 and color `#32ADE6`. Actual placement uses a center
raycast or the existing 2.5 m fallback; which path ran in U is unmeasured.
The operator confirmed placement but reported **the text was not visible**.
Actual camera-intent/placement timestamps and placement distance were not captured
by U. The trace's first ten seconds therefore cannot be labeled camera startup.
The operator's original heat report concerned every object and camera opening,
not one identified heavy asset. Castle remains a separately named test variant.

| Relative to trace start | Instruments device thermal state | Operator observation |
| --- | --- | --- |
| 0–205.590 s | Fair | Initially cool: unverified |
| Around the first response, logged at 20:18:41 UTC | Fair at that logged timestamp | Warm; exact observation time uncertain |
| 205.590–961.970 s | Serious | No continuous manual warmth scale |
| 10 min | Serious | Unmeasured at the exact milestone |
| 15 min | Serious | Unmeasured at the exact milestone |
| After recording ended | Not measured by the ended trace | Very hot; text had not appeared |

The Instruments state track is OS device-state evidence, distinct from both
operator-perceived warmth and an app `ProcessInfo` export (unavailable in U).
Serious began at **20:18:51.702 UTC**, 3 minutes 25.590 seconds into the trace.
No Critical interval appears in this trace. The existing ten-minute thermal
target fails for this observed run, subject to its initially Fair condition.

![Time Profiler CPU samples and device thermal intervals for U](media/AR-BASELINE-U-2026-09-08.png)

## U CPU samples and limits

The Time Profiler export contains **776,760 Running samples**, each weighted
1 ms, from +0.520 s to +961.969 s. Total sampled CPU weight is **776.760 s** over
961.970 s of elapsed trace time: **80.747% of one CPU core**, summed across app
threads. Main-thread weight is 78.722 s (8.183% of one core over the trace).
This is a sampling estimate, not scheduler-accounted utilization or energy.

The largest named leaf was RealityKit/CoreRE PhysX integer sorting (90.229 s
sample weight); other prominent leaves include PhysX spatial sorting and edge
construction. Stacks included CoreRE (267.439 s), RealityFusion (159.873 s),
Recon3D (135.788 s) and AppleCV3D (127.070 s). These are **inclusive, overlapping**
binary totals and must not be added. Some frames remain addresses/deduplicated
symbols. The evidence motivates reconstruction/physics isolation; it does not
establish that one subsystem caused the measured heat.

Actual presentation FPS/p95/p99, GPU execution, resident-memory peak, model
execution-device attribution, camera sample age and truthful hero readiness are
**unmeasured in U**: this template/unchanged build did not export those streams.
The 30 presented FPS and 40 ms presentation-p95 targets remain unmeasured.
No CPU sample count is used as a render-frame count.

| Evidence | Path beneath `runs/` |
| --- | --- |
| Original, unmodified trace | `U-steady.trace` |
| Capture command outcome and table definitions | `U-steady.log`, `U-toc.xml` |
| Complete thermal intervals | `U-device-thermal-state-intervals.xml` |
| CPU samples and derived windows, symbolicated with the archived U dSYM | `U-symbolicated-time-profile.xml`, `U-symbolicated-cpu-summary.json` |
| Reproducible CPU extraction and time-unit definition | `extract-time-profile.py` |
| Operator replies and uncertainty | `operator-observations.json` |
| Original build/installation provenance | `U-build-manifest.json`, `U-install.json`, `U-launch.json` |

The earlier `U-trace.log` attempt failed while Instruments was preparing the
device and supplies no measurement. System-log collection required unavailable
root privileges; its failure logs are not a substitute for a log archive.

## I-off: cool/Nominal start, visible text, sustained thermal failure

The same phone ran the archived I binary, recorder and experiment flags absent,
using the same wireless Time Profiler template. Instruments launched the process
(PID 9727); recording covered **20:39:08.889–20:55:10.318 UTC**, **961.429 s**.
The operator confirmed cool, app closed and unplugged before launch. The first
Instruments thermal interval independently reports **Nominal**.

The operator was asked to keep brightness/room setup unchanged, open Playground
camera, wait ten seconds, and place 3D text once. The text appeared and remained
visible in the near-ten-minute and end replies. Observed warmth progressed from
cool to hot, then very hot at those two later replies. Reply timestamps are
retained separately from requested checkpoint times; they are not exact event
timestamps. Camera intent, actual placement distance, brightness and battery
remain unmeasured in I-off because the recorder is disabled. The app process was
cold; OS/asset/shader caches were retained or unknown, not claimed uncached.

| Relative to I-off trace start | Instruments device thermal state |
| --- | --- |
| 0–86.123 s | Nominal |
| 86.123–186.120 s | Fair |
| 186.120–961.429 s | Serious |
| 10 min / 15 min | Serious / Serious |

The no-serious-state target at ten minutes **fails**, and Serious persists through
the extended observation. Actual presentation/capture FPS, frame p95/p99, GPU
execution and memory remain unmeasured by this external template. Recorder
overhead is pending I-on; the thermal failure already occurs with it disabled.
U versus I-off is not a controlled improvement comparison because starting state,
process-launch method and observed content visibility differ.

I-off contains **815,999 Running CPU samples**, 815.999 s of sample weight over
961.429 s: **84.874% of one core**, summed across process threads. A sampled
`placeRoomDrop(content:assetName:)` stack appears at +41.214 s, followed by
920.215 s of trace coverage. That establishes sampled placement-path activity,
not the exact button/camera-intent time or a presented-hero timestamp. The operator
separately confirmed the text remained visible.

Artifacts: `runs/I-off.trace`, `I-off-toc.xml`,
`I-off-device-thermal-state-intervals.xml`, `I-off-symbolicated.trace`,
`I-off-symbolicated-time-profile.xml`, `I-off-trace.log`, `I-install.json` and
the shared `operator-observations.json`/`capture-commands.json`.

## Implementation checks and remaining device work

39 focused simulator tests passed for bounded statistics, epochs, fresh frames,
placeholder handling, workload policy and video-format policy. After adding the
explicit missing-resource fixture, all four experiment tests passed, including
the new fixture/default-isolation regression (40 distinct selected tests in total).
Six Python report/build-provenance tests passed. Signed Release compilation and
embedded provenance verification passed. These results establish implementation
behavior, not physical presentation or thermal success.

[GitHub CI run 34275146718](https://github.com/CaptiveON/augmentmereality/actions/runs/34275146718)
also passed **179 local simulator tests**, including the native Firestore emulator
regression, plus the report/drift and Firestore rules jobs. Raw iOS CI output is
retained in `runs/CI-ios-tests.log`; CI retains the original test artifacts.

Still pending: cool-start U repetition, matched I-off/I-on measurement,
instrumented sustained export, physical cold/cached/delayed/missing asset and
background/recovery scenarios with separate quality video, and isolated workload
matrix results. Missing scenarios remain incomplete rather than being inferred
from simulator tests or the failed U run.
