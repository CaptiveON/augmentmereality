# Native Firestore authoritative-read regression

This explicit, local test uses the pinned iOS Firestore SDK. It is separate from
the JavaScript authorization suite and never runs `FirebaseIntegrationTests`.
Its intentionally narrow SDK fixture rules **must never be deployed**.

Prerequisites: Xcode with an available supported simulator, Python 3, Node,
Firebase CLI and a Java runtime supported by the Firestore emulator. The
September 2026 verification uses Xcode 26.6 and iOS 26.5. The separately tracked
minimum-iOS launch problem is not fixed by this test.

Run from the repository root, replacing the simulator identifier:

```sh
bash web/rules-tests/run-native-sdk-tests.sh SIMULATOR_UDID
```

CI uses the full local suite, including the opted-in native regression, while
excluding only the separate live Firebase integration test:

```sh
AMR_ALL_LOCAL_TESTS=1 bash web/rules-tests/run-native-sdk-tests.sh SIMULATOR_UDID
```

An optional second argument points to an existing Xcode `SourcePackages` cache.
The wrapper explicitly fetches the versions pinned in `Package.resolved` on a
fresh runner, disables automatic package resolution during the build,
builds a Debug host with signing disabled, and keeps derived data/logs/results in
a new `/tmp/amr-native-sdk.*` directory. `AMR_TEST_OUTPUT_DIR` can select an empty
artifact directory. Set `JAVA_HOME`/`PATH` if Java is not already available.

Before launching, the wrapper verifies that neither `GoogleService-Info.plist`
nor `Secrets.plist` was bundled. It writes an opt-in environment flag only into
the generated `.xctestrun`. Normal unit runs skip the emulator test. The probe is
compiled only for Debug, has no startup caller, creates a named Firebase app
with synthetic options, and uses only `demo-amr-native-sdk` and fixed loopback
ports: control `8187`, Firestore `8188`, HTTP/2 proxy `8189`.

The proxy holds Firestore's streaming Write RPC while allowing Listen and
transaction reads/commits. The native test proves all of the following:

- With a real local pending delete, the old `.server` read reports missing and
  `hasPendingWrites == false` even though the remote document still exists.
- The transaction-backed helper still sees the remote document, and continues
  to see it after the fixture rejects the queued delete.
- An acknowledged delete produces authoritative absence.
- A read-denied document produces permission denied, never absence.
- A stalled transaction read returns no snapshot by its deadline. A subsequent
  read succeeds after releasing the gate, exercising late completion.
- The native `DropReaction` encoder and acknowledged-write seam produce exactly
  the expected five fields, including a Firestore timestamp, in a server round trip.

Nonzero gate counters are asserted so accidentally bypassing either proxy path
cannot pass. The fixture seeds synthetic documents using the emulator's local
admin interface; it does not use credentials, the default Firebase app, account
creation, or any production endpoint. It validates SDK semantics and the helper;
the normal rules suite still owns actual authorization policy. Review the
`.xcresult` and logs: a skipped/unexecuted native test is not a passing regression.

Before launching `xcodebuild`, the harness verifies that the database itself is
ready by completing an emulator REST write/read/delete round trip and checking
the returned document name and marker. This uses a 60-second monotonic budget
and at most 15 seconds per backend request. Transient retries reuse the same
synthetic document ID and identical payload; malformed responses fail at once.
A failed warm-up exits before tests launch and never counts as an exercised
native RPC gate. The wrapper runs the Firebase CLI from the artifact directory
so emulator diagnostics are retained there, with `DEBUG` unset.

The initial simulator-to-fixture readiness request has a separate 30-second
monotonic setup budget, with at most five seconds per request and retries only
for transient transport errors. A wrong fixture/project response or missing
backend-ready marker fails at once. Other fixture control requests have a
30-second timeout; seed writes use a single attempt with a 20-second backend
abort, without blindly retrying a potentially acknowledged mutation.
Attempt and received-request counts distinguish client startup from an absent
server; each control/backend operation logs receipt, status, and elapsed time.
Actual SDK deadlines and assertions remain unchanged, including the 0.2-second
unresponsive-read deadline and its two-second completion assertion.
To force a first-request timeout and verify recovery locally, run with
`AMR_NATIVE_READY_DELAY_MS=6000`; only the first `/ready` reply is delayed. The
native test and both RPC gates must still execute and pass.
To exercise a slow first seed, use `AMR_NATIVE_SEED_DELAY_MS=6000`; only that
seed is delayed, and a passing native run must still have exactly three seed
requests, proving that setup recovery did not duplicate the mutations.
