# Placement provenance and ownership — 30 September 2026

## Completed merges and CI decision

The owner explicitly requested merging the previously verified functionality
while GitHub Actions credits are exhausted. PRs [#36](https://github.com/CaptiveON/augmentmereality/pull/36)
and [#37](https://github.com/CaptiveON/augmentmereality/pull/37) are merged.
The resulting `main` commit `a759033e0ad5348246750fb7d84ff288f35ec752` has the
same tree as tested and installed commit `684f6b4`. The
[merge record](implementation-evidence/2026-09-30-phase3/merge-resolution.json)
records both merge commits and identical tree hashes.

Hosted CI is deferred at the owner's request. No hosted pass is claimed and
workflow definitions remain intact. The preceding [phase 2 evidence](IMPLEMENTATION-STATUS-2026-09-30-PHASE2.md)
continues to identify its exact tested source; the historical evidence has not
been rewritten to imply that CI ran.

Issues #25 and #28 are closed with implementation and validation evidence;
#3 was already closed. The umbrella checklist reflects those three resolutions.

## Next phase

This branch continues placement provenance in #7 and owner/recipient permissions
in #21. Both have executable work that does not require active phone use.
Two GPT-6 Sol agents with ultra reasoning own separate implementation files;
another reviews authorization and asynchronous transitions. The coordinating
agent handles persistence compatibility, integration, and local validation.

Placement work distinguishes a session-local visual adjustment from a saved
geographic coordinate. Optional metadata records the coordinate source and
available uncertainty inputs. The design retains readable legacy content when
that metadata is absent or damaged. CloudKit's optional codec carries the same
Codable value as local JSON and Firebase; CloudKit remains disabled in the app
configuration and this phase does not deploy a CloudKit schema.

Google describes horizontal accuracy as uncertainty for the returned coordinate,
and yaw accuracy as angular uncertainty. The publication heuristic compares the
target's reported horizontal uncertainty with camera uncertainty plus distance-
dependent yaw displacement. It is an application estimate, not a calibrated
error bound. See the [official GARGeospatialTransform reference](https://developers.google.com/ar/reference/ios/interface/GARGeospatialTransform).
Physical comparison on a second device remains necessary for #7 acceptance.

Explicit camera relocation uses a separate publication policy: a fresh VPS
sample, estimated horizontal uncertainty no greater than 2 metres, and yaw
uncertainty no greater than 5 degrees. These are product admission limits,
not measured physical guarantees. Map/search choices remain deliberately
unquantified, and placing a pin at the current device fix retains that fix's
reported accuracy. A manual map nudge clears a previous sensor claim.
Automatic VPS corrections do not rewrite saved coordinates.

When a camera tap cannot meet that policy, its world pose stays local to the
current AR session and the saved geographic coordinate stays unchanged.
Scene-budget eviction retains the local pose for re-admission. Removing the
source drop, losing edit authority, transit/reset, or a new world frame retires
it. The AR HUD distinguishes this local placement from saved-point quality and
the receiver's current distance-dependent localization estimate.

Ownership work centralizes the local role policy and checks the live row at
mutation entry points. It preserves explicit received-copy removal and legacy
local content while preventing recipient content from becoming recipient-
authored shares. Authoritative immutable-owner Firestore rules remain in place.
The disabled legacy CloudKit adapter has no verifiable owner identity for its
public-database rows. Cloud-backed ownerless content therefore cannot gain
remote-delete authority through a legacy fallback. Enabling that backend would
require an explicit ownership contract; this phase does not invent one.

## Validation

The [verification record](implementation-evidence/2026-09-30-phase3/verification.json)
and [source fingerprint](implementation-evidence/2026-09-30-phase3/tested-source.json)
identify all 101 tested app/test source files. The fingerprint is
`3d5a57a5fd357df5ffa1ad10f4784d0394c6ba7998869072edf1672a250abc04`.

| Local check | Result |
| --- | --- |
| Current iOS 26.5 simulator, including native Firebase emulator contract | 318 passed, zero failures/skips |
| Minimum iOS 17.0.1 simulator | 317 passed, zero failures, one opt-in emulator test skipped (passed on current iOS) |
| Thread Sanitizer, AR/storage/ownership/correction selection | 128 passed, zero reported races; runtime linkage verified |
| Debug and unsigned Release builds | Passed, zero app diagnostics; all 16 concurrency boundaries compiled |
| Whole-app Swift 6 SIL compile with actual SDK/dependencies | Passed, zero errors/warnings; production language mode remains Swift 5 |
| Firestore rules | 8 drift, 59 current, and 6 historical tests passed |
| Disposable-emulator release smoke | 42 checks passed; cleanup complete |
| Diagnostic, simulator-selector, AR-baseline, release-verifier scripts | 6, 3, 6, and 9 tests passed respectively; both drift locks passed |
| Launch on current and minimum simulators | Root and unsupported-camera surfaces reached; all four screenshots inspected |

The Release and Swift 6 app sources match the final fingerprint. Final test-only
fixture corrections preserve full equality assertions while avoiding Firestore
timestamp precision differences. Logs and result bundles remain under
`/tmp/amr-phase3-sep30`; compact results and log hashes are committed here.

The independent authorization review found no remaining #21 blocker. The
ownership UI was reviewed statically and command behavior covered by regression
tests; no interactive physical account-switch UI test is claimed. Issue #21 can
close with this implementation and evidence. Issue #7 remains open for physical
two-device comparison and degraded-localization acceptance. Simulator checks do
not establish real-world placement precision, heat behavior, or occlusion quality.

## Remaining order

Continue vertical reference/support (#10), honest hero readiness and camera
recovery (#17), and consolidated placement state (#18), then the synchronized
depth/occlusion work (#11–#14). Account deletion, moderation, privacy, asset
rights, bounded queries, and invite lifecycle remain a parallel release track.

The phone-dependent acceptance checks stay last: sustained Release heat and
frame pacing, real foreground occlusion, fixed-size placement/heading walks,
second-device shared placement, and physical minimum-iOS launch. This phase
does not establish that overheating is solved or that release gates are closed.
