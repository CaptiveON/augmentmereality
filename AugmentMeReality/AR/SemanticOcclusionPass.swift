import ARKit
import CoreVideo
import Foundation
import Metal
import RealityKit
import simd
import UIKit
import os

/// Thread-safe hand-off of the latest Scene Semantics buffers from the GARSession
/// update (main actor) to the RealityKit render thread.
final class SemanticFeed: @unchecked Sendable {
    struct Sample {
        let labels: CVPixelBuffer
        let confidence: CVPixelBuffer
        let labelRaster: OcclusionRaster
        let confidenceRaster: OcclusionRaster
        var capture: OcclusionCapture { labelRaster.capture }
        var sessionGeneration: UInt64 { capture.sessionGeneration }
    }

    private let lock = NSLock()
    private var sample: Sample?
    private var enabled = false
    private var workAdmission = PerceptionWorkAdmission()
    private var streamRevision: UInt64 = 0

    func setStreamRevision(_ revision: UInt64) {
        lock.lock()
        if streamRevision != revision { sample = nil }
        streamRevision = revision
        lock.unlock()
    }

    func setWorkAdmission(_ allowed: Bool, generation: UInt64) {
        lock.lock()
        if workAdmission.setAllowed(allowed, generation: generation) {
            sample = nil
            enabled = false
        }
        lock.unlock()
    }

    /// GAR associates these buffers with its submitted ARFrame. The SDK does
    /// not expose the internal semantic capture timestamp; retain that limit.
    @discardableResult
    func update(labels: CVPixelBuffer?, confidence: CVPixelBuffer?,
                capture: OcclusionCapture) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard workAdmission.allowed,
              workAdmission.sessionGeneration == capture.sessionGeneration,
              streamRevision == capture.streamRevision else { return false }
        guard let labels, let confidence else { sample = nil; return false }
        let labelRaster = OcclusionRaster.captureAligned(
            labels, capture: capture, encoding: .categoricalUInt8,
            provenance: .garSubmittedFrameOpaque, ownership: .frameworkPoolRetained)
        let confidenceRaster = OcclusionRaster.captureAligned(
            confidence, capture: capture, encoding: .confidenceUNorm8,
            confidence: .classProbability, provenance: .garSubmittedFrameOpaque,
            ownership: .frameworkPoolRetained)
        guard labelRaster.matches(labels), confidenceRaster.matches(confidence),
              labelRaster.resolution == confidenceRaster.resolution,
              labelRaster.hasCompatibleCaptureAspect else {
            sample = nil
            ARBaselineMetrics.shared.event("Semantic format rejected")
            return false
        }
        if let old = sample, old.capture.streamRevision == capture.streamRevision,
           old.capture.timestamp > capture.timestamp { return false }
        sample = Sample(labels: labels, confidence: confidence,
                        labelRaster: labelRaster, confidenceRaster: confidenceRaster)
        return true
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value && workAdmission.allowed
        lock.unlock()
    }

    func snapshot(for capture: OcclusionCapture, framesAfter: TimeInterval,
                  maxAge: TimeInterval = 0.15) -> Sample? {
        lock.lock()
        defer { lock.unlock() }
        guard workAdmission.allowed,
              workAdmission.sessionGeneration == capture.sessionGeneration,
              enabled, let sample else { return nil }
        if let reason = RenderFrameAssociation.sampleRejection(
            sample.capture, relativeTo: capture, framesAfter: framesAfter, maxAge: maxAge) {
            ARBaselineMetrics.shared.observe("Semantic rejected " + reason.rawValue)
            return nil
        }
        return sample
    }

    var hasEnabledSample: Bool {
        lock.lock()
        defer { lock.unlock() }
        return workAdmission.allowed && enabled && sample != nil
    }

    func clear() {
        lock.lock()
        sample = nil
        enabled = false
        lock.unlock()
    }

}

/// Wave 4.5 SilhouetteRefiner (ADR-011): a RealityKit post-process that restores the
/// camera image wherever *far* virtual content overlaps pixels labeled
/// building/tree/structure by ARCore Scene Semantics — the per-pixel backstop for
/// "never draw content over a surface it's geometrically behind" where no
/// Streetscape/LiDAR geometry exists. Confidence-feathered, temporally EMA-smoothed.
///
/// RealityKit invokes prepare/postProcess outside the main actor, while its
/// callback slots and ARView.session are main-actor isolated. `stateLock`
/// protects CPU render state and serializes teardown against encode. The
/// separate lifecycle gate rejects callbacks from a prior installation; a
/// successful encode transfers GPU resources to a completion lease before
/// releasing `stateLock`. Lock order: stateLock -> lifecycle/feed locks only.
final class SemanticOcclusionPass: @unchecked Sendable {
    private let feed: SemanticFeed
    private let personOcclusionEnabled: Bool
    /// ADR-031: LiDAR-aligned Depth Anything output for the 4–60 m band; nil when
    /// the feature is off or the device lacks LiDAR (no alignment source).
    private let midDepthFeed: MidFieldDepthFeed?
    @MainActor private weak var arView: ARView?
    private weak var session: ARSession?

    /// Guards EVERY mutable field below (counsel ARP-11/SWE-4). Ordering:
    /// may be held while taking a feed lock; a feed lock is never held while
    /// taking this one.
    private let stateLock = NSLock()
    private let lifecycle = RenderCallbackLifecycle()
    private var workAdmission = PerceptionWorkAdmission()
    private var admittedSince: TimeInterval = .infinity
    private var streamRevision: UInt64 = 0
    private var streamFramesAfter: TimeInterval = .infinity
    private var viewport: RenderFrameAssociation.Viewport?
    private var frameAssociation = RenderFrameAssociation()
    private var lastAssociationDiagnostic: String?
    private var personAdmitted = false
    private var depthAdmitted = false
    private var device: MTLDevice?
    private var pipeline: MTLComputePipelineState?
    private var textureCache: RenderTextureCache?
    /// AUDIT P0: CVMetalTextures must outlive the GPU work that samples them —
    /// releasing the wrapper early is the classic cause of intermittent texture
    /// corruption. Collected per frame, released on command-buffer completion.
    private var inFlightTextures: [CVMetalTexture] = []
    private var inFlightBuffers: [CVPixelBuffer] = []
    private var matteTextures: [MTLTexture] = []
    private var matteIndex = 0
    // 1×1 placeholders so every kernel texture slot is always bound even when a
    // source (semantic labels, scene depth, stencil) is absent this frame; the
    // enable flags gate whether the kernel actually reads them.
    private var dummyUint: MTLTexture?
    private var dummyUnorm: MTLTexture?
    private var dummyFloat: MTLTexture?

    /// Label raw values come from the SDK enum at install time (never hardcoded).
    private let labelBuilding: UInt32
    private let labelTree: UInt32
    private let labelStructure: UInt32

    /// Layout mirrored by `MatteUniforms` in SemanticMatte.metal — keep in sync.
    struct MatteUniforms {
        var viewToCapture: simd_float3x3
        var captureToSemantic: simd_float3x3
        var captureToPerson: simd_float3x3
        var personToCapture: simd_float3x3
        var captureToDepth: simd_float3x3
        var captureToMid: simd_float3x3
        var attackAlpha: Float
        var releaseAlpha: Float
        var debugTint: Float
        // ADR-018: decode metric eye depth from the RealityKit depth buffer using
        // the frame's actual projection matrix (convention-proof):
        //   d = projZW / (projZZ − depth · projWSign)
        var projZZ: Float
        var projZW: Float
        var projWSign: Float
        var distTree: Float
        var distBuilding: Float
        // ADR-030 person occlusion
        var personEnabled: Float
        var semanticEnabled: Float
        var depthBias: Float
        var edgeInner: Float
        var edgeOuter: Float
        // ADR-031 mid-field depth: 1/metric ≈ midA·rel + midB
        var midEnabled: Float
        var midA: Float
        var midB: Float
        var midMinContent: Float
        var midMaxDepth: Float
        var midRelBias: Float
        // Counsel MATH-1: the fit's input-domain support — the shader refuses to
        // decode model outputs outside the band LiDAR actually calibrated.
        var midRelMin: Float
        var midRelMax: Float
        // Counsel MATH-2: metric presence boundary derived from this frame's
        // projection (replaces the NDC epsilon that rejected far content).
        var contentFarPlane: Float
        // Wave D R2 (RENDER-2): 0 on the first encode after (re)allocating
        // the matte history — the .private textures are UNDEFINED and a NaN
        // seed is absorbing under the EMA's mix().
        var historyValid: Float
        var refineRadius: Int32
        var labelBuilding: UInt32
        var labelTree: UInt32
        var labelStructure: UInt32
    }

    init(
        feed: SemanticFeed,
        labelBuilding: UInt32,
        labelTree: UInt32,
        labelStructure: UInt32,
        personOcclusionEnabled: Bool,
        midDepthFeed: MidFieldDepthFeed?
    ) {
        self.feed = feed
        self.labelBuilding = labelBuilding
        self.labelTree = labelTree
        self.labelStructure = labelStructure
        self.personOcclusionEnabled = personOcclusionEnabled
        self.midDepthFeed = midDepthFeed
    }

    /// Remembers the view; callbacks attach on demand (ADR-035: a pass with no
    /// work still forces RealityKit through an offscreen render + full-screen
    /// copy every frame — real bandwidth, real heat).
    @MainActor func prepare(on arView: ARView) {
        guard !lifecycle.snapshot.uninstalled else { return }
        self.arView = arView
        stateLock.lock()
        self.session = arView.session
        stateLock.unlock()
    }

    var callbacksActive: Bool {
        lifecycle.snapshot.active
    }

    func setCaptureStream(revision: UInt64, framesAfter: TimeInterval) {
        stateLock.lock()
        streamRevision = revision
        streamFramesAfter = framesAfter
        frameAssociation.reset()
        matteHistoryValid = false
        releaseCaptureResources()
        stateLock.unlock()
    }

    @MainActor func updateViewport(size: CGSize, orientation: UIInterfaceOrientation) {
        stateLock.lock()
        viewport = .init(size: SIMD2(Float(size.width), Float(size.height)),
                         orientation: orientation.rawValue,
                         observedAt: ProcessInfo.processInfo.systemUptime)
        stateLock.unlock()
    }

    /// Callback attachment may dwell; source consumption must still stop at
    /// the policy edge. A retained pre-pause ARFrame cannot satisfy a new run.
    func setWorkAdmission(_ allowed: Bool, generation: UInt64, person: Bool, depth: Bool) {
        stateLock.lock()
        let changed = workAdmission.setAllowed(allowed, generation: generation)
        let sourcesChanged = personAdmitted != (allowed && person)
            || depthAdmitted != (allowed && depth)
        personAdmitted = allowed && person
        depthAdmitted = allowed && depth
        if changed {
            admittedSince = allowed ? ProcessInfo.processInfo.systemUptime : .infinity
            releaseCaptureResources()
            frameAssociation.reset()
        }
        if changed || sourcesChanged { matteHistoryValid = false }
        let metrics = ARBaselineMetrics.shared
        if !allowed || !feed.hasEnabledSample {
            metrics.setWorkload("Semantic matte consuming", enabled: false)
        }
        if !personAdmitted { metrics.setWorkload("Person matte consuming", enabled: false) }
        if !depthAdmitted { metrics.setWorkload("Depth matte consuming", enabled: false) }
        stateLock.unlock()
    }

    /// Attach/detach the render callbacks. Pipeline and matte history are kept
    /// across detaches; re-attach is cheap and the EMA re-converges in ~3 frames.
    /// (ADR-035: an attached pass with no work still forces RealityKit through
    /// an offscreen render + full-screen copy — detaching IS the heat fix, so
    /// install-once was not an option; the lock makes detach safe instead.)
    @MainActor func setCallbacksActive(_ requested: Bool) {
        let active = requested && ARBaselineExperiment.current.allows(.postprocess)
        // The view is owned by the manager and may be gone after detach. Never
        // mark an installation active if there is no slot to install it into.
        if active && arView == nil { return }
        stateLock.lock()
        let epoch = active ? lifecycle.attach() : nil
        let changed = active ? epoch != nil : lifecycle.detach()
        if changed, !active {
            // Round 2 (counsel RENDER-3): detaching releases this frame's
            // wrappers and flushes — the detached steady state must not pin
            // IOSurfaces in the capture pool.
            releaseCaptureResources()
            recordConsumption()
        }
        stateLock.unlock()
        guard changed, let arView else { return }
        if active {
            guard let epoch else { return }
            arView.renderCallbacks.prepareWithDevice = { device in
                self.prepare(device: device, epoch: epoch)
            }
            arView.renderCallbacks.postProcess = { context in
                self.encode(context: context, epoch: epoch)
            }
            // Round 5 (counsel F-D4-DETACH): the RSCH-4 instrument lives at
            // THIS choke point — the one place that covers all six
            // attach/detach sites (round 4 wired it at two of them, so
            // disarmSemanticMatte's four production paths — detach, suspend,
            // interruption, session failure — were invisible to the FT-28/31
            // toggle count). Emitted AFTER the slot assignment, so it can
            // never claim a toggle the `guard changed, let arView` refused.
            ARBaselineMetrics.shared.setWorkload("Semantic postprocess", enabled: true)
            ARBaselineMetrics.shared.event("Semantic pass attached")
            log.log("Semantic pass attached")
        } else {
            arView.renderCallbacks.prepareWithDevice = nil
            arView.renderCallbacks.postProcess = nil
            ARBaselineMetrics.shared.setWorkload("Semantic postprocess", enabled: false)
            ARBaselineMetrics.shared.event("Semantic pass detached")
            log.log("Semantic pass detached")
        }
    }

    @MainActor func uninstall() {
        setCallbacksActive(false)
        // Counsel ARP-11/SWE-4: an encode may be mid-flight on the render
        // thread — the teardown takes the same lock, so the pipeline/matte
        // clears can never land between a guard and its use.
        stateLock.lock()
        lifecycle.uninstall()
        releaseCaptureResources()
        pipeline = nil
        device = nil
        textureCache = nil
        dummyUint = nil
        dummyUnorm = nil
        dummyFloat = nil
        session = nil
        matteTextures = []
        matteHistoryValid = false
        stateLock.unlock()
        arView = nil
    }

    private func prepare(device: MTLDevice, epoch: UInt64) {
        // Round 2 (counsel RENDER-4): PUBLISH, don't build, under the lock —
        // the Metal library load + pipeline compile can take tens of ms, and
        // the main actor takes this same lock at 2.5 Hz. Build into locals
        // first; commit only if still needed (a losing second builder just
        // discards its locals).
        stateLock.lock()
        let current = lifecycle.accepts(epoch)
        let alreadyBuilt = pipeline != nil && self.device === device
            && textureCache != nil && dummyUint != nil
            && dummyUnorm != nil && dummyFloat != nil
        stateLock.unlock()
        if !current || alreadyBuilt { return }

        let metrics = ARBaselineMetrics.shared
        let trace = metrics.measure("Semantic pipeline prepare")
        defer { metrics.end(trace) }
        guard
            let library = try? device.makeDefaultLibrary(bundle: .main),
            let function = library.makeFunction(name: "semanticMatte"),
            let builtPipeline = try? device.makeComputePipelineState(function: function)
        else {
            metrics.event("Semantic pipeline prepare failed")
            return
        }
        var builtCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &builtCache)
        let builtUint = makeDummy(device: device, format: .r8Uint)
        let builtUnorm = makeDummy(device: device, format: .r8Unorm)
        let builtFloat = makeDummy(device: device, format: .r32Float)

        stateLock.lock()
        defer { stateLock.unlock() }
        guard lifecycle.accepts(epoch) else { return }
        if pipeline != nil, self.device === device,
           textureCache != nil, dummyUint != nil, dummyUnorm != nil,
           dummyFloat != nil { return } // lost the race
        if let oldDevice = self.device, oldDevice !== device {
            // A new Metal device cannot use history allocated on the old one.
            // Earlier command buffers retain those textures in their leases.
            releaseCaptureResources()
            matteTextures = []
            matteHistoryValid = false
        }
        self.device = device
        self.pipeline = builtPipeline
        self.textureCache = builtCache.map(RenderTextureCache.init)
        dummyUint = builtUint
        dummyUnorm = builtUnorm
        dummyFloat = builtFloat
        if builtCache != nil, builtUint != nil, builtUnorm != nil, builtFloat != nil {
            metrics.event("Semantic pipeline ready")
        } else {
            metrics.event("Semantic pipeline resources incomplete")
        }
    }

    private func makeDummy(device: MTLDevice, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }

    private func encode(context: ARView.PostProcessContext, epoch: UInt64) {
        let admittedCallback = lifecycle.beginCPU(epoch: epoch)
        defer { lifecycle.finishCPU() }
        let metrics = ARBaselineMetrics.shared
        // RealityKit callback cadence is an explicit presentation proxy. It is
        // absent while detached and does not establish drawable presentation.
        metrics.observe("Postprocess callback proxy")
        // CPU-side elapsed time includes lock waiting; GPU duration/presentation
        // remain measurements for Metal System Trace rather than this interval.
        let trace = metrics.measure("Postprocess CPU encode")
        defer { metrics.end(trace) }
        if metrics.isEnabled {
            // This is the entire RealityKit-provided command buffer, not an
            // isolated shader or proof of drawable presentation. Never wait on it.
            context.commandBuffer.addCompletedHandler { buffer in
                guard buffer.status == .completed, buffer.gpuStartTime > 0,
                      buffer.gpuEndTime >= buffer.gpuStartTime else { return }
                metrics.sample("Postprocess command buffer GPU", milliseconds:
                    (buffer.gpuEndTime - buffer.gpuStartTime) * 1000, originating: trace)
            }
        }
        // Counsel ARP-11/SWE-4: the WHOLE CPU-side encode holds the state lock —
        // a main-actor uninstall/detach serializes against it instead of
        // mutating pipeline/mattes under the render thread's feet.
        stateLock.lock()
        defer { stateLock.unlock() }
        // A queued callback can arrive after detach and even after a later
        // reattach. It must satisfy RealityKit's target-write contract, but
        // must never consume the new session's frame, feeds or Metal state.
        guard admittedCallback, lifecycle.accepts(epoch) else {
            blit(context: context)
            return
        }
        inFlightTextures.removeAll()
        inFlightBuffers.removeAll()
        // Once installed, every callback must write its target, even if no
        // capture/render correspondence can be admitted.
        guard workAdmission.allowed, let pipeline, let textureCache,
              let dummyUint, let dummyUnorm, let dummyFloat,
              let frame = session?.currentFrame, let viewport,
              (1...4).contains(viewport.orientation),
              viewport.size.x.isFinite, viewport.size.y.isFinite,
              viewport.size.x > 0, viewport.size.y > 0,
              let orientation = UIInterfaceOrientation(rawValue: viewport.orientation) else {
            bailOut(context: context)
            return
        }
        let capture = OcclusionCapture(frame: frame,
                                       generation: workAdmission.sessionGeneration,
                                       streamRevision: streamRevision)
        guard capture.matchesCameraBuffer(frame.capturedImage),
              context.sourceColorTexture.width == context.targetColorTexture.width,
              context.sourceColorTexture.height == context.targetColorTexture.height,
              context.sourceDepthTexture.width == context.targetColorTexture.width,
              context.sourceDepthTexture.height == context.targetColorTexture.height else {
            frameAssociation.reset()
            metrics.observe("Occlusion capture or target format rejected")
            bailOut(context: context)
            return
        }
        let framesAfter = max(admittedSince, streamFramesAfter)
        let viewportSize = CGSize(width: CGFloat(viewport.size.x), height: CGFloat(viewport.size.y))
        let display = frame.displayTransform(for: orientation, viewportSize: viewportSize).inverted()
        let viewToCapture = simd_float3x3(columns: (
            SIMD3(Float(display.a), Float(display.b), 0),
            SIMD3(Float(display.c), Float(display.d), 0),
            SIMD3(Float(display.tx), Float(display.ty), 1)
        ))
        let association = frameAssociation.evaluate(
            capture: capture,
            context: .init(observedAt: ProcessInfo.processInfo.systemUptime,
                           sceneElapsedTime: context.time, viewport: viewport,
                           targetSize: SIMD2(Float(context.targetColorTexture.width),
                                             Float(context.targetColorTexture.height)),
                           renderProjection: context.projection,
                           captureProjection: frame.camera.projectionMatrix(
                            for: orientation, viewportSize: viewportSize, zNear: 0.01, zFar: 10_000),
                           viewToCapture: viewToCapture),
            generation: workAdmission.sessionGeneration, streamRevision: streamRevision,
            framesAfter: framesAfter)
        recordAssociation(association, capture: capture)
        guard association == .approximate,
              lifecycle.snapshot.gpuCommands == 0,
              let yTexture = makeTexture(frame.capturedImage, format: .r8Unorm, plane: 0, cache: textureCache),
              let cbcrTexture = makeTexture(frame.capturedImage, format: .rg8Unorm, plane: 1, cache: textureCache)
        else {
            if lifecycle.snapshot.gpuCommands > 0 { metrics.observe("Occlusion GPU busy fallback") }
            bailOut(context: context)
            return
        }
        metrics.sample("Occlusion capture age", milliseconds:
                        (ProcessInfo.processInfo.systemUptime - capture.timestamp) * 1000)

        // Google supports semantics quality in portrait. Its timing is SDK-
        // opaque; never describe a submitted-frame association as exact capture.
        let semantic = orientation == .portrait
            ? feed.snapshot(for: capture, framesAfter: framesAfter) : nil
        let labelsTexture = semantic.flatMap {
            makeTexture($0.labels, format: .r8Uint, cache: textureCache)
        }
        let confidenceTexture = semantic.flatMap {
            makeTexture($0.confidence, format: .r8Unorm, cache: textureCache)
        }
        let semanticEnabled = labelsTexture != nil && confidenceTexture != nil
        if let semantic {
            metrics.sample("Semantic associated capture age", milliseconds:
                            (capture.timestamp - semantic.capture.timestamp) * 1000)
        }

        // Stencil and optical-axis scene depth describe this ARKit capture;
        // foreground coverage is not LiDAR's discrete confidence measurement.
        var stencilTexture: MTLTexture?
        var sceneDepthTexture: MTLTexture?
        var personMapping = matrix_identity_float3x3
        var depthMapping = matrix_identity_float3x3
        if personAdmitted, personOcclusionEnabled,
           let stencil = frame.segmentationBuffer,
           let depthMap = frame.sceneDepth?.depthMap {
            let person = OcclusionRaster.captureAligned(
                stencil, capture: capture, encoding: .confidenceUNorm8,
                confidence: .foregroundCoverage, provenance: .arkitFrame,
                ownership: .frameworkPoolRetained)
            let depth = OcclusionRaster.captureAligned(
                depthMap, capture: capture, encoding: .opticalAxisMetersFloat32,
                provenance: .arkitFrame, ownership: .frameworkPoolRetained)
            if person.matches(stencil), depth.matches(depthMap),
               person.hasCompatibleCaptureAspect, depth.hasCompatibleCaptureAspect {
                personMapping = person.captureToSample
                depthMapping = depth.captureToSample
                stencilTexture = makeTexture(stencil, format: .r8Unorm, cache: textureCache)
                sceneDepthTexture = makeTexture(depthMap, format: .r32Float, cache: textureCache)
            } else {
                metrics.observe("Person depth format rejected")
            }
        }
        let personEnabled = stencilTexture != nil && sceneDepthTexture != nil

        var midTexture: MTLTexture?
        var midMapping = matrix_identity_float3x3
        var midA: Float = 0, midB: Float = 0
        var midRelMin: Float = 0, midRelMax: Float = 0
        var midMaxDepth = AppConfig.midDepthMaxDistance
        if depthAdmitted, let midSample = midDepthFeed?.snapshot(
            for: capture, framesAfter: framesAfter, maxAge: AppConfig.midDepthMaxSampleAge
        ) {
            metrics.sample("Depth sample age", milliseconds:
                            (capture.timestamp - midSample.frameTimestamp) * 1000)
            midTexture = makeTexture(midSample.relativeDepth, format: .r16Float, cache: textureCache)
            midMapping = midSample.raster.captureToSample
            midA = midSample.a
            midB = midSample.b
            midRelMin = midSample.relMin
            midRelMax = midSample.relMax
            midMaxDepth = min(midMaxDepth, midSample.maxTrustedDepth)
        }
        let midEnabled = midTexture != nil
        let sourceBits: UInt8 = (semanticEnabled ? 1 : 0) | (personEnabled ? 2 : 0) | (midEnabled ? 4 : 0)
        if sourceBits != lastSourceBits { matteHistoryValid = false }
        lastSourceBits = sourceBits

        guard semanticEnabled || personEnabled || midEnabled,
              let encoder = context.commandBuffer.makeComputeCommandEncoder()
        else {
            bailOut(context: context)
            return
        }

        let target = context.targetColorTexture
        ensureMatteTextures(width: target.width, height: target.height)
        guard matteTextures.count == 2 else {
            encoder.endEncoding()
            bailOut(context: context)
            return
        }
        let previousMatte = matteTextures[matteIndex]
        let nextMatte = matteTextures[1 - matteIndex]
        matteIndex = 1 - matteIndex

        // Depth decode constants from RealityKit's own projection for this frame:
        // clip.z = zz·z_eye + zw, clip.w = wSign·z_eye ⇒ d = zw / (zz − depth·wSign)
        // (holds for forward/reverse and finite/infinite Z alike).
        let projection = context.projection
        // Counsel MATH-2: derive the frame's metric far boundary from the same
        // projection. Cleared depth pixels decode to exactly the far plane
        // (finite conventions) or to non-finite (infinite-far reverse-Z), so a
        // `< contentFarPlane` test excludes "no content" without any NDC epsilon
        // — and without silently rejecting real content at 500 m+.
        let contentFarPlane = Self.deriveContentFarPlane(projection: projection)
        logDepthBoundsIfChanged(farPlane: contentFarPlane)
        var uniforms = MatteUniforms(
            viewToCapture: viewToCapture,
            captureToSemantic: semantic?.labelRaster.captureToSample ?? matrix_identity_float3x3,
            captureToPerson: personMapping,
            personToCapture: simd_inverse(personMapping),
            captureToDepth: depthMapping,
            captureToMid: midMapping,
            attackAlpha: AppConfig.matteAttackAlpha,
            releaseAlpha: AppConfig.matteReleaseAlpha,
            debugTint: AppConfig.semanticMatteDebugTint ? 1 : 0,
            projZZ: projection.columns.2.z,
            projZW: projection.columns.3.z,
            projWSign: projection.columns.2.w,
            distTree: AppConfig.semanticMatteTreeDistance,
            distBuilding: AppConfig.semanticMatteBuildingDistance,
            personEnabled: personEnabled ? 1 : 0,
            semanticEnabled: semanticEnabled ? 1 : 0,
            depthBias: AppConfig.occlusionDepthBiasMeters,
            edgeInner: AppConfig.personMatteEdgeInner,
            edgeOuter: AppConfig.personMatteEdgeOuter,
            midEnabled: midEnabled ? 1 : 0,
            midA: midA,
            midB: midB,
            midMinContent: AppConfig.midDepthMinContentDistance,
            midMaxDepth: midMaxDepth,
            midRelBias: AppConfig.midDepthRelativeBias,
            midRelMin: midRelMin,
            midRelMax: midRelMax,
            contentFarPlane: contentFarPlane,
            historyValid: matteHistoryValid ? 1 : 0,
            refineRadius: AppConfig.personMatteRefineRadius,
            labelBuilding: labelBuilding,
            labelTree: labelTree,
            labelStructure: labelStructure
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(context.sourceColorTexture, index: 0)
        encoder.setTexture(context.sourceDepthTexture, index: 1)
        encoder.setTexture(target, index: 2)
        encoder.setTexture(yTexture, index: 3)
        encoder.setTexture(cbcrTexture, index: 4)
        encoder.setTexture(labelsTexture ?? dummyUint, index: 5)
        encoder.setTexture(confidenceTexture ?? dummyUnorm, index: 6)
        encoder.setTexture(previousMatte, index: 7)
        encoder.setTexture(nextMatte, index: 8)
        encoder.setTexture(stencilTexture ?? dummyUnorm, index: 9)
        encoder.setTexture(sceneDepthTexture ?? dummyFloat, index: 10)
        encoder.setTexture(midTexture ?? dummyFloat, index: 11)
        encoder.setBytes(&uniforms, length: MemoryLayout<MatteUniforms>.stride, index: 0)

        let threadgroup = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(
            width: (target.width + 7) / 8,
            height: (target.height + 7) / 8,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()
        recordConsumption(semantic: semanticEnabled, person: personEnabled, depth: midEnabled)
        if semanticEnabled { metrics.observe("Semantic sample used") }
        if personEnabled { metrics.observe("Person sample used") }
        if midEnabled { metrics.observe("Depth sample used") }
        // RealityKit owns the command buffer and does not expose its
        // retainedReferences policy. Keep every bound input/history texture,
        // the pipeline and all CV wrappers until Metal reports completion.
        let retained = RenderGPUResourceLease(
            wrappers: inFlightTextures,
            textures: [context.sourceColorTexture, context.sourceDepthTexture, target,
                       yTexture, cbcrTexture, labelsTexture ?? dummyUint,
                       confidenceTexture ?? dummyUnorm, previousMatte, nextMatte,
                       stencilTexture ?? dummyUnorm, sceneDepthTexture ?? dummyFloat,
                       midTexture ?? dummyFloat],
            pipeline: pipeline, cache: textureCache, pixelBuffers: inFlightBuffers
        )
        inFlightTextures.removeAll()
        inFlightBuffers.removeAll()
        let tracked = lifecycle.submitGPU(epoch: epoch)
        assert(tracked, "stateLock must exclude detach while submitting GPU work")
        context.commandBuffer.addCompletedHandler { [lifecycle, weak self] command in
            if command.status != .completed {
                // Keep GPU admission closed until undefined history has been
                // retired. No completion-side cache/lifecycle lock is held here.
                self?.invalidateFailedHistory()
            }
            if retained.complete(), tracked { lifecycle.finishGPU() }
        }
        // Counsel ARP-12: flush ONCE PER FRAME after encoding — a non-zero
        // CVMetalTexture use count keeps the IOSurface out of ARKit's small
        // capture pool, and sustained pressure there drops camera frames in a
        // sawtooth that reads as thermal throttling but isn't.
        textureCache.flush()
        // Round 2 (counsel RENDER-2): the history is defined from here on —
        // this dispatch wrote nextMatte, and the next frame may read it.
        matteHistoryValid = true
    }

    /// Fixed-size counters and transition-only details avoid a per-frame log.
    private func recordAssociation(_ decision: RenderFrameAssociation.Decision, capture: OcclusionCapture) {
        let value: String
        switch decision {
        case .approximate: value = "approximate"
        case .rejected(let reason): value = reason.rawValue
        }
        let metrics = ARBaselineMetrics.shared
        metrics.observe("Occlusion association " + value)
        if value != lastAssociationDiagnostic {
            lastAssociationDiagnostic = value
            metrics.event("Occlusion association", details:
                            "decision=\(value) generation=\(capture.sessionGeneration) stream=\(capture.streamRevision) capture=\(capture.timestamp)")
        }
    }

    private func invalidateFailedHistory() {
        stateLock.lock()
        matteHistoryValid = false
        stateLock.unlock()
        ARBaselineMetrics.shared.observe("Occlusion GPU failed history rejected")
    }

    /// Round 2 (counsel RENDER-7): the ONE exit helper — no bail path can be
    /// added without releasing the frame's wrappers and flushing the cache.
    /// Caller holds `stateLock`.
    private func bailOut(context: ARView.PostProcessContext) {
        ARBaselineMetrics.shared.observe("Postprocess blit fallback")
        recordConsumption()
        matteHistoryValid = false
        inFlightTextures.removeAll()
        inFlightBuffers.removeAll()
        if let textureCache {
            textureCache.flush()
        }
        blit(context: context)
    }

    /// Textures accepted by the most recent compute encode, not presentation
    /// or proof of GPU completion. Caller holds `stateLock`.
    private func recordConsumption(semantic: Bool = false, person: Bool = false, depth: Bool = false) {
        let metrics = ARBaselineMetrics.shared
        metrics.setWorkload("Semantic matte consuming", enabled: semantic)
        metrics.setWorkload("Person matte consuming", enabled: person)
        metrics.setWorkload("Depth matte consuming", enabled: depth)
    }

    /// Round 2 (counsel RENDER-3): detach releases capture resources — the
    /// detached state is the pass's designed steady state (ADR-035), and
    /// wrappers held across it pin IOSurfaces in ARKit's small capture pool
    /// indefinitely. Caller holds `stateLock`.
    private func releaseCaptureResources() {
        inFlightTextures.removeAll()
        inFlightBuffers.removeAll()
        matteHistoryValid = false
        if let textureCache {
            textureCache.flushAfterGPU()
        }
    }

    /// Counsel MATH-2: the metric distances the depth buffer's two boundary
    /// values (0 and 1) decode to. The larger finite one IS the far plane; a
    /// hair inside it excludes cleared pixels on both clear conventions. An
    /// infinite-far projection has no far boundary — cleared pixels decode
    /// non-finite and are excluded by `isfinite`, so the visibility radius
    /// (nothing is ever placed beyond it) serves as the presence bound.
    static func deriveContentFarPlane(projection: simd_float4x4) -> Float {
        let zz = projection.columns.2.z
        let zw = projection.columns.3.z
        let wSign = projection.columns.2.w
        func decode(_ depth: Float) -> Float {
            let denom = zz - depth * wSign
            return abs(denom) > 1e-9 ? zw / denom : .infinity
        }
        let bounds = [decode(0), decode(1)].filter { $0.isFinite && $0 > 0 }
        if let far = bounds.max(), far > 1 {
            return far * 0.999
        }
        return Float(AppConfig.arVisibilityRadius) * 1.05
    }

    /// FT-15/FT-16 instrument (counsel MATH-2: "neither boundary is asserted,
    /// logged, or covered by a test"): one log line whenever the effective far
    /// boundary changes materially — the field evidence for whether far drops
    /// are even inside the frustum.
    private var loggedFarPlane: Float = 0
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "matte")
    private func logDepthBoundsIfChanged(farPlane: Float) {
        guard abs(farPlane - loggedFarPlane) > loggedFarPlane * 0.05 else { return }
        loggedFarPlane = farPlane
        log.log("Content far boundary: \(farPlane, format: .fixed(precision: 0)) m")
    }

    private func blit(context: ARView.PostProcessContext) {
        guard let blitEncoder = context.commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
        blitEncoder.endEncoding()
    }

    /// Wave D R2 (RENDER-2): false until the first dispatch after a history
    /// (re)allocation has WRITTEN both textures — the shader gates its EMA
    /// seed on this so undefined `.private` contents are never read.
    private var matteHistoryValid = false
    private var lastSourceBits: UInt8 = 0

    private func ensureMatteTextures(width: Int, height: Int) {
        if matteTextures.count == 2, let first = matteTextures.first,
           first.width == width, first.height == height {
            return
        }
        guard let device else {
            matteTextures = []
            matteHistoryValid = false
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        matteTextures = [
            device.makeTexture(descriptor: descriptor),
            device.makeTexture(descriptor: descriptor),
        ].compactMap { $0 }
        matteIndex = 0
        matteHistoryValid = false
    }

    private func makeTexture(
        _ pixelBuffer: CVPixelBuffer,
        format: MTLPixelFormat,
        plane: Int = 0,
        cache: RenderTextureCache
    ) -> MTLTexture? {
        guard let cvTexture = cache.makeTexture(pixelBuffer, format: format, plane: plane)
        else { return nil }
        inFlightTextures.append(cvTexture)
        inFlightBuffers.append(pixelBuffer)
        return CVMetalTextureGetTexture(cvTexture)
    }
}
