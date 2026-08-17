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
    private let lock = NSLock()
    private var labels: CVPixelBuffer?
    private var confidence: CVPixelBuffer?
    private var enabled = false

    func update(labels: CVPixelBuffer?, confidence: CVPixelBuffer?) {
        lock.lock()
        self.labels = labels
        self.confidence = confidence
        lock.unlock()
    }

    /// Far-mode gate, set by the session manager (ADR-011: the matte only applies
    /// when every rendered drop is beyond the far threshold).
    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    func snapshot() -> (labels: CVPixelBuffer, confidence: CVPixelBuffer)? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, let labels, let confidence else { return nil }
        return (labels, confidence)
    }
}

/// Wave 4.5 SilhouetteRefiner (ADR-011): a RealityKit post-process that restores the
/// camera image wherever *far* virtual content overlaps pixels labeled
/// building/tree/structure by ARCore Scene Semantics — the per-pixel backstop for
/// "never draw content over a surface it's geometrically behind" where no
/// Streetscape/LiDAR geometry exists. Confidence-feathered, temporally EMA-smoothed.
final class SemanticOcclusionPass {
    private let feed: SemanticFeed
    private let personOcclusionEnabled: Bool
    /// ADR-031: LiDAR-aligned Depth Anything output for the 4–60 m band; nil when
    /// the feature is off or the device lacks LiDAR (no alignment source).
    private let midDepthFeed: MidFieldDepthFeed?
    private weak var arView: ARView?
    private weak var session: ARSession?

    private var device: MTLDevice?
    private var pipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    /// AUDIT P0: CVMetalTextures must outlive the GPU work that samples them —
    /// releasing the wrapper early is the classic cause of intermittent texture
    /// corruption. Collected per frame, released on command-buffer completion.
    private var inFlightTextures: [Any] = []
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
    private struct MatteUniforms {
        var viewToCapture: simd_float3x3
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
    func prepare(on arView: ARView) {
        self.arView = arView
        self.session = arView.session
    }

    private(set) var callbacksActive = false

    /// Attach/detach the render callbacks. Pipeline and matte history are kept
    /// across detaches; re-attach is cheap and the EMA re-converges in ~3 frames.
    func setCallbacksActive(_ active: Bool) {
        guard active != callbacksActive, let arView else { return }
        callbacksActive = active
        if active {
            arView.renderCallbacks.prepareWithDevice = { [weak self] device in
                self?.prepare(device: device)
            }
            arView.renderCallbacks.postProcess = { [weak self] context in
                self?.encode(context: context)
            }
        } else {
            arView.renderCallbacks.prepareWithDevice = nil
            arView.renderCallbacks.postProcess = nil
        }
    }

    func uninstall() {
        setCallbacksActive(false)
        pipeline = nil
        matteTextures = []
    }

    private func prepare(device: MTLDevice) {
        // Idempotent: callbacks re-attach on demand and must not rebuild Metal state.
        if pipeline != nil, self.device === device { return }
        self.device = device
        guard
            let library = try? device.makeDefaultLibrary(bundle: .main),
            let function = library.makeFunction(name: "semanticMatte"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else { return }
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        dummyUint = makeDummy(device: device, format: .r8Uint)
        dummyUnorm = makeDummy(device: device, format: .r8Unorm)
        dummyFloat = makeDummy(device: device, format: .r32Float)
    }

    private func makeDummy(device: MTLDevice, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }

    private func encode(context: ARView.PostProcessContext) {
        // Fresh frame: anything left from a bailed-out frame is safe to drop.
        inFlightTextures.removeAll()
        // The contract with RealityKit: once postProcess is set, EVERY frame must
        // write target. Fall back to a plain blit when nothing to composite.
        guard
            let pipeline,
            let textureCache,
            let dummyUint, let dummyUnorm, let dummyFloat,
            let frame = session?.currentFrame,
            let yTexture = makeTexture(frame.capturedImage, format: .r8Unorm, plane: 0, cache: textureCache),
            let cbcrTexture = makeTexture(frame.capturedImage, format: .rg8Unorm, plane: 1, cache: textureCache)
        else {
            blit(context: context)
            return
        }

        // Semantic (building/tree) matte — only when VPS armed it (far mode).
        let semantic = feed.snapshot()
        let labelsTexture = semantic.flatMap {
            makeTexture($0.labels, format: .r8Uint, cache: textureCache)
        }
        let confidenceTexture = semantic.flatMap {
            makeTexture($0.confidence, format: .r8Unorm, cache: textureCache)
        }
        let semanticEnabled = labelsTexture != nil && confidenceTexture != nil

        // Person occlusion — stencil (high-res) + LiDAR scene depth (metric).
        var stencilTexture: MTLTexture?
        var sceneDepthTexture: MTLTexture?
        if personOcclusionEnabled,
           let stencil = frame.segmentationBuffer,
           let depthMap = frame.sceneDepth?.depthMap {
            stencilTexture = makeTexture(stencil, format: .r8Unorm, cache: textureCache)
            sceneDepthTexture = makeTexture(depthMap, format: .r32Float, cache: textureCache)
        }
        let personEnabled = stencilTexture != nil && sceneDepthTexture != nil

        // Mid-field depth (ADR-031) — discard stale samples (camera moved on).
        var midTexture: MTLTexture?
        var midA: Float = 0, midB: Float = 0
        var midRelMin: Float = 0, midRelMax: Float = 0
        var midMaxDepth = AppConfig.midDepthMaxDistance
        if let midSample = midDepthFeed?.snapshot(
            forFrameAt: frame.timestamp, maxAge: AppConfig.midDepthMaxSampleAge
        ) {
            midTexture = makeTexture(
                midSample.relativeDepth, format: .r16Float, cache: textureCache
            )
            midA = midSample.a
            midB = midSample.b
            midRelMin = midSample.relMin
            midRelMax = midSample.relMax
            // MATH-1: the trusted ceiling is per-fit (reference band + margin),
            // never the static config maximum.
            midMaxDepth = min(midMaxDepth, midSample.maxTrustedDepth)
        }
        let midEnabled = midTexture != nil

        guard semanticEnabled || personEnabled || midEnabled,
              let encoder = context.commandBuffer.makeComputeCommandEncoder()
        else {
            blit(context: context)
            return
        }

        let target = context.targetColorTexture
        ensureMatteTextures(width: target.width, height: target.height)
        guard matteTextures.count == 2 else {
            encoder.endEncoding()
            blit(context: context)
            return
        }
        let previousMatte = matteTextures[matteIndex]
        let nextMatte = matteTextures[1 - matteIndex]
        matteIndex = 1 - matteIndex

        // Map view UVs into capture-image UVs (inverse of ARKit's display transform).
        let viewport = CGSize(width: target.width, height: target.height)
        let display = frame.displayTransform(for: .portrait, viewportSize: viewport).inverted()
        let viewToCapture = simd_float3x3(columns: (
            SIMD3(Float(display.a), Float(display.b), 0),
            SIMD3(Float(display.c), Float(display.d), 0),
            SIMD3(Float(display.tx), Float(display.ty), 1)
        ))

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
        // Keep the CV wrappers alive until the GPU is done sampling them.
        let retained = inFlightTextures
        inFlightTextures = []
        context.commandBuffer.addCompletedHandler { _ in
            _ = retained
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

    private func ensureMatteTextures(width: Int, height: Int) {
        if let first = matteTextures.first, first.width == width, first.height == height {
            return
        }
        guard let device else {
            matteTextures = []
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
    }

    private func makeTexture(
        _ pixelBuffer: CVPixelBuffer,
        format: MTLPixelFormat,
        plane: Int = 0,
        cache: CVMetalTextureCache
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        inFlightTextures.append(cvTexture)
        return CVMetalTextureGetTexture(cvTexture)
    }
}
