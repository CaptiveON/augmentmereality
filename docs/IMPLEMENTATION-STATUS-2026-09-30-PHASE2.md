# Storage and VPS implementation status — 30 September 2026

This phase starts from `eb63a99` on `fix/storage-vps-corrections`. It continues
issues [#8](https://github.com/CaptiveON/augmentmereality/issues/8) and
[#7](https://github.com/CaptiveON/augmentmereality/issues/7). The original
audit, research, and implementation-plan files remain unchanged.

## Merge diagnosis

### Resolution — 30 September 2026

The repository owner confirmed that GitHub Actions credits are exhausted and
explicitly authorized merging the locally verified functionality without waiting
for hosted CI. [PR #36](https://github.com/CaptiveON/augmentmereality/pull/36)
merged as `a5625924128135a1516a02071ded73a46236bbb8`;
[PR #37](https://github.com/CaptiveON/augmentmereality/pull/37) merged this storage
and VPS batch as `a759033`.
The resulting `main` tree exactly matches the tested and installed `684f6b4`
tree; all 93 source files match the final validation fingerprint. Workflow and
check definitions were not disabled. Hosted CI remains unverified and deferred
at the owner's request. The diagnosis below records the earlier blocked state.

Issues #25 and #28 were closed with implementation and validation evidence. The
umbrella tracker also reflects the previously closed #3. Other issues retain
their outstanding implementation, service, or physical acceptance requirements.

### Original diagnosis

[PR #36](https://github.com/CaptiveON/augmentmereality/pull/36) is mergeable
without source conflicts. In
[CI run 36645268084](https://github.com/CaptiveON/augmentmereality/actions/runs/36645268084),
all four jobs failed before starting: GitHub's annotations report an account
payment or spending-limit restriction. No build or test ran in that workflow.
Actions billing must be restored before rerunning the checks. Required checks
remain intact; remote CI and merge completion are pending.

The next phase uses a separate branch so PR #36 can retain its reviewed source
while the account restriction is resolved.

The PR's previously built, config-free test app passed local home-screen and
unsupported-camera launch smoke checks on iOS 17.0.1 and 26.5. Both screenshots
were inspected. Those checks cover view appearance and process survival, not
AR capability or a signed Release launch. The source/test fingerprint and
earlier full suite results remain in the preceding implementation record.

## Storage ownership

`DropStore`, provenance, absence verification, and local diagnostics now require
checked `Sendable` implementations. `GeoDrop`, its content enum, and cloud read
snapshots are transferable values. The local store keeps mutable state in its
actor; the stateless Firebase and CloudKit adapters keep SDK references within
each operation. These changes add no unchecked conformance.

Local save and delete use a synchronous actor-isolated read helper, keeping the
read-modify-write inside one actor turn. Corruption recovery, preservation
guards, acknowledgement, and provenance behavior remain covered by the existing
tests. Concurrent save/delete coverage and propagation of task-group failures
strengthen the local write regressions.

CI's ownership diagnostic gate now includes storage adapters and `GeoDrop`.
It requires each boundary to compile and rejects its warnings/errors. The TSan
lane also includes local-store and library tests. The project remains in Swift
language mode 5 with complete concurrency checking. The real whole-app Swift 6
SIL compile passes with zero diagnostics; this records compiler compatibility,
not an untested change of production language mode.

## VPS correction ordering

Every accepted pose has capture time, sequence, session generation, and anchor
generation. The engine checks the current anchor binding before delivery, and
the correction policy rejects older accepted versions. A new target replaces
the deferred target; it also interrupts an active holder glide toward an older
target. Only holder placement animation is stopped, preserving child content
animations. Pose decisions consider translation, viewing angle, and rotation.
The deadband and immediate-update limits are deliberately small; visible larger
refinements wait for an offscreen opportunity, and gross positional errors glide.

Gesture start protects the drop before its first slider value tick. A committed
height, facing, or geographic relocation clears obsolete correction state and
invalidates even an unresolved anchor request. A temporary authored-placement
overlay feeds re-pinning and GPS placement until the asynchronous library update
publishes matching placement fields. It preserves current library metadata,
prunes absent IDs, and caps pending entries at 128. This closes the window in
which re-pinning could reuse pre-edit height or facing values.

The previous phase's single-consumption VPS heading estimator remains in place.
Four overlay tests and ten correction-policy tests cover newer/older ordering,
yaw-only changes, glides, edits, generation changes, metadata retention and bounds.
These tests exercise the production helpers. Physical RealityKit animation
interruption and visual stability remain explicit device acceptance checks.

## Final-source verification

| Check | Result |
| --- | --- |
| Full current-iOS suite (26.5) | **283 passed, 0 failed, 0 skipped**, including the real native Firebase SDK against a disposable emulator. |
| Full minimum-iOS suite (17.0.1) | **282 passed, 0 failed, 1 skipped**. The opt-in emulator contract passed in the current lane. |
| Debug and unsigned Release builds | Passed with **zero app diagnostics**, down from 19; all 16 required ownership boundaries compiled. |
| Whole-app Swift 6 SIL compile | Passed using the real app, installed SDK and compiled dependency context, with zero warnings/errors. |
| Thread Sanitizer | **105 passed, 0 failed, 0 skipped** across the expanded AR/storage/correction suite, with no reported races. The app binary links the iOS Simulator TSan runtime. |
| Config-free launch smoke | Home and unsupported-camera surfaces appeared and survived on both runtimes; all four screenshots inspected. This is Debug simulator launch evidence. |
| Rules and release smoke | 8 drift, 59 current-rules and 6 historical-rules tests passed; all 42 disposable-emulator release smoke checks passed. |
| Tooling checks | Six diagnostic gate tests, existing baseline and simulator selector tests, release verification script tests, CI YAML parsing, and whitespace checks passed. |

The source fingerprint covers all 93 app/test Swift and Metal files. Full logs,
commands and result bundles are retained under `/tmp/amr-phase2-sep30`. Initial
pre-review results are retained separately and excluded from the final counts.
Live-service integration tests and real service configuration are excluded from
simulator and unsigned Release validation.

The [verification record](implementation-evidence/2026-09-30-phase2/verification.json),
[source fingerprint](implementation-evidence/2026-09-30-phase2/tested-source.json),
test summaries and diagnostic inventories identify the tested working tree.
Signed delivery manifests record the later commit and installation separately.

## Remaining acceptance

Issue #7 also requires persisted geographic uncertainty and source information,
appropriate write-back policy, and a second-device comparison; this phase's
correction mechanics do not establish geographic accuracy. Physical render
teardown, release startup, sustained heat, memory and frame pacing, and placement
walks remain phone-last. Simulator results cannot close those field criteria.
