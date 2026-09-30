# Capture, render and depth sample contract, 2026-09-30

This records the phone-free issue [#11](https://github.com/CaptiveON/augmentmereality/issues/11)
implementation design. It describes source contracts and rejection policy, not
verified physical pixel registration. Build and test results belong in the
[build ledger](BUILD-AND-ISSUE-STATUS.md); physical acceptance remains open.

## Identity and geometry

`OcclusionCapture` extracts immutable metadata from one `ARFrame`: perception
generation, capture-stream revision, `ARFrame.timestamp`, camera-to-world pose,
intrinsics in the captured image's pixel coordinates, image resolution and
tracking state. The tuple `(generation, stream revision, timestamp)` identifies
the capture. Every `ARSession.run`, including a configuration-only or thermal
change, increments the stream revision. The manager disarms render admission
before the run and re-arms it after the call with a new uptime boundary; old
samples and in-flight depth completions cannot publish into the new stream.
The metadata does not retain an `ARFrame`.

An `OcclusionRaster` adds stored dimensions, a normalized top-left-origin
`captureToSample` UV transform, a valid UV support rectangle, pixel encoding,
confidence meaning, producer provenance and buffer ownership. The current
ARKit camera, person stencil and scene-depth adapters use the full capture UV;
Vision's explicit `.up` / `.scaleFill` request uses full normalized UV despite
different output dimensions. The shader receives separate capture-to-semantic,
person, scene-depth and neural-depth matrices, plus the inverse person map for
its luma-guided filter. All production adapters currently declare full unit-square
support; the shader treats coordinates outside that square as unknown and leaves
rendered content in place. A future partial-support adapter must also pass its
support rectangle to the shader before consumption. Asymmetric transform and
stride fixtures belong to the synthetic contract tests; sensor crop and
registration still need phone evidence.

Depth and confidence types have distinct meanings:

| Source | Stored value and geometry | Confidence or ownership |
| --- | --- | --- |
| ARKit `sceneDepth.depthMap` | `DepthFloat32`; optical-axis distance from the camera plane in meters, aligned to a region of `capturedImage` | ARKit's optional depth confidence map is discrete low/medium/high level data, not a probability or foreground mask. The depth buffer is framework-pool retained for CPU use and GPU completion. |
| ARKit `segmentationBuffer` | `OneComponent8` foreground coverage in capture UV | Coverage is a matte weight, not LiDAR depth confidence. Framework-pool retained. |
| GAR semantic label and confidence images | `OneComponent8` class label and `OneComponent8` confidence (0–255) | Confidence describes the selected class probability. Buffers are retained from the GAR result and released at disable/reset or after GPU completion. |
| Vision relative depth | `OneComponent16Half` unitless model output in `.up` / `.scaleFill` UV | A separately validated per-capture inverse-depth fit (`1/meters ≈ a·relative + b`) provides only bounded metric support. Output is copied to a Metal-compatible app-owned buffer before publication. |

Apple defines `ARDepthData` as distance from the camera plane in meters and
describes its separate confidence map in the
[ARDepthData reference](https://developer.apple.com/documentation/arkit/ardepthdata).
Google documents the semantic formats and 0–255 class confidence in its
[iOS Scene Semantics guide](https://developers.google.com/ar/develop/ios/scene-semantics)
and [GARFrame reference](https://developers.google.com/ar/reference/ios/interface/GARFrame).

## Render association and rejection

The installed RealityKit `ARView.PostProcessContext` exposes rendered color and
depth textures, a projection and scene elapsed time. It supplies neither the
rendered `ARFrame` identity nor render camera pose; its
[`time` is scene elapsed time](https://developer.apple.com/documentation/realitykit/arview/postprocesscontext/time),
so it is never compared with `ARFrame.timestamp` or converted using an invented
clock offset. Reading `session.currentFrame` in the callback yields a candidate
capture, **not** proof that it supplied RealityKit's background. The only
production admission is explicitly **approximate** and bounded:

- A candidate capture is normal-tracking, in the current generation and stream,
  newer than the stream/admission boundary and no more than 50 ms old at the
  callback. Viewport orientation/size must be valid and observed within 50 ms.
- Four or fewer recent capture metadata records must span at least 30 ms, with
  no adjacent capture gap above 75 ms. Across that history, translation is at
  most 1.5 mm and rotation at most 0.003 radians; intrinsics must agree within
  0.25 source pixel and image resolution must be unchanged.
- The viewport/target aspect, inverse ARKit display transform and x/y projection
  of asymmetric camera rays must agree with the render context to within one
  target pixel. Scene time is used only to reject duplicate or backward render
  callbacks. Any mismatch, reset, stale sample, unsupported format or GPU-busy
  condition blits RealityKit source color to target and invalidates temporal
  matte history.

Inference samples have a second capture-to-capture gate after render admission:
same generation/stream/calibration, normal tracking, bounded pose and nonfuture
timestamp. GAR semantics may be at most 0.15 s old; neural depth uses the
configured 0.3 s ceiling. Those age limits bound exposure but do not prove that
a moving person or vehicle stayed in place while the camera was still.

Google says each `GARFrame` corresponds to the submitted `ARFrame` and shares
its timestamp, but describes the semantic images as the **latest** images for
that GAR frame without a separate semantic capture timestamp
([GARFrame](https://developers.google.com/ar/reference/ios/interface/GARFrame)).
Semantic provenance is therefore recorded as SDK-opaque. The current full
normalized-UV mapping follows Google's portrait sample convention and rejects
semantic/camera aspect mismatch; it is an inference, not an SDK guarantee of
per-pixel crop or timing. Semantic consumption is portrait-only because
[Google does not guarantee landscape label quality](https://developers.google.com/ar/develop/scene-semantics).

## Buffer lifetime and GPU order

The serial depth worker copies ARKit camera and LiDAR inputs into bounded
pooled buffers (at most six format pools, four allocations per pool), then empties
its handoff box before Vision inference. Pool saturation drops the sample. If pool
creation itself fails, a direct copy remains bounded by the single worker and
feed/GPU admission limits. It copies
Vision's output to an app-owned, Metal-compatible buffer before publication.
The feed rejects old generation/stream tokens and out-of-order completions.
The render pass validates nonplanar dimensions and format before wrapping each
single-channel buffer; planar camera luma/chroma use their actual plane sizes.
It retains every wrapped `CVMetalTexture`, source `CVPixelBuffer`, bound Metal
texture, pipeline and cache in a completion lease, including failed commands.
Apple explicitly requires the Core Video wrapper to remain strongly referenced
until the command buffer completes
([CVMetalTextureCacheCreateTextureFromImage](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage%28_%3A_%3A_%3A_%3A_%3A_%3A_%3A_%3A%29)).
At most one matte GPU command is in flight; a busy callback blits instead of
waiting on the CPU. A failed command invalidates history before GPU admission
reopens. Detach and reset release unsubmitted wrappers and defer cache flush
until GPU leases finish.

The current inverse-depth fit samples LiDAR below 4 m and caps trusted output
at `depthMax × 1.25`, so its validated surface support is **below 5 m**, even
though the model and original feature description discuss 4–60 m. The shader
refuses extrapolation outside the fitted relative and metric ranges. Extending
safe metric support is part of the later depth-fit work, not demonstrated by
this contract.

Physical acceptance still requires capture/render alignment during pans,
viewport/orientation changes, resume and thermal reconfiguration, delayed GAR
and Vision output, foreground motion, real-device Metal wrapping, buffer-pool
pressure, and thermal/frame-pacing measurements. A synthetic association or
successful build cannot establish RealityKit's private frame provenance.
