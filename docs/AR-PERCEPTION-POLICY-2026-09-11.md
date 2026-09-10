# Perception demand validation — issue #4

Issue [#4](https://github.com/CaptiveON/augmentmereality/issues/4) follows the
completed [baseline](AR-BASELINE-2026-09-08.md) and its
[physical measurement protocol](AR-BASELINE-PROTOCOL.md). This report separates
implementation checks from device observations. **Device validation is pending;
no thermal, cost, presentation or visual improvement is established.**
Keep #4 open until the required policy tests and physical validation are complete.

## Preserved baseline and source identity

The starting main commit is `6ba0b44178478298970e7834f986ac6b1e0d6f26`.
Issue #3's original U, I-off, I-on and Q evidence remains in
`docs/ar-baseline-evidence/2026-09-08/` and the durable local archive
`/Users/captiveon/Documents/AR-Baselines/issue-3-2026-09-08/`.
Use a separate `issue-4-2026-09-11` artifact directory for subsequent builds and
traces. Do not replace baseline apps, exports, reports, videos or failed attempts.

The baseline recorded Serious at about 186 s from trace start in both I-off and
I-on. Those runs happened on different days and do not establish causal recorder
overhead. I-on recorded GAR semantic production active for about 942 s but its
postprocess consumer active for about 217 s. This motivates the scheduling change;
it does not attribute the device's thermal failure to a single subsystem.
Actual presentation FPS/p95 and model execution-device attribution were unmeasured.
The separate Q recovery case lost Room Test text; retain that known failure when
assessing regressions and distinguish issue #18 placement recovery work.

Read-only preservation check at `2026-09-10T23:36:48Z` found no diff in the prior
baseline reports, protocol, checked-in evidence or media. Original untracked
audit/research files remain untracked. Recorded SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `docs/AR-BASELINE-2026-09-08.md` | `7af330d0e861977a7c1455860cda627b9923e0fe8e813f9b34b83dff2df22342` |
| `docs/AR-BASELINE-PROTOCOL.md` | `830e6e3da683358c23a775378c1b9e6397718c8afee2db73da4bbf9ee49e02ed` |
| `AR-TECHNOLOGY-RESEARCH-2026-09-07.md` | `264c9fa305f4136f220b8ea5d2279df91b7117c9cd8936ae08ac87c5be795671` |
| `IMPLEMENTATION-PLAN-2026-09-08.md` | `31e4f16f5cb2a4cfeef124dcf2a251ebf2c219c677dee337d019a811391dd2db` |
| `TECHNICAL-AUDIT-2026-09-07.md` | `b7209f849639ce7be475df0892fa86a19f0c8e794f717a72cec8a697635dffeb` |

The tested implementation is commit `82ae3f5273e2b9330e49ef620be1d17eabc55004` on
`fix/issue-4-perception-demand`. Its signed Release build has a clean app-source
tree, embedded verified build identity and the same source hash as the 215-test run:

| Implementation identity | Value |
| --- | --- |
| Source hash | `07ecef1e2d58cbd0aa38737baf7665b76a5c5454132b7339dd51968fbbd1ffa1` |
| Executable SHA-256 | `a8a241c1da254bd20c28f369c014f042616ac0ad106257f084a72d1394be95e4` |
| Configuration | Release, signed with the existing development team |
| Version / SDK / minimum OS | 0.9.0 (1) / iphoneos26.5 / 17.0 |

The [Release build manifest](ar-perception-evidence/2026-09-11/release-build-manifest.json)
and [artifact record](ar-perception-evidence/2026-09-11/artifact-info.json) identify
the build. The app and dSYM are retained at
`/Users/captiveon/Documents/AR-Baselines/issue-4-2026-09-11/builds/P/`.
Their binary UUIDs match and `codesign --verify --deep --strict` passed.
The app bundle contains the existing service configuration and stays local.

Installation on the baseline iPhone 15 Pro Max succeeded at **00:47 BST,
September 11**, using the archived app. `install.json` and `install.log` are
retained beside it. No issue #4 camera scenario or thermal trace has been run:
the phone reported a required passcode unlock, and operator availability/scene
conditions have not been confirmed. Installation is not a physical-validation pass.

## Implementation under validation

`GeoARSessionManager` now builds one `PerceptionDemand` snapshot containing camera
visibility, running/interrupted/failed state, projected content with each object's
own distance, held editing ownership, capabilities, render/window mode and thermal
state. The projection checks content bounds against the viewport; a nearby object
outside the view cannot supply the distance for another visible object. An edited
object remains relevant while either held gesture still owns it. Person occlusion
has no virtual-object distance ceiling: a nearby person can occlude distant content.
The existing LiDAR-calibrated neural-depth band remains strictly 4–5 m, with its
scene-depth, full-tier and pedestrian prerequisites. No depth algorithm changed.

`PerceptionPolicy` owns the injected-clock governor and sensor dwell. It requests
semantics only while a relevant content consumer can use them, including the
Serious-state exclusion. Critical bypasses the ordinary six-second governor and
ten-second person/depth downgrade dwell. A six-second noncritical recovery hold
survives session-request resets, so a pause/return cannot immediately restore
critical-shed work. Ordinary person-detection changes retain the existing request
dwell and do not toggle reconstruction. Capability fallbacks still use RealityKit's
built-in `personSegmentationWithDepth` where the custom stencil/depth pass is
unavailable; the policy distinguishes that retained built-in consumer from custom
pass use.

`PerceptionCoordinator` applies the policy through granular subsystem adapters:
ARKit configuration, GAR admission/mode, sentinel/depth admission, sample consumers
and postprocess callbacks. It closes consumer admission before changing producer
configuration. If ARCore refuses a semantic disable, its actual active state is
retained as evidence and GAR frame updates stop until a later disable succeeds.
An unsuccessful semantic enable cannot attach an otherwise unused postprocess
pass. Callback detachment keeps the existing five-second idle and ten-second
minimum-attachment conditions during ordinary transitions; lifecycle and Critical
shutdown bypass that dwell.

The coordinator's generation is the manager's work-generation source. Hide,
suspend, interruption, failure and tracking reset retire outstanding admissions;
each producer also has an admission revision, so disabling/re-enabling it within
one session rejects an older completion. Depth samples and semantic snapshots
carry the generation. Sentinel publication, depth publication, GAR anchor replies
and asynchronous streetscape work reject retired tokens. Frame-driven producers
require a running, visible session and a recent frame captured after the relevant
run/visibility boundary. A hidden-camera fallback GAR feed has been removed.
These are lifecycle identities; issue #11 still owns the full synchronized frame,
pose, calibration and depth contract.

The same ARView/ARKit session and existing placements are retained for supported
warm resume. During the five-second tab grace, only already-running reconstruction
can be retained; new perception admission closes immediately. After the actual
pause, resume requests the stable reconstruction axis and fresh results reestablish
other perception. A failure received during hidden grace keeps its retry pending
for the next visible tick; a short return cannot lose recovery merely because the
holder did not need to call `resumeSession`.

The recorder now distinguishes these stages:

| Recorded stream | Meaning |
| --- | --- |
| `sessionConfiguration`, `reconstructionRequested`, `personSegmentationRequested`, `sceneDepthRequested` | Configuration actually passed to ARKit; not measured per-feature execution |
| `Perception semantics requested` | Policy demand for semantic production |
| `GAR semantics` | Last successfully applied GAR semantic configuration |
| `Perception localization admitted`, `Perception sentinel admitted`, `Perception person admitted`, `Perception depth admitted`, `Perception semantics admitted` | Work allowed by the policy/coordinator; not proof of an inference or sample |
| `GAR blocked by semantic disable` | GAR retains active semantics after an unsuccessful disable and updates must remain stopped |
| `GAR update`, `Person sentinel inference`, `Depth inference`, `Depth sample published` | Observed producer/request/publication activity under the existing measurement definitions |
| `Semantic matte consuming`, `Person matte consuming`, `Depth matte consuming` and corresponding `sample used` observations | Source textures accepted by the most recent compute encoding; not GPU completion or presentation |
| `Semantic postprocess`, `Postprocess callback proxy`, `Postprocess blit fallback` | Callback attachment and conditional execution, including no-source fallback |
| `perceptionInvalidated`, `perceptionPlan`, stale-completion rejection events | Lifecycle generations, demand changes and rejected retired work |

In particular, the non-LiDAR built-in person path has no custom `Person matte
consuming` event. Its retained ARKit request can outlast fresh person admission
during the ordinary off dwell. Do not interpret a missing custom-pass event as
proof that built-in occlusion stopped.

Policy and coordinator tests exercise injected-clock transitions through fake
granular subsystem adapters. The coordinator tests exercise the production
ordering, admission-token invalidation and callback dwell, rather than only
copying the resulting plan. Separate tests cover real feed generation rejection.
Their local execution results are recorded below; fake SDK outcomes cannot establish
device API success, quality, presentation or cost.

## Local environment and checks

Read-only inspection on September 11 local time found Xcode **26.6 (17F113)**,
the `AugmentMeReality` scheme and `AugmentMeRealityTests` target. Available test
destinations include booted iPhone 17 / iOS 26.5 and iPhone 15 / iOS 17.0.1
simulators. SDK/package resolution succeeded with the existing package lock.

A physical **iPhone 15 Pro Max (iPhone16,2), iOS 26.6 (23G71)** is paired,
booted, connected over **wired USB**, with Developer Mode and device services
enabled. This confirms a viable device destination; it does not establish that
the phone is cool, unplugged, at Nominal, showing the prescribed scene or running
the implementation. At 00:44 BST the device reported `passcodeRequired: true`; physical interaction
requires the operator to unlock it. No installation or launch was performed
during this inspection.

Use a config-free simulator test host, retaining logs and result bundles:

```sh
xcodebuild -project AugmentMeReality.xcodeproj -scheme AugmentMeReality \
  -configuration Debug \
  -destination 'id=A203C7B2-7DBA-494E-9E34-E1FED217D83B' \
  -derivedDataPath /tmp/amr-issue4-tests \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates CODE_SIGNING_ALLOWED=NO \
  'EXCLUDED_SOURCE_FILE_NAMES=GoogleService-Info.plist Secrets.plist' \
  -resultBundlePath /tmp/amr-issue4-policy-tests.xcresult \
  -only-testing:AugmentMeRealityTests/PowerGovernorTests \
  -only-testing:AugmentMeRealityTests/PerceptionPlanTests \
  test
```

Include the new demand/adapter/generation suites in the final selected test run;
the command above identifies the existing policy suites only. Full local CI's
simulator/native Firebase-emulator gate is available via:

```sh
AMR_ALL_LOCAL_TESTS=1 AMR_TEST_OUTPUT_DIR=/tmp/amr-issue4-native \
  bash web/rules-tests/run-native-sdk-tests.sh \
  A203C7B2-7DBA-494E-9E34-E1FED217D83B
```

The existing baseline build wrapper supports a signed Release build with embedded
source identity and exact asset/executable hashes. Use a fresh output directory:

```sh
python3 scripts/ar-baseline.py build \
  --derived-data /tmp/amr-issue4-release \
  --output /tmp/amr-issue4-evidence/build \
  --team 3WN9B888RU
```

The signing team is the existing issue #3 Q build's team. A successful signed
build remains a compilation/provenance result until installed and validated on
the physical phone. Use `--unsigned` instead for compile-only verification.

The fast CI equivalents passed locally on September 11. Logs are retained under
`/tmp/amr-issue4-validation/`:

| Command | Result | Log |
| --- | --- | --- |
| `node web/rules-tests/drift-check.mjs` | Pass: emoji and reaction-key drift locks | `drift-check.log` |
| `node --test scripts/verify-firestore-release.test.mjs` | 9 passed, 0 failed | `verify-firestore-release.log` |
| `python3 scripts/ar-baseline.test.py` | 6 passed, 0 failed | `ar-baseline-tests.log` |

These checks did not mutate prior evidence, deploy rules or exercise the live
Firebase project. The full local iOS suite also passed: **215 tests, zero failures**
on iPhone 17 / iOS 26.5 Simulator, including the native Firestore SDK emulator
regression. The live `FirebaseIntegrationTests` suite was explicitly excluded;
real service plists were excluded and their absence verified before launch.
The standalone JavaScript Firestore rules suite was not rerun for this AR-only
change. No deployment was performed.

The run used the documented native wrapper with `AMR_ALL_LOCAL_TESTS=1`,
`AMR_TEST_OUTPUT_DIR=/tmp/amr-issue4-native`, the simulator UDID above and
`/tmp/amr-issue4-tests/SourcePackages` as its second argument. Java 26 was supplied
on PATH from the existing Homebrew installation. The
[215-test result](ar-perception-evidence/2026-09-11/ios-test-summary.json) and
[source provenance](ar-perception-evidence/2026-09-11/ios-test-provenance.json)
are checked in. Build, package, native-emulator and fast-check logs plus the full
`.xcresult` are retained under
`/Users/captiveon/Documents/AR-Baselines/issue-4-2026-09-11/checks/`.

The new coverage includes 15 demand tests, 9 production-coordinator tests with
granular fake subsystem sinks, 8 admission/feed-generation tests and 11 governor
tests. Existing Wave D, baseline/readiness, math and storage regressions also ran.
Coordinator tests exercise actual command ordering, failed semantic configuration,
callback dwell and invalidation; they do not execute real ARKit/GAR/Metal work.
The build retains existing Swift concurrency warnings in AR/asset code; no
sanitizer, GPU or physical-device pass is claimed by this test run.

| Required implementation check | Result |
| --- | --- |
| Injected-clock demand-to-adapter transitions and ordinary downgrade dwell | Pass in local iOS suite |
| Serious semantics producer and consumer both disabled | Pass in local iOS suite |
| Critical escalation during governor/person/depth dwell immediately applies critical plan | Pass in local iOS suite |
| Projected-content identity prevents nearby offscreen content from activating unrelated neural work | Pass in local iOS suite |
| Glass/transit changes and two-finger edit ownership | Pass in local iOS suite |
| Hidden/suspended/interrupted/failed admission and generation rejection after resume | Pass in local iOS suite |
| Policy invariants for recovery hysteresis, warm resume and stable reconstruction | Pass in local iOS suite; physical behavior pending |
| Focused existing baseline/readiness and occlusion regression tests | Pass in local iOS suite |
| Signed Release compilation and embedded source provenance | Pass; signed Release installed, matching app/dSYM UUIDs |

## GitHub Actions restriction

[Main CI run 34542351704](https://github.com/CaptiveON/augmentmereality/actions/runs/34542351704)
on `6ba0b44178478298970e7834f986ac6b1e0d6f26` completed as failure on September 10
at 23:29 UTC. Its `ios-tests`, `rules-emulator` and `drift-locks` jobs each have
**zero executed steps**. All three check-run annotations say the jobs were not
started because recent account payments failed or the spending limit needs to be
increased, and direct the account owner to Billing & plans.

This is an infrastructure block, not an executed test failure. Local results
must be reported separately. The earlier successful
[Q-source CI run 34538554041](https://github.com/CaptiveON/augmentmereality/actions/runs/34538554041)
belongs to `b45f43725166c156dfd69a8f871660d665f35923`; its 181 simulator tests do
not validate issue #4. Record the implementation run's own URL and disposition
if a new CI run is created. No billing setting was changed or CI rerun requested.

## Required physical validation

Follow the existing protocol's measurement definitions. Archive the exact
implementation Release app/dSYM, source patch if dirty, package lock, executable
hash, launch arguments, recorded conditions, logs, recorder JSON and original
traces. Use `-ARBaselineMetrics` for activity evidence. Keep any synthetic thermal
or workload override explicitly labeled as an experiment; it cannot establish
natural heating or cooling. A capability/request flag alone does not prove
actual inference, sample publication, consumption or presentation.

Use separate short quality recordings for the scenarios below and correlate the
visible content with the selected drop ID, epoch/generation and fresh frame.
Record actual return delays, retained placement, editing target and the ordering
of request/use activity. Screen recording affects cost and is excluded from the
sustained thermal run.

| Device scenario | Evidence required | Result |
| --- | --- | --- |
| Far visible content while thermal state becomes Serious | GAR semantics request and consumer activity both fall; retain natural thermal timeline and relevant visibility | Pending physical validation |
| Critical admission | Next-update plan drops immediately; generation/activity records show rejected late work; distinguish physical fixture from natural state | Pending physical validation |
| Nearby offscreen object plus distant visible content | Exact IDs, camera view and distances; unrelated depth/sentinel work does not start | Pending physical validation |
| Supported near/person occlusion, glass and transit | Visual occlusion remains usable where supported; display thermal degradation honestly; no persistent oscillation | Pending physical validation |
| Two-finger editing | Second held gesture retains the captured editing target; no wrong-drop commit or producer oscillation | Pending physical validation |
| Camera → Map → Camera inside 5 s grace | One retained AR session and stable mesh; hidden camera admits no new perception work; fresh results resume | Pending physical validation |
| Camera → Map for 15 s → Camera | Paused then warm-resumed session; supported placements survive; old results cannot reactivate consumers | Pending physical validation |
| Background for 10 s then return | Capture/perception stop; generation advances and fresh samples restore supported perception | Pending physical validation |
| Actual interruption/failure and recovery | Trigger recorded, no stale result revival, fresh-frame recovery; compare with Q's known Room Test loss | Pending physical validation |

Repeat controlled Release sustained observations for **15 minutes**, beginning
cool, Nominal and unplugged with screen recording off. Record brightness, battery,
ambient/case/holding conditions, scene/content, permissions, cache status and
movement schedule. Keep recorder/profiler setup matched; record their overhead
and the fact that September 8–10 baseline conditions were not fully controlled.
At 0, 2, 5, 10 and 15 minutes retain thermal/workload observations and operator
warmth separately. Compare process CPU, measured GAR/depth/sentinel and postprocess
activity, resident size and callback distributions only where captured. A thermal
escalation or visual regression remains a reported failure, not a missing row.

Keep the existing targets explicit: at least **30 presented FPS**, presentation
p95 interval at most **40 ms**, and no Serious/Critical at ten minutes, with the
separate fifteen-minute outcome. Scene-update, capture and postprocess callbacks
remain proxies. If available instruments cannot measure a target, report it
**unmeasured** with the reason. Do not convert a simulator pass or lower requested
workload into a device cooling or presentation claim.

## Result and closure status

The 215-test local iOS suite passed and the exact signed Release build is installed.
There is no issue #4 device trace, quality result or measured subsystem-cost change
yet. The phone requires an operator unlock and the controlled physical scenes/runs
remain pending. Issue #4 remains open; no thermal or presentation improvement is
claimed. No GitHub issue status, PR, remote branch or billing setting was changed.
