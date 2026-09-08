# Firestore release procedure — issue #2

**Status: v3 deployed and verified on September 8, 2026; device acceptance and next-day verification are in progress.** Keep [issue #2](https://github.com/CaptiveON/augmentmereality/issues/2) open until the remaining client and next-day checks pass. This procedure deploys only Firestore rules for the default database.

## Authorized September 8 rollout

The user explicitly authorized completing issue #2, including the proposed merge, rules-only release and controlled checks. [PR #33](https://github.com/CaptiveON/augmentmereality/pull/33) was merged as `e54285d9875480a2a60a43a6ebb332fa9966b255`; its tree exactly matches tested commit `a4aeff7f9d1b6fd4e3cf9a57bd88eecda192df35`. The previously exposed Firebase CLI login was revoked and replaced through user-completed browser authentication.

- Firebase CLI 15.23.0 deployed only `firestore:rules` to `augmentmereality` at **2026-09-08 12:47:32 UTC**. The operator account is recorded privately.
- The [active release export](rules-releases/2026-09-08-after-rollout/release.json) identifies ruleset `a2f0de32-da20-4a9e-aba7-d5da8afee2a3`. Exact active source SHA-256: `cd613a6be99c86e071cf4782d4e170731363b0a9496b4d781007e12d02c457b6`, matching the reviewed v3 candidate.
- [Controlled live checks](rules-releases/2026-09-08-after-rollout/live-checks.json) passed all 42 authorization cases, after emulator validation. Their disposable identities/documents were cleaned up. Requests used Firebase user ID tokens; they did not bypass Security Rules with operator credentials. Enumeration probes use a zero-result cap so no user documents are returned.
- [Release build 0.9.0 (2)](rules-releases/2026-09-08-after-rollout/client-build.json) was signed, installed and launched on the paired iPhone 15 Pro Max running iOS 26.6. Device observations and remaining checks are recorded in the issue. This does not claim distribution to other users or App Store/TestFlight publication.
- App Check enforcement remains **unknown** because the API omits its mode. No enforcement, hosting, indexes or functions configuration changed.

The next-day verification is due **September 9, after 12:47:32 UTC (13:47:32 London time)**. Capture a fresh active release, repeat controlled access checks and verify receive/delete recovery on the patched client. Do not close the issue merely because deployment or installation succeeded.

The post-merge CI run failed in the first native SDK transport setup read, before the regression's held-request gates. The test fixture now gives that initial read one bounded 30-second startup window and requires the seeded document to be present. Production deadlines and all subsequent native assertions are unchanged. The six-second transport-delay control reproduces the old failure and passes all 157 tests with the correction; a 35-second delay still fails before the held-request gates. Record the follow-up PR's hosted result separately.

## Repeatable controlled live checks

The operator runner is [scripts/firestore-release-smoke.mjs](../scripts/firestore-release-smoke.mjs). Its emulator mode is exercised by CI. Live mode is opt-in and accepts only the fixed production target; it requires a fresh matching release export and the configured app plist. It creates two anonymous test identities, limits writes to its generated IDs, tests 42 allow/deny cases, and removes the fixtures and identities afterward.

From the repository root, first capture a fresh release into a new directory outside Git, then run:

```sh
node --use-system-ca scripts/verify-firestore-release.mjs --output /tmp/amr-next-day-release --expect-candidate
node --use-system-ca scripts/firestore-release-smoke.mjs --production \
  --output /tmp/amr-next-day-checks \
  --release-evidence /tmp/amr-next-day-release/release.json \
  --app-config AugmentMeReality/Support/GoogleService-Info.plist
```

Use fresh output paths each time. The parent directory must exist outside any Git checkout. `results.json` contains redacted verdicts and the exact runner hash. The private cleanup ledger contains test credentials only while needed, and is removed after successful cleanup; never publish that ledger. A failed or uncertain mutation is not blindly retried. If cleanup fails, keep the private ledger for a targeted recovery of only that run's test IDs. These REST checks do not replace native offline/tombstone or UI acceptance.

To exercise the same checks without production access:

```sh
env -u DEBUG firebase --config web/firebase.release-smoke.json \
  --project demo-amr-release-checks emulators:exec --only firestore \
  'node scripts/firestore-release-smoke.mjs --emulator --output /tmp/amr-release-emulator-checks'
```

## Verified target and pre-rollout baseline

The app's local Firebase configuration was checked against [firestore-target.json](firestore-target.json): project `augmentmereality`, project number `895624785272`, default database `(default)`, iOS bundle `com.adnan.augmentmereality`. Configuration values are identifiers, not credentials. Do not use a CLI's default project; this workstation's gcloud default points to an unrelated project.

At **2026-09-08 03:18:12 UTC**, a read-only API inspection confirmed:

| Evidence | Value |
| --- | --- |
| Release | `projects/augmentmereality/releases/cloud.firestore` |
| Active ruleset | `680529bf-416d-44b2-aef8-347ab6584664` |
| Release updated | `2026-07-09T01:11:10.207900Z` |
| Active source SHA-256 | `bfbd52d0c34dcc43e0624ff3f0eb6fa2495065547cacc41e304385c96d0a65bf` |
| Candidate SHA-256 | `cd613a6be99c86e071cf4782d4e170731363b0a9496b4d781007e12d02c457b6` |
| Candidate active? | **No** |
| App Check enforcement | **Unknown**: service read succeeded but the API omitted `enforcementMode` |

The [metadata](rules-releases/2026-09-08-before-rollout/release.json) and [exact exported source](rules-releases/2026-09-08-before-rollout/active-0.rules) are evidence at that time, not a continuously updated claim. No user documents were read. The active v2 expressions permit cross-owner replacement by stamping the incoming owner, and shared-visibility collection enumeration. Emulator tests reproduce those vulnerabilities in [a historical fixture](rules-tests/fixtures/firestore.v2.rules); that fixture is separately labelled and **must never be deployed**.

The candidate is [firestore.rules](firestore.rules). Its authorization expressions are the existing prepared v3 contract; this change adds trustworthy verification and stronger compatibility gates, rather than silently widening policy. Exact-id sharing, authenticated absent-document GET/DELETE, owner-only listing and immutable ownership remain intentional.

## Read-only verification

Requirements: Node 22+, Firebase CLI 15.23.0, an authorized Firebase account with permission to read releases and rulesets. The verifier defaults to the Firebase CLI's sole cached account; with multiple accounts, select `--account EMAIL`. `--auth gcloud` is also supported with an explicitly authorized account. Do not paste access tokens or run `firebase login:list --json` into logs: that command includes credentials.

From the repository root, use a **new** directory for every observation:

```sh
node scripts/verify-firestore-release.mjs --output web/rules-releases/YYYY-MM-DD-before
```

On a Mac whose Node trust store needs system certificates, add `--use-system-ca` before the script path. The script performs only metadata/source GETs, repeats the release read to detect concurrent deployment, hashes the exact bytes, sanitizes auth errors and refuses to overwrite evidence. It obtains credentials in memory and removes temporary CLI logs. The source names supplied by the API never become local paths.

The Rules REST API's [release lookup](https://firebase.google.com/docs/reference/rules/rest/v1/projects.releases/get) identifies the active ruleset; its [ruleset lookup](https://firebase.google.com/docs/reference/rules/rest/v1/projects.rulesets/get) supplies source. App Check is recorded independently using the [service lookup](https://firebase.google.com/docs/reference/appcheck/rest/v1/projects.services/get). An omitted field or failed read is unknown, never proof that enforcement is off. This release must not change App Check enforcement.

## Client compatibility change

An ordinary Firestore `.server` read still includes pending local writes. A pending delete can therefore produce `exists == false` even while the server document exists. Firebase iOS 11.15 also reports `hasPendingWrites == false` on deleted snapshots, so checking metadata does not fix this. See the [Swift source contract](https://firebase.google.com/docs/reference/swift/firebasefirestore/api/reference/Enums/FirestoreSource) and the pinned SDK implementation in [document_reference.cc](https://github.com/firebase/firebase-ios-sdk/blob/fdc352fabaf5916e7faa1f96ad02b1957e93e5a5/Firestore/core/src/api/document_reference.cc).

`FirestoreServerRead` uses a transaction containing one read and no data writes. Transaction reads exclude uncommitted local changes ([SDK contract](https://github.com/firebase/firebase-ios-sdk/blob/fdc352fabaf5916e7faa1f96ad02b1957e93e5a5/Firestore/Source/Public/FirebaseFirestore/FIRFirestore.h)). Callers accept only the completed transaction result; denial, concurrent modification, timeout and cancellation remain unknown. The caller waits at most ten seconds; the SDK cannot cancel its already-started RPC, and late completions are discarded. It is used for receive absence, individual tombstone retirement and capability probing. A denied capability is retried on a subsequent refresh after 60 seconds of monotonic uptime, or immediately after an auth identity change.

Record the client build/version tested and distributed with this release. Older clients retain the local-delete-overlay bug after v3 starts permitting absence reads. Rules deployment cannot install this client fix; do not claim that server rollout alone fixes every client. Coordinate distribution of the patched build with the operator while treating the confirmed v2 authorization exposure as urgent.

## Gates before authorization

During September 8 preparation, `main` had no enforced required status checks. The [previous CI run](https://github.com/CaptiveON/augmentmereality/actions/runs/32201076010) failed before any job steps because GitHub reported an account payment/spending-limit restriction. Neither branch mergeability nor a configured workflow waives the execution gate below; record the new PR's actual result separately. Repository billing or branch-protection changes are not part of this rules release.

1. Freeze the reviewed commit and candidate bytes. Record the commit, rules hash, Firebase CLI version and client build. Ensure the PR's required jobs **actually ran and passed on that commit**; a skipped or never-started workflow is not a pass.
2. Run the complete emulator suite, including historical regression and Swift encoder/emoji drift checks:

   ```sh
   cd web/rules-tests
   npm ci
   env -u DEBUG firebase --version
   env -u DEBUG npm test
   ```

   Java 21+ is required. On this workstation, set `JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home` if `/usr/bin/java` has no runtime. The project is the disposable `demo-amr-rules`; the harness refuses non-loopback emulator hosts. Historical assertions deliberately demonstrate v2 failures, never certify production.
3. From the root run `node --test scripts/verify-firestore-release.test.mjs`. Run affected Swift receive/delete/reaction tests and the opt-in [native SDK emulator regression](rules-tests/NATIVE-SDK-TESTS.md). Use the pinned packages and an isolated simulator build with both real service plists excluded. Do not run the live `FirebaseIntegrationTests` as an automatic gate. The asset test validates decode/clone behavior and records diagnostic timing on a simulator; its unchanged 250 ms main-actor gap and 800 ms clone performance limits are physical-device gates (ADR-047). A simulator pass does not satisfy those performance bars.
4. Review the fresh live export and the delta to the candidate. Confirm current owner refresh, exact-link receive, reaction-before-parent, absence and idempotent deletion compatibility. Record release operator and their authorized account privately; do not record tokens, private recipient data or emails in artifacts.
5. Obtain authorization for the concrete rules-only production release, naming the reviewed commit/hash and project. Issue #2 explicitly separates this action from implementation. No production writes or deployment have been performed during preparation.

## Authorized operator release

Record the operator, approval reference and UTC start time in the issue. From a clean checkout of the approved commit, confirm the candidate hash still matches the review. Use the explicitly selected authorized account, and run from `web`:

```sh
env -u DEBUG firebase deploy --only firestore:rules --project augmentmereality --account AUTHORIZED_ACCOUNT
```

Do not deploy hosting, indexes, functions, auth configuration or App Check in this operation. Capture a new release export from the repository root:

```sh
node scripts/verify-firestore-release.mjs --output web/rules-releases/YYYY-MM-DD-after --expect-candidate
```

Exit 0 means the exact source matches this checkout; exit 2 records a mismatch and is a failed release verification. Authentication/network errors exit 1. Attach the new release identifier, timestamp, source hash and redacted command result. If the release changes during capture, repeat into a new directory. Rule changes can take several minutes to reach active requests; distinguish API metadata from observed client behavior ([Firebase deployment guidance](https://firebase.google.com/docs/rules/manage-deploy)).

## Controlled post-release and next-day checks

These are **pending** and require the authorized target and isolated test identities/documents. Never probe another user's objects. Use two disposable signed-in test identities (owner A and viewer B), fresh random drop/reaction IDs, and no personal content or location. Record IDs privately for cleanup and retain only redacted verdicts in the issue.

| Check | Required result |
| --- | --- |
| A creates, reads, edits and lists its own private/link/public test drops | Allowed; owner-filtered refresh succeeds |
| B reads A's exact link/public IDs | Allowed; private exact-ID GET denied |
| B overwrites A's drop with B as owner; merge-owner takeover; A transfers owner to B | All denied; A's original content/owner verified unchanged |
| B lists unfiltered drops, shared/public visibility queries, or A's owner-filtered query | All denied |
| Allowed reactions, including queued-before-parent and four shipping emojis | Allowed with correct author; wrong author/extra keys/disallowed emoji/update denied |
| Signed-in missing GET and repeated DELETE of test ID | Server-confirmed missing and idempotent success |
| Receive deleted test link on patched client | `.gone` only after authoritative missing read; denied/offline remains retryable/unknown |
| Queue a delete while offline, refresh, reconnect and receive acknowledgement | No premature tombstone retirement; tombstone retires after acknowledged delete or authoritative absence |
| Begin with denied capability, then refresh after rollout/backoff | Existing session recovers without app restart; preserved tombstones are resolved only with per-document evidence |
| Repeat receive, owner refresh, reactions and pending-tombstone recovery next day | Same behavior after relaunch/reconnection; no unexpected permission errors |

Clean up only the owned test drops/reactions/profiles after recording results. Capture a next-day active-release export to tie those checks to a release. Close #2 only after the verified safe active policy and these checks pass; prepare a follow-up if client distribution remains incomplete.

## Failure response and remaining scope

If the candidate hash mismatches or compatibility checks fail, stop the rollout, preserve redacted evidence, and investigate exact identity/query/path and propagation before changing policy. If exposure is found after rollout, stop further mutation, capture the active release, and prepare an emulator-tested forward correction or narrowly scoped deny policy with explicit approval and documented feature impact. **Do not restore the vulnerable v2 snapshot as a rollback.** A previous release is only eligible after its exact policy has independently passed the same authorization gate.

This contract intentionally permits authenticated exact-id missing reads and capability-based reactions even before the parent exists. The reaction key rule is an upper bound, not full type/required-field validation. Abuse/rate controls, stricter reaction schema, identity migration, moderation and App Check enforcement need their own coordinated changes. This release also does not resolve AR thermal, occlusion or placement issues.
