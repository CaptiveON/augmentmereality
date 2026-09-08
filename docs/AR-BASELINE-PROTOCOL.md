# AR Release baseline protocol — issue #3

This protocol measures the reported iPhone 15 Pro Max warmth during startup and
continuous AR use. It does not establish an improvement or replace visual quality
tests. Use [the result template](AR-BASELINE-RESULT-TEMPLATE.md) for every run.
Physical-device evidence must be recorded per run; implementation checks alone are not field results.

## Preserve the baseline before changing workloads

The issue's source reference is `9612f8211547d358f2511be5ccd632f0580dce02`.
The checkout immediately before issue #3 implementation was
`a4aeff7f9d1b6fd4e3cf9a57bd88eecda192df35`. These are different revisions; always
identify which was built. Archive the unchanged Release build, source revision,
dependency resolution, configuration and asset manifest before changing workload
defaults. Do not describe the instrumented implementation as an unchanged build.

Collect three separately identified build/run classes:

| Class | Source and instrumentation | Purpose |
| --- | --- | --- |
| U | Exact unchanged baseline SHA; existing logging only | Preserve original startup/thermal behavior and collect external traces |
| I-off | Exact issue #3 implementation SHA; recorder disabled | Check that adding instrumentation did not change the workload |
| I-on | Same binary as I-off; recorder enabled | Collect readiness, callback cadence and activity; measure recorder overhead |

Do U first, then paired I-off/I-on runs with the same content, device conditions
and observation method. Alternate the order of later pairs; cool the device between
runs. Keep workload defaults identical across these classes. Isolated-subsystem
experiments below are additional variants, never replacements for U.

## Run identity and controlled conditions

Use a physical **iPhone 15 Pro Max**, initially cool and unplugged. Wait for stable
ambient conditions and `ProcessInfo.thermalState == .nominal`; record actual
conditions rather than assuming that nominal means physically cool. Record:

- Full source SHA, dirty-tree status and any exact patch; app version/build,
  Release configuration, Xcode/SDK version, dependency lockfile, archive/dSYM paths,
  executable SHA-256 and launch arguments/environment. A supplied commit label is
  operator metadata, not proof of which executable is installed.
- Device model, iOS version/build, initial battery percentage and thermal state;
  ambient temperature, case, direct sunlight, hand-held/mount arrangement, screen
  brightness setting, auto-brightness, Low Power Mode, refresh/accessibility
  settings, network and location permissions. Keep each unchanged within a pair.
- Charging status and cable connection separately. Record any connection change.
  A trace that charges the phone belongs to a different condition from an unplugged
  thermal run. Prefer wireless profiling where available; record profiler overhead.
- Selected content/drop ID, asset filename, size and SHA-256, model/package version,
  scale and animation state, object count, initial distance and view direction.
  For generated text, preserve text, font/style and size instead of an asset hash.
  Hash all files of a model package; do not hash a directory name as model identity.
- Cache state: process cold versus warm is separate from asset/model/filesystem
  cache state. Force-quit does not prove an uncached asset. Describe the reset or
  retained cache; mark cache state unknown when it cannot be controlled.
- Actual session video format, frame semantics, reconstruction, localization,
  neural/model activity, post-process attachment and tier transitions from recorded
  configuration/activity. A requested feature or enabled flag alone is not proof
  that it ran. Preserve feature support, authorization, model-load failure and
  missing-key reasons; never include API keys in reports.

Use a repeatable physical scene: mark the standing position, initial phone heading,
asset position/distance and pan route. Repeat the same scene and movement schedule.
Treat indoor Room Test and an outdoor geo drop as separate scenarios.

## Instruments and recorder setup

Build and run Release without sanitizers. Record debugger attachment, Metal
validation and profiling settings. Correctness/sanitizer runs cannot supply thermal
or performance acceptance evidence. Keep existing metrics logs and MetricKit
diagnostics as supporting artifacts; lack of a MetricKit payload is not a pass.

Build reproducible Release artifacts with:

```sh
python3 scripts/ar-baseline.py build --derived-data /tmp/amr-baseline-build --output /tmp/amr-baseline-evidence --team YOUR_TEAM
```

Use `--unsigned` instead of `--team` for compile-only checks. The wrapper embeds
source commit, a hash of source/configuration/assets and source-dirty state into
the app's Info.plist, then writes an executable/asset hash manifest and build log.
It rejects source changes during the build. Keep its app, dSYM, manifest and log.
A direct Xcode build without these keys is explicitly **unmeasured** for embedded
source identity. Secrets are excluded from the source manifest; their presence and
actual active subsystems are recorded separately.

For I-on, add `-ARBaselineMetrics` to launch arguments. For I-off omit the argument.
Optional `AR_BASELINE_COMMIT` is an operator label, separate from embedded identity.
Optional operator metadata uses these environment variables:
`AR_BASELINE_ASSET`,
`AR_BASELINE_DISTANCE_METERS`, `AR_BASELINE_BRIGHTNESS`, `AR_BASELINE_CHARGING`,
`AR_BASELINE_INITIAL_THERMAL`, `AR_BASELINE_OBSERVED_WARMTH`,
`AR_BASELINE_TRACE_LOCATION` and `AR_BASELINE_RUN_KIND`. These labels supplement
the run sheet; they do not replace actual measurements or enable subsystem switches.

The recorder atomically overwrites one `baseline-<run UUID>.json` per app process
under the app container's `Library/Application Support/baselines/`. Exports are
queued on epoch start, camera hide/session pause and periodic health observations;
a utility timer also requests an export initially after 10 s and every 30 s.
After the final observation, return to Map and allow the export to finish before
force-quitting. Confirm the `Baseline exported:` log and JSON `exportedUptime`
cover the endpoint; an interrupted export or suspended app may leave older data.
Download the app container after the observation window using Xcode's device tools
and copy that directory into the run artifact folder. Reconnecting for export
happens **after** the unplugged measurement ends. Do not treat a missing export as
zero activity.

Use Instruments on separate, explicitly labeled profiling repeats:

- Time Profiler plus Points of Interest/signposts for main-thread work, GAR update,
  decode, model preparation/inference and configuration/attachment intervals.
- Metal/GPU and applicable rendering instruments for actual GPU work, frame
  presentation/cadence and compositor behavior. A CPU callback ending or submitting
  a command buffer is not GPU completion or display presentation.
- Core ML instruments where supported for model execution/compute attribution;
  distinguish the whole request's elapsed time from measured CPU, GPU or Neural
  Engine execution. Allocations/VM Tracker or equivalent for memory peaks and
  growth. Instruments availability depends on the installed Xcode/device.

Save the original `.trace` bundles, extracted summaries, recorder JSON, run sheet,
source/build manifest, logs and quality video with explicit paths/URLs in the result.
Keep time origins and clock units in every extraction. Collect narrowly scoped
traces when combined instruments materially perturb the workload; do not silently
merge different repetitions into one measured run.

## Measurement meanings

Readiness milestones belong to a camera epoch and session generation. Cold start,
warm resume and recovery must remain distinguishable, including within one app
launch. Use camera intent as the readiness origin, and retain the actual frame's
capture timestamp to reject a retained pre-epoch frame.

| Observation | What it establishes | What it cannot establish |
| --- | --- | --- |
| Camera intent | User requested camera access | Fresh image or visible content |
| First fresh camera frame | A newly captured frame reached the app in this epoch | Its display presentation |
| Placeholder placement | A provisional entity was placed | Selected asset loaded or displayed |
| Selected-asset readiness | The intended asset is ready for that target | The target is in view, unobscured or presented |
| Scene-update observation after readiness | Scene callback occurred after fresh frame and intended-asset readiness, when the recorder's conditions are satisfied | Hero pixels reached the display |
| Post-process observation | Post-process callback/CPU encoding was observed while attached | All renders, GPU duration or hero presentation |
| First presented hero | Independently verified display/video evidence correlated to the intended asset and epoch | Never inferred from a holder, placeholder or pre-warmed zero |

Capture cadence uses frame timestamps; delivery cadence uses callback receipt times.
Scene-update cadence is a **proxy**, not render/presentation FPS. Post-process
cadence is conditional on pass attachment: no callback while detached is not zero
render FPS. Record p95/p99 intervals with stream name, count, time window, dropped
sample count and percentile method. Separate startup (0–10 s), sustained intervals
and each epoch; do not hide a pause or restart inside one average. End-to-end
signpost durations are wall elapsed times, not CPU utilization or GPU execution.

Report inference-input age, delivery/publication age and age at consumption only
where instrumented, using their actual timestamp origins. Report process memory
with its measurement definition (for example resident size versus physical
footprint). Unmeasured CPU/GPU/memory/sample-age fields stay **unmeasured** with a
reason; they do not become zero. JSON may bound samples/events; report its retained
coverage and truncation counters rather than claiming full-resolution traces.

Schema version 2 retains at most 16 epochs, 64 series per epoch, 4,096 recent
samples per series and 256 recent events per epoch, plus bounded first events.
Read the exported `limits` and drop counters in case a later build changes them.
`startupFirstTenSeconds` retains up to 4,096 values in the first 10 s after that
epoch's origin; `recentSamples` is a rolling sample window, **not** the whole
15-minute distribution. Its start is `recentWindowStartUptime`. Percentiles use
nearest rank (`ceil(p × count)`). `wholeEpochHistogram` keeps all observations
in constant memory using 1 ms buckets, reporting conservative p95/p99 upper
bounds. A percentile in the >1000 ms overflow bucket has a null upper bound;
`overflowCount` and the full maximum retain the failure. Whole-epoch count,
mean, min and max are also preserved. `workloadActivity` retains observed active
seconds and transition counts even after detailed events are evicted. Hidden,
paused and interrupted camera epochs end explicitly; later offscreen callbacks
belong to `cameraInactive`, never to the resumed camera's cadence. `sampleAgeMilliseconds` in a series means time since its last observation
at export, not inference-input age. Named age samples such as `captureSampleAge`
or `Depth sample age` have their own source/consumption definitions. Top-level
`residentMemoryBytes` and `processThermalState` are export-time snapshots, not a
peak-memory measurement or full thermal history. Preserve trace/log evidence for
the history and report unmeasured peaks/tails honestly. Cadence signposts are
sampled to at most one per second per stream under a shared start/event rate cap;
signpost count is not frame count. Bounded cadence samples still observe every
callback while their epoch is active.

## Startup runs: first 0–10 seconds

Repeat each scenario at least five times, reporting individual results and the
range/median. Start traces before camera intent and retain the first ten seconds
after it. Record launch-to-intent separately so background asset/model warmup is
not excluded from the startup cost attribution. Note observed warmth at 0, 5 and
10 seconds without opening panels or changing workload during the measured window.

1. **Cold process, immediate camera:** force-quit and open Camera immediately;
   record whether asset/model caches are known cold, retained or unknown.
2. **Cached/prepared:** allow the app's ordinary warmup on Map for a fixed recorded
   duration (10 s), then open Camera. Keep cached readiness separate from the cold
   process experiment; retained content must not produce fabricated presentation.
3. **Delayed selected asset:** reproduce a documented loading delay using an exact
   variant/fixture or a reproducible naturally slow asset. Observe placeholder,
   eventual selected-asset readiness and later scene proxy separately.
4. **Missing selected asset:** use a documented fixture referencing an unavailable
   asset. A fallback/placeholder can be visible, but selected-hero readiness and
   presentation remain missing. Preserve the failure event/reason.
5. **Warm tab resume:** Camera → Map → Camera within the configured grace period
   (currently 5 s). Repeat past the grace period (15 s on Map) as a distinct case.
6. **Background/resume:** background for 10 s and return; record actual epoch and
   session-generation behavior and whether placements survive.
7. **Recovery:** reproduce a documented AR interruption/failure that actually
   triggers recovery. Record trigger, reset, fresh frame and readiness; do not call
   every background return a recovery. If no safe reproducible failure is available,
   mark this scenario incomplete instead of claiming coverage.

Experiment variants use the separate `-ARBaselineExperiment` launch argument,
independent of the recorder. Set `AR_BASELINE_DISABLE` to a comma-separated subset
of `reconstruction,localization,neuralDepth,personSegmentation,sentinel,postprocess,assetPreload`.
The default without this argument is unchanged; environment variables alone cannot
alter workloads. Unknown switches or invalid delays retain shipping defaults and
mark the experiment INVALID. Inspect the exported experiment description.

For an intentionally delayed existing model, set `AR_BASELINE_DELAYED_ASSET` to its
bundle name and `AR_BASELINE_ASSET_DELAY_SECONDS` to 0–10. Disable `assetPreload`
to prevent it being ready before the test. This delay precedes the measured decode
and is separately logged as a fixture delay. Missing assets still use a documented
fixture referencing an absent model; negative-cache failures never become readiness.
Never relabel an experiment variant as U.

Make short **separate** screen recordings for these scenarios to correlate the
reveal, camera image, placeholder, intended hero and interruption behavior with
epoch markers. Record the video-to-log time alignment and its uncertainty.
Video can establish visually observed hero appearance at its frame resolution;
it does not supply precise GPU presentation timestamps or uncontaminated heat/FPS.

## Sustained runs: 15 minutes

For each applicable matrix row, begin cool, nominal and unplugged. Keep Camera
open for 15 continuous minutes with a fixed movement/hold schedule (for example
40 s hold, 10 s slow left pan, 10 s return each minute). Keep content distance and
visibility comparable. Screen recording is OFF. Do not run a sanitizer or introduce
interruption tests in this window. Record battery, thermal state, observed warmth
and workload changes at 0, 2, 5, 10 and 15 minutes; use automated sampling where
available. Describe any manual measurement disturbance.

| Row | Scenario / controlled contrast | Isolation requirement |
| --- | --- | --- |
| U-default | Unchanged production defaults; reproduce reported scene/asset | Required baseline before any workload changes |
| Camera/tracking | Empty scene, no content | Record background reconstruction/localization/neural work; empty alone does not isolate tracking |
| Simple content | One fixed text or simple asset at fixed distance | Match tracking setup; record exact content |
| Reported heavy content | Exact reported asset; Castle only as a separately named fallback if the reported asset is unknown | Record hash/bytes, animation, preload and decode/cache state; do not equate different assets |
| Reconstruction | Matched scenario with reconstruction absent/present | Explicit isolated build patches if needed; record actual requested/supported/active configuration |
| Localization | Matched scenario with GAR/localization absent/present, including convergence versus lock | Record authorization/network/coverage and actual update activity; do not change credentials silently |
| Neural perception | Matched scenario without/with each neural component (person sentinel, depth, semantics as applicable) | Separate model load, inference and pass activity; document dependencies such as GAR semantics and LiDAR |

For camera/tracking isolation, disable all seven optional subsystems and use an
empty scene. For simple/heavy content, use the same disabled set and place exactly
one Room Test object. Add back reconstruction, localization or neural components
one at a time. These switches suppress work; they do not force unsupported sensors,
localization success or model inference without a consumer. Neural depth still
needs a full-tier scene and content in its serviceable 4–5 m band. Keep dependencies
(such as depth plus its postprocess consumer) together and label them explicitly.
Record any row with unmet prerequisites as **not isolated / incomplete**. A default-policy tier transition
changes workload; record its timing and do not attribute its combined cost to one
subsystem. Capture additional short profiler repeats around expensive transitions.

Retain the existing targets: **at least 30 presented FPS, p95 frame interval at most
40 ms, and no `.serious` (or `.critical`) thermal state at ten minutes**, extending
observation to fifteen minutes. Report presentation-stream target outcomes only
with presentation evidence. Report capture/scene/post-process proxy target checks
separately; a proxy pass cannot close the presentation gate. Record the full
thermal timeline and any state escalation even if it returns to nominal by minute
10. Record the 15-minute result separately, not as an assumed continuation of the
10-minute result. Observed warmth and a HUD banner are not replacements for
`ProcessInfo.thermalState`.

## Overhead, debrief and completion

Compare I-off/I-on repetitions with matched conditions and the same external
instrumentation (or neither). Report startup duration, cadence distribution,
CPU/GPU timing, memory, battery and thermal differences only where measured, with
run-to-run variation. A missing metric in I-off cannot be treated as zero overhead.
Record quality-video, Instruments and recorder overhead separately. If overhead is
larger than repeatability, retain that limitation in the baseline conclusions.

Keep raw evidence and failures. Use the template to distinguish **pass**, **fail**,
**unmeasured** and **incomplete**; include the exact implementation SHA and tests.
Simulator tests can validate epoch tagging, stale-frame/placeholder handling and
statistics. A build or simulator pass cannot establish device heat, visual quality,
GPU cost or presentation cadence. Issue #3 remains incomplete until the required
physical-device traces and reports are attached. It does not require or imply a
thermal improvement.

The recorder also retains up to 128 export-time system observations in
`recentSystemSamples` (uptime, epoch/generation, ProcessInfo thermal state and
resident memory). `droppedSystemSamples` reports eviction. These snapshots can show
sampled memory/thermal changes; they are not a memory peak or continuous thermal
trace. A received invitation supplies its intended drop ID before warmup; otherwise
the first nearest target is fixed for the epoch before checking readiness. Use one
intended target per readiness run and verify the exported `selectedHero` ID.

## Generate and retain the result

```sh
python3 scripts/ar-baseline.py report /path/to/baseline-RUN.json --conditions /path/to/conditions.json --output /path/to/result.md
```

The optional conditions JSON accepts `observed_warmth`, `initially_cool`,
`screen_recording` (boolean), `raw_trace_locations` and `build_manifest`. The report
always keeps presentation unmeasured unless separately supplied evidence is reviewed;
proxy values never become presented FPS. Use the result template for overhead pairs
and quality-video review. Do not claim an I-off missing field is zero overhead.

Schema 2 additionally records cumulative process user+system CPU seconds from
`getrusage`, bounded system-sample CPU deltas, and GPU start/end durations from
completed RealityKit postprocess command buffers. GPU durations cover the whole
provided command buffer, are absent when callbacks are detached or timings are
unavailable, and never measure hero presentation. No synchronous GPU waits are added.
Per-epoch conditions include actual brightness, initial battery/thermal readings,
selected asset/drop and placement distance. UIKit battery states are 0 unknown,
1 unplugged, 2 charging, 3 full; a negative battery fraction is unmeasured.
