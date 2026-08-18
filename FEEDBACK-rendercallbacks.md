# Feedback Assistant draft — RealityKit ARView.renderCallbacks threading contract

**For the owner to file at feedbackassistant.apple.com. Paste the FB number into
DECISIONS.md's honest-unknown line (search "FB number goes here").**

- **Area:** RealityKit
- **Type:** API / Documentation Request
- **Title:** ARView.RenderCallbacks: undocumented synchronization between
  main-actor writes and render-thread reads of prepareWithDevice / postProcess

## Description

`ARView.renderCallbacks.prepareWithDevice` and
`ARView.renderCallbacks.postProcess` are properties of a @MainActor-isolated
view, and our app assigns them exclusively from the main actor, as the declared
isolation prescribes. RealityKit's render loop, however, invokes these closures
from its own render thread.

Neither the ARView.RenderCallbacks documentation nor the headers state the
synchronization contract between a main-actor assignment (including assignment
to nil during teardown) and an in-flight render-thread read of the same slot.
Specifically:

1. If the main actor assigns `postProcess = nil` while the render thread is
   between reading the closure reference and invoking it, is the previously
   read reference (and its captured context) kept alive by RealityKit for the
   duration of that frame, or can the closure's context be released while the
   render thread still holds a raw reference?
2. Is there any point in the frame lifecycle (e.g. between `postProcess`
   completion and the next `prepareWithDevice`) at which an assignment is
   guaranteed not to race a read?
3. `session.pause()` does not appear to be a quiescence point — SceneEvents
   continue to fire on a paused session — so there is no evident way for an
   app to know the render thread is not mid-read.

## Why it matters

Apps that attach the callbacks only while they have work (to avoid the
offscreen-render + full-screen-copy cost of an idle pass) must toggle these
slots at runtime. Without a documented contract, the only available mitigation
is rate-limiting the toggles (we enforce a dwell floor), which reduces but
cannot eliminate the window. Thread Sanitizer cannot observe the render
thread's read (it is inside RealityKit), so the question is not answerable
empirically from the app side.

## Request

Either document the synchronization RealityKit performs on renderCallbacks
slot access, or expose an explicit synchronization point / atomic swap API for
installing and removing render callbacks at runtime.

- **Configuration:** iOS 26.x, RealityKit ARView (cameraMode: .ar,
  automaticallyConfigureSession: false), callbacks toggled from the main actor.
