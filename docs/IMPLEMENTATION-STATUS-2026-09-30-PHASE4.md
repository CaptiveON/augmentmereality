# Vertical support, camera readiness and library paging — 30 September 2026

This batch implements the phone-free work for #10 and #17, and bounded
owner-library synchronization for #26. GPT-6 Sol agents using ultra reasoning
implemented and independently reviewed separate placement, readiness and query
seams. Hosted CI remains deferred at the owner's request because Actions
credits are exhausted. Workflow definitions remain unchanged.

## Vertical placement (#10)

Optional persisted vertical metadata distinguishes terrain, rooftop, measured
local support and unresolved legacy/future references. Local JSON, native
Firestore coding and the disabled CloudKit codec carry the same value. Unknown
values remain readable without becoming permission to reinterpret a surface.
Present malformed metadata becomes explicitly unresolved; missing/null metadata
retains legacy decoding. Invalid raw height offsets remain readable but cannot
request geographic anchors. Presentation uses a finite bounded offset, and
repeated malformed values cannot trigger endless anchor invalidation.
Geographic altitude is WGS84 ellipsoidal height, matching the
[GAR transform contract](https://developers.google.com/ar/reference/ios/interface/GARGeospatialTransform)
and the [absolute-anchor API](https://developers.google.com/ar/develop/ios/geospatial/anchors).
Viewer conversion uses `CLLocation.ellipsoidalAltitude`, not its mean-sea-level
`altitude` value. Missing or incompatible evidence produces a provisional
discovery height and hides the ground-contact cue. Transit no longer invents
a ground plane from eye height or adds eight metres for a roof.

A ground lock requires fresh same-session support near the target footprint:
an upward-facing bounded horizontal plane polygon or a direct upward-facing
scene-mesh ray hit. There is no lowest-plane-anywhere fallback. Plane support
uses actual [boundary vertices](https://developer.apple.com/documentation/arkit/arplanegeometry/boundaryvertices-3h98l),
not an unbounded estimated plane. The object pose, authored offset, anchor
invalidation, ground lock and contact cue update together. Geographic saves
add fresh vertical uncertainty requirements to the existing horizontal/yaw
publication policy. A failed save keeps a session-local support value rather
than retaining altitude tied to the rejected coordinate. Saved local support
with usable WGS84 evidence uses an absolute GAR anchor; terrain and rooftop
references retain their own routing.

Sensor uncertainty thresholds are application admission limits, not measured
physical accuracy guarantees. Slopes, steps, multiple floors, roofs and
second-device/reopen comparisons remain required; #10 stays open.

## Camera readiness and recovery (#17)

The UI follows a tested epoch/selection state machine. Fresh camera capture,
asset readiness and a qualified hero scene-update proxy remain separate.
Normal tracking, a full-content slot, an active enabled holder, nonzero finite
geometry, current viewport projection and a fresh post-run capture are required
for the hero proxy. Expensive bounds sampling is capped at 5 Hz; current pose
and camera projection are evaluated for each scene update. There is one shared
visibility sample for the baseline metric and UI policy.

A cancellable deadline shows loading or recovery guidance without claiming an
object loaded. A slow in-flight asset offers wait guidance; a failed asset can
be retried explicitly without an automatic failure loop. Tracking loss, stale
camera capture or stalled scene updates revoke current readiness, preserving
the historical first-frame/proxy measurements. Hide, new epochs and changed
selections reject stale events. The camera always retains its exit control.
Reset and transit disclose that session-only pins need placement again.

This does not measure presented pixels or prove continuous physical hero
appearance. Cold/cached hero opens, live interruptions, return-to-camera and
device presentation/interaction checks remain required; #17 stays open.

## Owner-library synchronization (#26)

The [query contract](OWNER-LIBRARY-PAGINATION-2026-09-30.md) documents the API,
64-document page limit, immutable document-ID cursor, retry semantics, read
cost and unchanged authorization boundary. The library offers explicit
continuation and labels an incomplete sweep honestly. The legacy `near/radius`
parameters are removed from owner sync. Nearby AR filtering still uses the
loaded library; this batch introduces no public discovery query.

Pages preserve received/local rows, deduplicate overlap, retain cloud edits
across later stale local reads and never treat omission as deletion. Cache,
pending-write or malformed evidence cannot complete a clean sweep. The cursor
also waits for this owner's local outbox because a pending deleted document
can disappear without useful per-document metadata. Pending work belonging to
another UID cannot block the current owner's pages. UID changes hide old
cloud-only data before awaiting disk and cancel publication from stale reads.

## Validation and remaining work

Final local results are recorded in
[the verification record](implementation-evidence/2026-09-30-phase4/verification.json).

| Local check | Result |
| --- | --- |
| Current iOS 26.5, including native Firebase emulator contracts | 366 passed, zero failures/skips |
| Minimum iOS 17.0.1 | 364 passed, zero failures, two opt-in emulator tests skipped (both passed on current iOS) |
| Thread Sanitizer, selected AR/storage/placement/readiness suites | 174 passed, zero reported races; runtime linkage verified |
| Debug and unsigned Release builds | Passed, zero app diagnostics; all 16 existing ownership boundaries compiled in Release |
| Whole-app Swift 6 SIL compile with actual SDK/dependencies | Passed, zero diagnostics; production language mode remains Swift 5 |
| Firestore rules | 8 drift, 60 current, and 6 historical tests passed |
| Current/minimum simulator launch | Root and unsupported-camera screens reached; screenshots inspected |

The final [source fingerprint](implementation-evidence/2026-09-30-phase4/tested-source.json)
covers 112 app/test source files, aggregate
`01215322ddcd7730fc39e134778d7095a7ee6b72d2fc1df83f1159a5e35f1f15`.
Logs and result bundles remain under `/tmp/amr-phase4-sep30`; compact summaries
and log hashes are committed. Debug test-host builds are incremental; the
Release and whole-app Swift 6 checks establish the complete app compile.
Real Firebase configuration is excluded; SDK tests use a disposable emulator.
No rules/index deployment or hosted CI pass is claimed. #26 meets its code and
local acceptance criteria and can close after merge.

Physical thermal, frame pacing, placement and occlusion acceptance remain open.
Simulator tests do not establish that overheating is solved. No phone was
needed for this batch's implementation or local validation.

Next is #18's production object-state/lifecycle consolidation, followed by
#11's synchronized capture/depth contract and the dependent #12–#14 occlusion
work. A registry/lifecycle test draft is prepared separately; it is not part
of this app build and is not claimed as implemented. Physical acceptance
checks stay last.
