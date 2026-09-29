# AR runtime implementation status — 30 September 2026

This record covers verification of the local issue #8/#9 batch based on `243eed4`. It supplements the [29 September implementation status](IMPLEMENTATION-STATUS-2026-09-29.md); that batch's results and evidence remain separate. At verification, these source changes were uncommitted and had **not been installed on a phone**; the phone's installed build was `243eed4`. Subsequent signed build and installation records identify the delivered commit separately from this test evidence.

## Implemented in this batch

| Area | Current behavior and boundary |
| --- | --- |
| Scene content (#9) | One admission policy spans geographic and Room Test drops. Selected, edited, imminent and nearby items get stable priority within hard full-model count, relative work, compressed USDZ source, and cue limits. Unloaded geographic drops remain in library discovery; unloaded room drops retain world poses for reselection and reset recovery. Memory and thermal pressure shrink live content, including while the camera is hidden. Late shared-asset callbacks and bright-mode rebuilds cannot turn cues into unbudgeted full models. See the [scene content budget and limits](../Scene-Content-Budget-2026-09-30.md). |
| Streetscape ownership and backlog (#8/#9) | GAR SDK objects and raw mesh pointers stay on the main actor. A bounded per-update copy creates owned value snapshots for background validation. Generation, build-ticket, payload and installed-mesh limits prevent stale asynchronous work from installing or taking a new job's reservation. See [Streetscape ownership and bounds](Streetscape-Ownership-2026-09-30.md). |
| Render and perception ownership (#8) | RealityKit callback slots are main-actor owned. Epoch checks reject callbacks from an old installation, while a copied callback still writes its required target. Successful compute work leases CVMetalTexture wrappers, bound Metal textures and the pipeline through command-buffer completion. Mid-field Vision resources are confined to one worker queue; the person sentinel transfers one capture buffer into its serial queue. See [render and perception ownership](RENDER-OWNERSHIP-2026-09-30.md). |
| Scene update scheduling (#8) | `SceneUpdateAdmission` coalesces RealityKit update notifications into at most one queued or running main-actor wakeup. The callback transfers no `ARFrame`; the actor reads the current frame when it runs. A generation and ticket prevent old callbacks from entering a reattached scene or clearing a newer request's slot. |
| Main-actor boundaries (#8) | `LocationService`, `DropEffects`, and the RealityKit-building `DropEntityFactory` helpers have explicit main-actor ownership. Asset preparation's cost and load callbacks retain their main-actor function types. The migration uses narrow queue or lock ownership for SDK work rather than an app-wide `Sendable` suppression. |
| Diagnostic gate (#8) | CI now runs `scripts/swift-diagnostics.py` after each full native simulator build. It rejects a failed or incomplete build and warnings/errors in the migrated AR ownership boundaries; its parser has separate unit tests. The current-iOS lane also runs the 30 targeted tests with Thread Sanitizer in a separate build directory. This is a scoped warning gate, not a claim that the whole app is Swift 6 ready. No remote CI result is claimed here. |

## Evidence and remaining checks

| Check | Status at this record |
| --- | --- |
| Current-iOS full local simulator suite | **267 passed, 0 failed**, including the real native client against a disposable local Firebase emulator and a real CVMetalTexture/Metal command-buffer lease test. This is simulator evidence, not a physical render or thermal result. |
| Swift 6 compiler probe | The whole-app SIL check reaches **19 existing `DropStore.swift` sending/data-race errors only**. The project language mode remains Swift 5. This probe is a migration inventory, not a Swift 6 build pass. |
| Minimum iOS 17.0.1 | **266 passed, 0 failed, 1 skipped**. The skipped opt-in native emulator contract passed in the current-iOS lane. This includes launching the Debug test host; clean first launch and Release launch acceptance remain separate. |
| Unsigned Release iPhone build | **Passed** with real service plists excluded. Full-compile app diagnostics fell from **114 to 19**; all remaining diagnostics are the existing storage sendability sites. The scoped AR diagnostic gate passed with every required boundary compiled. No physical install or Release launch is claimed. |
| Thread Sanitizer | **30 passed, 0 failed, 0 skipped**, with no reported races in the targeted simulator suite. The app binary links the iOS Simulator TSan runtime. This covers reachable production helpers and callback/Metal probes, not all physical RealityKit scheduling. |
| Diagnostic gate tests / repository checks | **5 tests passed**; CI YAML parsing, emoji/reaction drift locks and `git diff --check` passed. Remote CI remains unexecuted. |
| Physical device | **Pending, phone-last.** Install the new revision before testing. Measure real first-use and sustained memory, frame pacing and thermal behavior with representative heavy assets and dense catalogs. Check render-history ordering across in-flight command buffers and live callback teardown on device. No decoded-RAM or GPU-residency ceiling is established by source-file proxies. |

The [verification record](implementation-evidence/2026-09-30-runtime/verification.json),
[source fingerprint](implementation-evidence/2026-09-30-runtime/tested-source.json),
test summaries and diagnostic inventories identify the exact tested working tree.
All 89 app/test Swift and Metal files still match that fingerprint. Full build
logs and result bundles are retained under `/tmp/amr-runtime-sep30`; log hashes
are in the record. The Swift 6 probe uses the real app and compiled dependency
context through SIL generation, without replacement app types. A plain
typecheck passed but did not expose the later storage data-race diagnostics.

The app's existing field and release gates still apply. This batch is a bounded implementation step toward #8/#9, not closure of their physical acceptance criteria. Storage ownership remains the next Swift 6 migration boundary. Latest-wins VPS corrections (#7), vertical support (#10), hero readiness (#17), consolidated placement state (#18), and the other queued realism/release issues remain subsequent work. The three pre-existing untracked audit/research/plan files remain user material and were not changed for this status record.
