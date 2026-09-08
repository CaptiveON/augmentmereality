# AR baseline result — <run ID>

Protocol: [AR-BASELINE-PROTOCOL.md](AR-BASELINE-PROTOCOL.md) ·
Issue: [#3](https://github.com/CaptiveON/augmentmereality/issues/3)

**Status: incomplete — physical-device measurements not entered.**
Replace placeholders only with measured evidence. Use `unmeasured (reason)` for a
missing metric; use `not applicable (reason)` only when it does not apply. A
placeholder, retained holder or callback proxy is never first-presented-hero proof.

## Build and run identity

| Field | Recorded value |
| --- | --- |
| Run ID / UTC date / operator | <pending> |
| Class / matrix row / repetition | <U, I-off, I-on or named isolated variant; pending> |
| Exact source SHA | <pending; issue reference: 9612f8211547d358f2511be5ccd632f0580dce02> |
| Dirty status / preserved patch | <pending; preimplementation HEAD: a4aeff7f9d1b6fd4e3cf9a57bd88eecda192df35> |
| Actual installed build identification | <pending; do not rely solely on AR_BASELINE_COMMIT> |
| Configuration / app version / build | <Release / pending / pending> |
| Xcode / SDK / dependency lockfile | <pending> |
| Archive / executable SHA-256 / dSYM | <pending> |
| Launch arguments / environment | <pending; omit secrets> |
| Recorder / debugger / sanitizers / Metal validation | <pending> |
| Instruments / screen recording | <pending; thermal runs require screen recording OFF> |
| Start/end / camera intent time / duration | <pending> |

## Conditions and content

| Field | Recorded value |
| --- | --- |
| Device / iOS version and build | <iPhone 15 Pro Max / pending> |
| Ambient °C / direct sun / case / handling | <pending> |
| Initially cool observation / cooldown procedure | <pending> |
| Initial ProcessInfo thermal state / battery % | <pending; thermal state and warmth are independent observations> |
| Charging / cable / connection changes | <pending; unplugged required for primary thermal run> |
| Brightness / auto-brightness / Low Power Mode | <pending> |
| Display/refresh/accessibility settings | <pending> |
| Network / permissions / localization coverage | <pending; no keys> |
| Indoor/outdoor scene / position / movement schedule | <pending> |
| Content/drop ID / asset filename / bytes / SHA-256 | <pending> |
| Model package file hashes / version | <pending> |
| Content count / scale / animation / initial distance / heading | <pending> |
| Process/cache state / reset procedure / warmup duration | <pending; unknown when unverified> |
| Actual capture format / semantics / reconstruction | <pending> |
| Localization / model activity / pass attachment / tier | <pending; attach configuration/activity timeline> |
| Requested but unsupported/inactive subsystems / reasons | <pending> |

## Readiness per camera epoch

Times are milliseconds relative to camera intent unless otherwise labeled. Keep
every epoch, including ones that fail to become ready. Preserve raw monotonic
timestamps and session generations in the attached JSON/trace.

| Epoch / generation / kind | Trigger / cache state | Fresh frame | Placeholder | Selected asset ready | Scene-update readiness proxy | First presented hero evidence |
| --- | --- | --- | --- | --- | --- | --- |
| <pending> | <pending> | unmeasured | unmeasured | unmeasured | unmeasured | unmeasured; callback proxy is insufficient |

| Scenario | Repetitions / run IDs | Outcome / failures / evidence |
| --- | --- | --- |
| Cold immediate camera | <pending> | incomplete |
| Cached/prepared camera | <pending> | incomplete |
| Delayed selected asset | <pending> | incomplete; record fixture/build |
| Missing selected asset | <pending> | incomplete; intended hero must remain missing |
| Warm tab resume within grace | <pending> | incomplete |
| Tab resume past grace | <pending> | incomplete |
| Background/resume | <pending> | incomplete |
| Session recovery | <pending> | incomplete; record actual recovery trigger |

Reveal/hero visual observation: <pending; separate video path, epoch alignment and
uncertainty; whether the intended asset was actually visible, and at what frame>.
Launch-to-intent preparation cost: <unmeasured; give time origin and profiler path>.

## Cadence and workload cost

Fill separate rows for 0–10 s startup, each sustained minute/window, whole 15-minute
coverage and each relevant epoch. Supply counts, coverage, discarded samples and
percentile method. Do not label scene-update or post-process callbacks as presented
frames. Do not substitute a configured target frame rate for a measured rate.

| Stream / window / epoch | Source and definition | Count / coverage / dropped | Mean FPS | p95 interval ms | p99 interval ms | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Capture timestamp cadence | <pending> | unmeasured | unmeasured | unmeasured | unmeasured | <pending> |
| Capture callback delivery | <pending> | unmeasured | unmeasured | unmeasured | unmeasured | <pending> |
| Scene-update cadence (proxy) | <pending> | unmeasured | unmeasured | unmeasured | unmeasured | <pending> |
| Post-process cadence (conditional proxy) | <pending> | unmeasured | unmeasured | unmeasured | unmeasured | <pending> |
| Actual presentation | <Instruments/display evidence; pending> | unmeasured | unmeasured | unmeasured | unmeasured | <pending> |

Percentile method and treatment of pauses/invalid timestamps: <pending>.
Recorder retention limits/truncation, inference sampling and missing windows: <pending>.
Schema 1's p95/p99 cover bounded startup/recent samples; they are not full-run
percentiles. The export's series `sampleAgeMilliseconds` is observation recency,
not inference-input age. Preserve exact windows and definitions when extracting.

| Measurement / window | Value and unit | Definition / source / coverage |
| --- | --- | --- |
| Main-thread / process CPU | unmeasured | <CPU execution/utilization; pending> |
| GPU execution / GPU frame time | unmeasured | <device timing, not callback wall time; pending> |
| GAR update elapsed duration | unmeasured | <count, p50/p95/p99, wall versus CPU; pending> |
| Asset decode / selected asset | unmeasured | <cold/cached/failure, count/duration; pending> |
| Model preparation per model | unmeasured | <load/compile/prewarm distinction; pending> |
| Inference per model | unmeasured | <request elapsed versus CPU/GPU/ANE attribution; pending> |
| Post-process CPU encoding | unmeasured | <includes/excludes submission, attached time; pending> |
| Memory initial / peak / at 10 and 15 min | unmeasured | <resident size/physical footprint definition; pending> |
| Sample age at input / publication / consumption | unmeasured | <stream, source timestamp, units, p95/max; pending> |
| Workload/tier / configuration / attachment timeline | unmeasured | <actual active intervals and transition counts; pending> |

## Warmth, thermal state and battery

| Elapsed | Observed warmth | ProcessInfo thermal state | Battery % | Charging | Workload / notes |
| --- | --- | --- | --- | --- | --- |
| 0 s | unmeasured | unmeasured | unmeasured | <pending> | <pending> |
| 5 s | unmeasured | unmeasured | unmeasured | <pending> | <pending> |
| 10 s | unmeasured | unmeasured | unmeasured | <pending> | <pending> |
| 2 min | unmeasured | unmeasured | unmeasured | <pending> | <pending> |
| 5 min | unmeasured | unmeasured | unmeasured | <pending> | <pending> |
| 10 min | unmeasured | unmeasured | unmeasured | <pending> | <pending> |
| 15 min | unmeasured | unmeasured | unmeasured | <pending> | <pending> |

Full thermal transitions/max state and warning times: <pending; absence of a HUD
warning is not evidence of a nominal state>. Battery delta: <unmeasured; coarse
percentage is not a power measurement>. Manual sampling disturbances: <pending>.

## Targets and interpretation

| Gate | Result: pass / fail / unmeasured / incomplete | Supporting evidence and limits |
| --- | --- | --- |
| At least 30 presented FPS during sustained use | unmeasured | <presentation evidence required> |
| Presented-frame p95 interval at most 40 ms | unmeasured | <presentation evidence required> |
| Capture/scene proxy checks against 30 FPS / 40 ms | unmeasured | <separate from presentation gates> |
| No serious/critical thermal state through 10 min | unmeasured | <thermal timeline required> |
| Thermal/cadence observation extended through 15 min | incomplete | <retain failures after minute 10> |
| Placeholder/stale holder cannot report selected hero | incomplete | <missing/delayed/retained cases and video> |
| Cold / warm resume / recovery separately identifiable | incomplete | <epoch and generation evidence> |

Observed bottlenecks and alternatives still unresolved: <pending; distinguish
source-code inference from trace attribution>. No thermal or visual improvement
is claimed by this template or by build/test success.

## Overhead comparison and artifacts

| Matched run pair / external profiling settings | Metric | I-off | I-on | Difference / repetition variation / limitation |
| --- | --- | --- | --- | --- |
| <pending> | <startup/cadence/CPU/GPU/memory/battery/thermal> | unmeasured | unmeasured | unmeasured |

U versus I-off behavior comparison: <pending>.
Separate Instruments and video overhead assessment: <pending>.

| Artifact | Exact file path or durable URL |
| --- | --- |
| Raw Instruments `.trace` bundle(s), including run/window mapping | <pending> |
| Exported recorder JSON and schema version | <pending> |
| Source/patch/dependency/asset/build manifest | <pending> |
| Archive/executable/dSYM | <pending> |
| Raw logs and available MetricKit diagnostics | <pending> |
| Separate quality screen recording and alignment notes | <pending> |
| Summary extraction script/version and percentile definitions | <pending> |
| Test results and exact implementation SHA | <pending> |

Outstanding physical-device evidence, failed scenarios and next required run:
<pending; do not mark issue #3 complete without the required device artifacts>.
