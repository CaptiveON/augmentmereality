# Render and perception ownership, 2026-09-30

**Later issue 11 update:** the inventory below preserves the earlier runtime-batch
review and test counts. The [capture contract](FRAME-DEPTH-CONTRACT-2026-09-30.md)
and [new validation](IMPLEMENTATION-STATUS-2026-09-30-ISSUE11.md) supersede its
unfenced-history limitation: only one matte GPU command can now be in flight;
completion invalidates failed history before reopening admission. Completion
enters the pass lock before lifecycle/cache cleanup, never in reverse order.
Leases explicitly retain source pixel buffers as well as their wrappers. Neural
output is now copied to bounded app-owned Metal-compatible buffers and feed
publication checks capture-stream revision in addition to generation. The later
whole-app Swift 6 compile has zero diagnostics. Physical acceptance is still open.

This inventory covers the issue #8 render boundary at the September 30 source
state. It is a code and SDK review, not evidence of physical render-thread or
thermal behavior.

| Reference | Owner and transfer | Last use and release |
| --- | --- | --- |
| `ARView.renderCallbacks`, `ARView.session` | The manager calls `SemanticOcclusionPass.prepare(on:)`, `setCallbacksActive(_:)`, and `uninstall()` on the main actor. Installed callbacks capture the pass strongly; the pass holds the view weakly. The installed RealityKit SDK declares `renderCallbacks` `@MainActor @preconcurrency`. | The main actor removes both slots on detach. A callback already copied by RealityKit keeps the pass alive and blits its target, but its captured epoch cannot read state from a later attachment. Uninstall is terminal for that pass. |
| `ARSession.currentFrame` and `ARFrame` buffers | `SemanticOcclusionPass` reads the session reference under `stateLock` only after its callback epoch and work admission pass. The pass holds each returned frame locally for the CPU encode. `SemanticFeed` and `MidFieldDepthFeed` return retained pixel-buffer references under their own locks. | The CPU callback releases its frame/feed references on return. Every successfully wrapped buffer's `CVMetalTexture` moves to a `RenderGPUResourceLease` before `stateLock` unlocks and remains until command-buffer completion, including an error completion. |
| Metal pipeline, textures and cache | Pipeline compilation and dummy creation occur outside `stateLock`; publication checks the epoch inside it. `RenderTextureCache` serializes all Core Video create/flush operations. Each compute submission leases all bound textures, pipeline, cache and wrappers. | Detach/uninstall can clear pass fields after the current CPU encode unlocks. The GPU lease releases wrappers/textures only on completion, then the cache performs a deferred flush after its final outstanding lease. A frame that bails before submission drops any partial wrappers and flushes immediately. |
| `MidFieldDepthEstimator` ARKit input | `update(frame:)` extracts image/depth buffers without capturing `ARFrame`. A single `SourceBox` transfers those two SDK references to the serial worker; its `busy` gate admits at most one job. The worker makes pooled app-owned copies before running Vision. | `SourceBox.empty()` releases both ARKit buffers before inference. Every early stale-admission exit empties it, and closure destruction releases it if the estimator is gone. Copied buffers and Vision output live through fit/publication only. `MidFieldDepthFeed` checks the admission token again at publication, so an old result cannot enter a new run. |
| `MidFieldDepthEstimator.WorkerResources` | This narrowly `@unchecked Sendable` holder is created before queue use; only the `midfield-depth` serial queue touches its `VNCoreMLModel`, `VNCoreMLRequest`, and pools. Outer admission, busy and readiness state is in `OSAllocatedUnfairLock`. | The model, reusable request and pools live with the estimator. An invalidated job releases input copies after its current CPU operation and cannot publish into a later generation. |
| `PersonSentinel` ARKit input and Vision request | One immutable `CaptureBuffer` box transfers a pixel buffer into the serial `person-sentinel` queue. The lock-protected `busy` flag limits this to one ARKit surface at a time. The reusable request is confined to that queue; presence and admission state is locked. | The capture buffer remains held through queue wait and Vision inference, then releases with the closure. Admission is checked before inference and again before presence publication. A stale job may finish its current inference but cannot set `lastSeenAt` for a new generation. Queue wait plus inference hold is measured. |

`RenderCallbackLifecycle` counts entered CPU callbacks and submitted GPU commands
across detach. `stateLock` serializes CPU encode against state teardown; the
lifecycle epoch rejects old callbacks after reacquisition. GPU counts may
remain nonzero after uninstall because the lease, rather than pass fields,
owns resources until Metal calls its completion handler. The Metal SDK describes
that handler as running after command-buffer execution; the pass does not
assume RealityKit's `retainedReferences` setting. Lock order is pass
`stateLock` → lifecycle/feed/cache lock. Completion only enters lifecycle and
cache locks; neither calls back into the pass.

The pass attaches only on demand. Dwell and work admission remain manager
policy, and a detached pass has no postprocess copy cost. A late callback still
copies source to target because RealityKit's postprocess contract requires a
target write. The current matte history assumes RealityKit submits successive
postprocess command buffers in an order that preserves the prior frame's
texture dependency; this code change does not establish a cross-command-buffer
history fence.

The early isolated Swift 6 / iOS 17 probe used app-only dependency stubs. The
subsequent real-app SIL compile and simulator TSan results are recorded in the
[integrated verification](IMPLEMENTATION-STATUS-2026-09-30.md). The real-app
compile reports only the 19 pre-existing storage ownership errors; the 30
targeted simulator TSan tests pass without reported races. Physical
lifecycle/thermal behavior remains a separate acceptance gate.
`RenderLifecycleTests` exercises controlled CPU/GPU overlap, stale epochs,
terminal uninstall, GPU lease retention with a real `CVMetalTexture` on a Metal
command buffer, and an old production callback's target blit. Existing copy
and admission tests cover planar buffer copies and stale
depth publication; the tests do not prove RealityKit's private render-thread
scheduling on a physical iPhone.

Installed public declarations reviewed: RealityKit 26.5
`ARView.renderCallbacks` and `PostProcessContext` Swift interface; Metal
`MTLCommandBuffer.addCompletedHandler` and `retainedReferences` headers; Core
Video `CVMetalTextureCacheFlush` header; ARKit `ARSession.currentFrame` and
`ARFrame` headers. Apple references:
[renderCallbacks](https://developer.apple.com/documentation/realitykit/arview/rendercallbacks-swift.property),
[postProcess](https://developer.apple.com/documentation/realitykit/arview/rendercallbacks-swift.struct/postprocess),
[Metal completion](https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler(_:)),
[retainedReferences](https://developer.apple.com/documentation/metal/mtlcommandbuffer/retainedreferences),
[Core Video cache flush](https://developer.apple.com/documentation/corevideo/cvmetaltexturecacheflush(_:_:)).
