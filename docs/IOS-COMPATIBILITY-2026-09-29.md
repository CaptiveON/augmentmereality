# Minimum and current iOS simulator compatibility — 29 September 2026

The app still declares iOS 17.0 as its deployment minimum. Issue [#19](https://github.com/CaptiveON/augmentmereality/issues/19) exposed a launch-time RealityKit symbol failure on that minimum. This record distinguishes the reproduced failure, the source repair, local simulator evidence, and CI coverage that has not yet run remotely. It does not establish physical-device compatibility.

## Reproduced loader failure and repair

On an iPhone 15 Pro Max simulator running **iOS 17.0.1**, a Debug test host built with **Xcode 26.6 (17F113), iOS Simulator SDK 26.5** exited before XCTest connected. The local working tree was based on `18f27d3`; the pinned `Package.resolved` SHA-256 was `899220de4469827ceb4c268f40e5e773afdde71769a9a83a664d0de85df9977e`. The retained local report is `/tmp/amr-sep29/minimum-before.log` (SHA-256 `c3f297bb94e0a84cf66d8097a570ee74253977af95e9ac76e3d510ee8085251f`) and `/tmp/amr-sep29/minimum-before.xcresult`. Its decisive diagnostics are:

```text
dyld: Symbol not found: _$s10RealityKit12AnchorEntityC6anchorACSo8ARAnchorC_tcfC
Referenced from: AugmentMeReality.app/AugmentMeReality.debug.dylib
Expected in: iOS 17.0.simruntime/.../RealityKit.framework/RealityKit
Test crashed with signal abrt before establishing connection.
```

The direct `AnchorEntity(anchor: geoAnchor)` convenience initializer emitted that unavailable symbol. The geo anchor is already added to the AR session; the app now creates its RealityKit entity with `AnchorEntity(.anchor(identifier: geoAnchor.identifier))`. [Apple documents the target initializer](https://developer.apple.com/documentation/realitykit/anchorentity/init%28_%3A%29-9rdwu) and [its AR-anchor identifier case](https://developer.apple.com/documentation/realitykit/anchoringcomponent/target-swift.enum/anchor%28identifier%3A%29). This preserves identifier-based tethering without the unavailable initializer. It is an ABI workaround, not an OS-availability branch; a branch would be too late for a loader failure.

The rebuilt Debug host on the same iOS 17.0.1 simulator started **243 tests, one skipped**, with no missing-symbol error. One `GeoMathTests.testBearingCardinals` assertion failed in that intermediate run; the parent integration is correcting it and will retain the final suite result. The intermediate report is `/tmp/amr-sep29/minimum-fixed.log` and `.xcresult` (log SHA-256 `c719a3f367611ada6a5b01ce4b5bbef4e77001df6d4f6b21f02f96f9f7912e0f`). A Release **device build** also succeeded (`/tmp/amr-sep29/release-build.log`); that is a link/build check, not a Release launch check. `nm -u` on the rebuilt Debug simulator dylib and Release device executable shows the `AnchorEntity` target initializer and `Target.anchor(identifier:)`, with no reference to the missing `AnchorEntity.init(anchor: ARAnchor)` symbol.

## CI gates and retained evidence

The `ios-tests` matrix has explicit **minimum 17.0** and **current stable 26.5** lanes. Both use the `macos-26` arm64 image, Xcode 26.6 build 17F113 and SDK 26.5. GitHub's [runner label table](https://github.com/actions/runner-images/blob/main/README.md#available-images) maps `macos-26` to arm64; its [software manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md#xcode) lists that Xcode path/build, SDK and preinstalled iOS 26.5 simulator. [Apple lists Xcode 26.6 as supporting iOS 15 or later simulators](https://developer.apple.com/xcode/system-requirements), so iOS 17.0 is within the supported range.

The selector records the runner image, architecture, Xcode build, SDK, source commit, `Package.resolved` hash, installed runtimes and exact selected device in `environment.json`. It accepts a patch release within the requested minor (for example, 17.0.1 for the 17.0 lane) but cannot select 17.1 or 26.5 as a substitute. The 17.0 runtime is absent from GitHub's image, so the lane requests that exact version with Apple's documented [`xcodebuild -downloadPlatform iOS -buildVersion 17.0`](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components) flow; download failure or continued absence fails the lane and retains `runtime-download.log`. This download has **not** been validated on a remote GitHub runner. A missing Apple catalog runtime therefore remains a visible coverage failure rather than a green newer-OS test.

Each lane retains the existing Firestore-emulator native regression plus all local client tests, using the locked Swift package versions and a config-free Debug app. The additional launch smoke installs that app, checks for bundled service-secret plists, reaches the non-AR root, then enters the unsupported-camera screen on Simulator with a DEBUG-only launch flag. A unique per-launch token is recorded from view appearance and the process must stay alive; screenshots and `launch-smoke.json` are uploaded with build/test logs, `environment.json`, crash diagnostics and `.xcresult` bundles. The pure selector tests cover no-fallback, patch-version acceptance and device/runtime pairing.

Final local verification supersedes the intermediate cardinal-angle failure:
**iOS 26.5 passed 246 tests**, including the native Firestore emulator contract;
**iOS 17.0.1 passed 245 tests with one emulator opt-in test skipped**. Final Debug
simulator and unsigned Release device builds passed. Exact source, environment,
counts and log hashes are retained in the [implementation evidence](implementation-evidence/2026-09-29/verification.json).

The root and unsupported-camera appearance markers passed on both simulators.
A pre-existing location alert survived the CLI revocation request and covered
the original screenshots; those marker results do not prove an unobstructed UI.
The alerts were subsequently declined through Simulator UI, and the current-OS
Home and unsupported-camera screens were visually verified without them.

Neither remote matrix lane has run for this working tree. Clean first launch,
Release launch and an actual minimum-supported iPhone launch remain separate
checks. Simulator AR-unavailable presentation cannot establish camera tracking,
visual quality or thermal behavior on hardware.
