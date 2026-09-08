# Local Firestore rules tests

Use Node 22 (the CI version), Java 21 or newer, and the Firebase CLI. After
`npm ci`, run from this directory:

```sh
env -u DEBUG npm test
```

If Homebrew Java is installed but not discoverable on macOS:

```sh
env -u DEBUG \
  JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
  PATH="/opt/homebrew/opt/openjdk/bin:$PATH" npm test
```

Unsetting `DEBUG` prevents the Firebase CLI from logging the subprocess
environment when an unrelated application has set that variable. The command
uses only the disposable `demo-amr-rules` project and the local Firestore
emulator. The shared harness rejects missing or non-loopback emulator endpoints.

The stages run sequentially:

1. Emoji and reaction-key drift locks, plus tests of the synthesized Codable
   field/type contract. Unsupported encoding customizations fail closed.
2. Authorization and client-contract tests of `../firestore.rules`, including
   read-only transaction verification, acknowledged absence, ownership, query
   scoping, reaction payloads, and an offline reaction flushed before its parent.
3. Historical regression tests of `fixtures/firestore.v2.rules`, demonstrating
   the old overwrite and shared-list weaknesses and old missing-document denials.

The historical fixture is immutable evidence of an earlier rule design. Neither
suite inspects or certifies any production deployment. JavaScript payload tests
also do not execute Swift's Firestore encoder or prove iOS queue durability.

Both emulator suites await client termination and environment cleanup. The
Firebase Node SDK still retains process-level timers afterward on the local
Node 26 runtime, so the runner uses `--test-force-exit` ([available since Node
22.0.0](https://github.com/nodejs/node/blob/v22.0.0/doc/api/cli.md#--test-force-exit))
after tests and hooks finish. Suites are bounded at 60 seconds, current-rule
cases and cleanup hooks at 15 seconds. A failed assertion or hook still produces
a nonzero exit; the flag does not skip work or make failed assertions pass.
