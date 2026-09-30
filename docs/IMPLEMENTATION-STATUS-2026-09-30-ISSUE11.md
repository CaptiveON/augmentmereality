# Issue 11 implementation and validation, 30 September 2026

The phone-free implementation of [#11](https://github.com/CaptiveON/augmentmereality/issues/11)
is complete. The issue stays open for physical registration, lifetime and thermal
acceptance. No phone was used or installed in this batch. The exact source commit
and merged PR are indexed in the [build ledger](build-history.json).

## Result

Camera, semantic, person-mask, LiDAR and neural-depth consumers now use explicit
capture/session/stream identity, pose, calibration, raster mapping, format,
depth units, confidence meaning and ownership metadata. Every session run retires
the previous stream, including thermal configuration changes. Late, future,
expired, incompatible or unsupported samples take a counted fallback.

RealityKit does not expose its rendered capture identity or camera pose. Admission
therefore uses a documented **bounded approximation**, requiring recent low-motion
capture history, fresh viewport metadata and compatible projection. Scene elapsed
time is never subtracted from capture uptime. GAR semantics retain SDK-opaque
provenance because the SDK exposes no separate semantic capture timestamp. These
limits do not prove physical registration or that foreground objects stayed still.
See the [contract and SDK references](FRAME-DEPTH-CONTRACT-2026-09-30.md).

Depth inference copies its input and output into bounded app-owned buffers. Metal
wrapping now uses correct nonplanar dimensions and retains both Core Video wrappers
and source buffers until GPU completion. One matte command at a time prevents
unfenced reuse of temporal textures; busy callbacks blit without a CPU wait. Failed
commands and rejected associations invalidate history. The shader uses separate
raster transforms and rejects samples outside valid coverage.

## Local evidence

Xcode 26.6 (17F113), iOS SDK 26.5; production remains in Swift 5 language mode.
The compact [verification record](implementation-evidence/2026-09-30-issue11/verification.json)
and [source fingerprint](implementation-evidence/2026-09-30-issue11/tested-source.json)
are durable. The fingerprint covers 120 Swift/Metal app/test files:
`1042543e313b1f8c191ea572b2201b9b3e004c999bb12a7b94eeb3e53435a1d3`.
All lanes used those same source bytes; later documentation commits are not app builds.

| Check | Result |
| --- | --- |
| Current iOS 26.5 suite, including native Firebase emulator contracts | 392 passed; zero failures or skips |
| Minimum iOS 17.0.1 suite | 390 passed; zero failures; two opt-in emulator tests skipped here and passed in the current lane |
| Selected Thread Sanitizer suites | 200 passed; zero failures/skips or reported races; sanitizer runtime linkage confirmed |
| Debug test-host build | Passed, incremental compile; zero app diagnostics |
| Unsigned Release | Passed, complete app compile; zero app diagnostics; all 20 required ownership boundaries compiled |
| Whole-app Swift 6 SIL compile with real dependencies | Passed; zero errors or warnings; this does not switch production language mode |
| Root and unsupported-camera launch smoke | Both screens passed on both OS versions; all four screenshots inspected |
| Supporting checks | Six diagnostics-script tests passed; CI YAML parsed; whitespace checks passed |

The 26 added tests cover capture/stream rejection, asymmetric transforms, unit and
confidence interpretation, calibration/pose bounds, buffer strides, app-owned copy
isolation and GPU lifetime. Real Metal fixtures exercise the production shader and
uniform layout: a rotated semantic edge restores independently computed camera
pixels against a known depth plane, while out-of-coverage pixels stay untouched.
These are synthetic GPU results, not a sensor-registration claim.

The first native runner attempt stopped before tests because Java was absent from
PATH. Reusing the installed Homebrew OpenJDK resolved the environment issue. No
failed test result is omitted. Full logs and screenshots were generated under
`/tmp/amr-issue11-sep30`; their hashes and compact result summaries are checked in,
but temporary artifacts can expire.

Hosted Actions remain deferred because the owner's credits are exhausted. New
contract suites were added to the existing TSan lane without disabling workflows.
No real service configuration was bundled and no live rules/indexes were deployed.

## Remaining gates and next work

- Keep #11 open for target-phone alignment during pans, orientation/viewport changes,
  resume and thermal reconfiguration; delayed semantic/neural output and moving
  foreground; real buffer pressure, Metal scheduling and sustained frame/thermal cost.
- Continue #12 next: general live foreground depth and arbitration with every static
  occlusion stage. Its implementation and synthetic ordering tests can use this
  contract without the phone; physical moving-object acceptance remains separate.
- #13 still owns motion-aware history/reprojection and #14 robust metric fitting.
  Existing fit support remains below 5 m; no 4–60 m metric-depth claim was established.
- #18's archived registry draft is still unintegrated and unbuilt. Its #11 code
  dependency now exists, but manager/lifecycle integration and physical cases remain.
- Last recorded phone installation remains phase 3 source `1b433e7`. This batch does
  not establish that overheating is solved. No additional issue is closed.
