import ARKit
import CoreML
import CoreVideo
import Foundation
import ImageIO
import Vision
import os
import os.lock

/// Thread-safe hand-off of the latest aligned mid-field depth to the render pass.
final class MidFieldDepthFeed: @unchecked Sendable {
    /// Model output + the per-frame affine fit that makes it metric:
    /// `1/metric ≈ a·rel + b`, least-squares aligned against LiDAR (ADR-031).
    /// Counsel MATH-1: the fit is only evidence over the band the LiDAR reference
    /// actually covered — the sample carries that support so the shader can
    /// refuse to extrapolate (unknown is unknown, never "a surface").
    struct Sample {
        let relativeDepth: CVPixelBuffer
        let a: Float
        let b: Float
        /// Input-domain support: model outputs outside [relMin, relMax] were
        /// never observed against LiDAR and must not decode to a depth.
        let relMin: Float
        let relMax: Float
        /// Output ceiling: depths beyond this exceed the reference band (plus
        /// margin) and are extrapolation, not measurement.
        let maxTrustedDepth: Float
        /// Vision `.up`/`.scaleFill` output with its source capture, calibration,
        /// normalized image mapping, units and app-owned buffer semantics.
        let raster: OcclusionRaster

        var capture: OcclusionCapture { raster.capture }
        var frameTimestamp: TimeInterval { capture.timestamp }
        var sessionGeneration: UInt64 { capture.sessionGeneration }
        var streamRevision: UInt64 { capture.streamRevision }

        var isValid: Bool {
            guard a.isFinite, b.isFinite, a != 0,
                  relMin.isFinite, relMax.isFinite, relMin < relMax,
                  maxTrustedDepth.isFinite,
                  maxTrustedDepth >= Float.leastNormalMagnitude,
                  raster.encoding == .relativeInverseDepthFloat16,
                  raster.confidence == .none,
                  raster.provenance == .visionScaleFill,
                  raster.bufferOwnership == .appOwnedCopy,
                  raster.matches(relativeDepth) else { return false }
            // The source handler is explicitly `.up` and Vision uses
            // `.scaleFill`; both axes retain their full normalized image UVs.
            let mapping = raster.captureToSample
            for column in 0..<3 {
                for row in 0..<3 {
                    let expected: Float = column == row ? 1 : 0
                    if abs(mapping[column][row] - expected) > 0.0001 { return false }
                }
            }
            return OcclusionInverseDepthFit(
                a: a, b: b, relativeRange: relMin...relMax,
                metricRange: Float.leastNormalMagnitude...maxTrustedDepth
            ).isValid
        }
    }

    private let lock = NSLock()
    private var sample: Sample?
    private var publishedAt = Date.distantPast
    private var workAdmission = PerceptionWorkAdmission()
    private var requiredStreamRevision: UInt64 = 0

    @discardableResult
    func setWorkAdmission(_ allowed: Bool, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = workAdmission.setAllowed(allowed, generation: generation)
        if changed {
            sample = nil
            publishedAt = .distantPast
        }
        return changed
    }

    /// ARSession.run may restart the capture stream without changing the
    /// perception generation. Pending work from the old stream cannot publish.
    @discardableResult
    func setStreamRevision(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard requiredStreamRevision != revision else { return false }
        requiredStreamRevision = revision
        sample = nil
        publishedAt = .distantPast
        return true
    }

    func admissionToken() -> PerceptionWorkAdmission.Token? {
        lock.lock()
        defer { lock.unlock() }
        return workAdmission.token
    }

    func accepts(_ token: PerceptionWorkAdmission.Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return workAdmission.accepts(token)
    }

    func accepts(_ token: PerceptionWorkAdmission.Token,
                 capture: OcclusionCapture) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return workAdmission.accepts(token) && capture.isValid &&
            capture.trackingNormal &&
            capture.sessionGeneration == token.sessionGeneration &&
            capture.streamRevision == requiredStreamRevision
    }

    @discardableResult
    func publish(_ new: Sample, token: PerceptionWorkAdmission.Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard workAdmission.accepts(token), new.isValid,
              new.capture.trackingNormal,
              new.sessionGeneration == token.sessionGeneration,
              new.streamRevision == requiredStreamRevision,
              sample.map({ new.frameTimestamp > $0.frameTimestamp }) ?? true else {
            return false
        }
        sample = new
        publishedAt = Date()
        return true
    }

    func invalidate() {
        lock.lock()
        sample = nil
        publishedAt = .distantPast
        lock.unlock()
    }

    /// Wave B review C15: a single refused fit must not blank a still-fresh
    /// sample (a reference band hovering at the support threshold would flicker
    /// the matte at the inference rate). The sample ages out naturally; clear
    /// it only once stale so `hasSample` (the DPT chip) can't advertise an
    /// expired fit.
    func invalidateIfStale(maxAge: TimeInterval, token: PerceptionWorkAdmission.Token) {
        lock.lock()
        defer { lock.unlock() }
        guard workAdmission.accepts(token) else { return }
        if sample != nil, Date().timeIntervalSince(publishedAt) > maxAge {
            sample = nil
        }
    }

    func snapshot(for capture: OcclusionCapture, framesAfter: TimeInterval,
                  maxAge: TimeInterval) -> Sample? {
        lock.lock()
        defer { lock.unlock() }
        guard workAdmission.allowed, let sample else { return nil }
        guard workAdmission.sessionGeneration == capture.sessionGeneration else {
            ARBaselineMetrics.shared.observe("Depth rejected generation")
            return nil
        }
        guard requiredStreamRevision == capture.streamRevision else {
            ARBaselineMetrics.shared.observe("Depth rejected stream")
            return nil
        }
        if let reason = RenderFrameAssociation.sampleRejection(
            sample.capture, relativeTo: capture, framesAfter: framesAfter,
            maxAge: maxAge
        ) {
            ARBaselineMetrics.shared.observe("Depth rejected " + reason.rawValue)
            return nil
        }
        return sample
    }

    var hasSample: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sample != nil
    }
}

/// LiDAR-aligned Depth Anything output. Each run fits relative output in
/// inverse-depth space against same-capture LiDAR samples from 0.4–4 m. The
/// usable metric domain is only that measured reference band plus its existing
/// 1.25 support margin (below 5 m with current settings), not the configured
/// 60 m ceiling. No usable fit means no occlusion from this source. Broader
/// robust fit/coverage work remains #12–#14 and must not extrapolate evidence.
final class MidFieldDepthEstimator: Sendable {
    let feed = MidFieldDepthFeed()

    private let queue = DispatchQueue(label: "midfield-depth", qos: .userInitiated)
    private struct State {
        var loading = false
        var modelReady = false
        var busy = false
        var lastRunAt = Date.distantPast
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Vision objects and pools never leave `queue`; this narrow owner is the
    /// only unchecked transfer of those SDK references into its async jobs.
    private let worker = WorkerResources()
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "middepth")

    func setWorkAdmission(_ allowed: Bool, generation: UInt64) {
        if feed.setWorkAdmission(allowed, generation: generation) {
            state.withLock { $0.lastRunAt = .distantPast }
        }
    }

    func setStreamRevision(_ revision: UInt64) {
        if feed.setStreamRevision(revision) {
            state.withLock { $0.lastRunAt = .distantPast }
        }
    }

    /// Decode the model off the main thread at app start; ~50 MB of weights.
    func loadIfNeeded() {
        let token = feed.admissionToken()
        let shouldLoad = state.withLock { state in
            let needed = token != nil && !state.modelReady && !state.loading
            if needed { state.loading = true }
            return needed
        }
        guard shouldLoad, let token else { return }

        queue.async { [weak self] in
            guard let self else { return }
            guard self.feed.accepts(token) else {
                self.state.withLock { $0.loading = false }
                return
            }
            let metrics = ARBaselineMetrics.shared
            let trace = metrics.measure("Depth model prepare")
            defer { metrics.end(trace) }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            guard
                let url = Bundle.main.url(
                    forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc"
                ),
                let mlModel = try? MLModel(contentsOf: url, configuration: configuration),
                let vnModel = try? VNCoreMLModel(for: mlModel)
            else {
                metrics.event("Depth model prepare failed")
                self.log.error("Mid-field depth model failed to load; feature disabled")
                self.state.withLock { $0.loading = false }
                return
            }
            self.worker.model = vnModel
            self.state.withLock { state in
                state.modelReady = true
                state.loading = false
            }
            metrics.event("Depth model ready")
            metrics.setWorkload("Depth model ready", enabled: true)
            self.log.log("Mid-field depth model loaded (Depth Anything V2 small f16)")
        }
    }

    /// Feed a frame; runs at most every `1/hz` seconds and never overlaps itself.
    /// Requires LiDAR scene depth in the frame for the metric alignment.
    func update(frame: ARFrame, capture: OcclusionCapture, hz: Double) {
        guard let token = feed.admissionToken(),
              feed.accepts(token, capture: capture),
              capture.timestamp == frame.timestamp,
              capture.matchesCameraBuffer(frame.capturedImage),
              let lidarSource = frame.sceneDepth?.depthMap else { return }
        let lidarRaster = OcclusionRaster.captureAligned(
            lidarSource, capture: capture, encoding: .opticalAxisMetersFloat32,
            provenance: .arkitFrame, ownership: .frameworkPoolRetained
        )
        guard lidarRaster.matches(lidarSource),
              Self.compatibleAspect(lidarRaster.resolution,
                                    with: capture.imageResolution) else { return }
        let admitted = state.withLock { state in
            guard state.modelReady, hz.isFinite, hz > 0, !state.busy,
                  Date().timeIntervalSince(state.lastRunAt) > 1.0 / hz else { return false }
            state.busy = true
            state.lastRunAt = Date()
            return true
        }
        guard admitted else { return }

        let timestamp = capture.timestamp
        // Wave D (counsel ARP-12) round 2 (counsel RENDER-5): the copy runs
        // OFF the main actor, into POOLED app-owned buffers. ARKit's
        // pool-managed buffers are held only for the memcpy itself (a few ms,
        // bounded to one in flight by `busy`) — the box empties BEFORE the
        // 17–50 ms inference, so neither the frame nor its buffers ever span
        // the long work. The ARFrame is never retained.
        let sources = SourceBox(image: frame.capturedImage, lidar: lidarSource)

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.state.withLock { $0.busy = false }
            }
            guard self.feed.accepts(token, capture: capture) else {
                sources.empty()
                return
            }
            let image = sources.image.flatMap { self.worker.pooledCopy($0) }
            let lidar = sources.lidar.flatMap { self.worker.pooledCopy($0) }
            sources.empty() // ARKit's buffers release HERE, pre-inference
            guard let image, let lidar,
                  capture.matchesCameraBuffer(image), lidarRaster.matches(lidar) else {
                ARBaselineMetrics.shared.event("Depth input copy failed")
                return
            }
            guard self.feed.accepts(token, capture: capture) else { return }
            let request: VNCoreMLRequest
            if let existing = self.worker.request {
                request = existing
            } else {
                guard let model = self.worker.model else { return }
                request = VNCoreMLRequest(model: model)
                self.worker.request = request
            }
            request.imageCropAndScaleOption = .scaleFill
            let metrics = ARBaselineMetrics.shared
            metrics.sample("Depth input age", milliseconds: (ProcessInfo.processInfo.systemUptime - timestamp) * 1000)
            let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up)
            let inferenceSucceeded: Bool = {
                let trace = metrics.measure("Depth inference")
                defer { metrics.end(trace) }
                metrics.observe("Depth inference")
                do {
                    try handler.perform([request])
                    return true
                } catch {
                    metrics.event("Depth inference failed")
                    return false
                }
            }()
            guard inferenceSucceeded else { return }
            guard self.feed.accepts(token, capture: capture) else {
                metrics.event("Depth stale completion rejected")
                return
            }
            guard let observation = request.results?.first as? VNPixelBufferObservation else {
                metrics.event("Depth inference missing output")
                return
            }
            let visionOutput = observation.pixelBuffer
            let outputRaster = OcclusionRaster.captureAligned(
                visionOutput, capture: capture, encoding: .relativeInverseDepthFloat16,
                provenance: .visionScaleFill, ownership: .appOwnedCopy
            )
            guard outputRaster.matches(visionOutput),
                  let relative = self.worker.pooledCopy(visionOutput),
                  outputRaster.matches(relative) else {
                metrics.event("Depth output copy or format rejected")
                return
            }

            if let fit = Self.fitInverseDepth(relative: relative, lidar: lidar) {
                let published = self.feed.publish(.init(
                    relativeDepth: relative,
                    a: fit.a,
                    b: fit.b,
                    relMin: fit.relMin,
                    relMax: fit.relMax,
                    maxTrustedDepth: fit.maxTrustedDepth,
                    raster: outputRaster
                ), token: token)
                guard published else {
                    metrics.event("Depth stale completion rejected")
                    return
                }
                metrics.sample("Depth publication age", milliseconds: (ProcessInfo.processInfo.systemUptime - timestamp) * 1000)
                metrics.observe("Depth sample published")
            } else {
                metrics.event("Depth alignment rejected")
                self.feed.invalidateIfStale(maxAge: AppConfig.midDepthMaxSampleAge, token: token)
            }
        }
    }

    private static func compatibleAspect(_ raster: OcclusionRasterSize,
                                         with image: OcclusionRasterSize) -> Bool {
        guard raster.isValid, image.isValid else { return false }
        let horizontalScale = Double(raster.width) / Double(image.width)
        let verticalScale = Double(raster.height) / Double(image.height)
        return abs(horizontalScale - verticalScale) <=
            0.02 * max(horizontalScale, verticalScale)
    }

    // MARK: - Buffer ownership (Wave D, counsel ARP-12 + round 2 RENDER-5)

    /// A hand-off box that can be EMPTIED: closure captures are immutable, so
    /// without it the captured ARKit buffers would stay retained for the whole
    /// closure — including the long inference the copy exists to decouple.
    private final class SourceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedImage: CVPixelBuffer?
        private var storedLidar: CVPixelBuffer?
        init(image: CVPixelBuffer, lidar: CVPixelBuffer) {
            storedImage = image
            storedLidar = lidar
        }
        var image: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return storedImage }
        var lidar: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return storedLidar }
        func empty() {
            lock.lock()
            storedImage = nil
            storedLidar = nil
            lock.unlock()
        }
    }

    /// This owner is created before any job is enqueued and is touched only on
    /// `queue`; model load and inference therefore never overlap. The feed's
    /// generation token rejects jobs that finish after a reset.
    private final class WorkerResources: @unchecked Sendable {
        var model: VNCoreMLModel?
        var request: VNCoreMLRequest?
        var bufferPools: [String: CVPixelBufferPool] = [:]

    /// Round 2 (counsel RENDER-5): copies land in POOLED buffers — no per-call
    /// IOSurface allocation at 5 Hz. Falls back to a plain create if the pool fails.
    func pooledCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard MidFieldDepthEstimator.copyLayout(for: source) != nil else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let key = "\(width)x\(height)-\(format)"
        if bufferPools[key] == nil {
            // Format changes must not accumulate retired camera/model pools.
            // Live buffers retain their own storage after a pool is released.
            if bufferPools.count >= 6 { bufferPools.removeAll() }
            var newPool: CVPixelBufferPool?
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            bufferPools[key] = newPool
        }
        if let pool = bufferPools[key] {
            var out: CVPixelBuffer?
            let limits = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
            if CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &out) == kCVReturnSuccess,
               let copy = out, MidFieldDepthEstimator.copyContents(of: source, into: copy) {
                return copy
            }
            // Saturation is a skipped sample, not an unbounded allocation path.
            return nil
        }
        return MidFieldDepthEstimator.copyPixelBuffer(source)
    }
    }

    /// Deep-copies a pixel buffer into an APP-OWNED allocation (all planes).
    /// The returned buffer has no ties to ARKit's capture pool — the original
    /// can be released immediately, which is the researcher-verified fix
    /// direction (retaining frames is the documented CAUSE of pool
    /// exhaustion, not the cure).
    static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard copyLayout(for: source) != nil else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        var copyOut: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            nil, width, height, format, attributes as CFDictionary, &copyOut
        ) == kCVReturnSuccess, let copy = copyOut else { return nil }
        return copyContents(of: source, into: copy) ? copy : nil
    }

    private struct CopyPlane {
        let rows: Int
        let activeBytes: Int
        let stride: Int
    }

    /// Only formats whose active bytes and plane geometry are known may enter
    /// the copy path. CoreVideo may choose different row padding for each copy.
    private static func copyLayout(for buffer: CVPixelBuffer) -> [CopyPlane]? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferIsPlanar(buffer),
                  CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
            let chromaWidth = width / 2 + width % 2
            let chromaHeight = height / 2 + height % 2
            guard chromaWidth <= Int.max / 2,
                  CVPixelBufferGetWidthOfPlane(buffer, 0) == width,
                  CVPixelBufferGetHeightOfPlane(buffer, 0) == height,
                  CVPixelBufferGetWidthOfPlane(buffer, 1) == chromaWidth,
                  CVPixelBufferGetHeightOfPlane(buffer, 1) == chromaHeight else {
                return nil
            }
            let rowBytes = [width, chromaWidth * 2]
            let rows = [height, chromaHeight]
            var planes: [CopyPlane] = []
            for plane in 0..<2 {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                guard stride >= rowBytes[plane],
                      stride <= Int.max / rows[plane] else { return nil }
                planes.append(CopyPlane(rows: rows[plane],
                                        activeBytes: rowBytes[plane], stride: stride))
            }
            return planes
        case kCVPixelFormatType_OneComponent8,
             kCVPixelFormatType_OneComponent16Half,
             kCVPixelFormatType_DepthFloat32,
             kCVPixelFormatType_OneComponent32Float,
             kCVPixelFormatType_32BGRA:
            guard !CVPixelBufferIsPlanar(buffer),
                  CVPixelBufferGetPlaneCount(buffer) == 0 else { return nil }
            let bytesPerPixel: Int
            switch format {
            case kCVPixelFormatType_OneComponent8: bytesPerPixel = 1
            case kCVPixelFormatType_OneComponent16Half: bytesPerPixel = 2
            default: bytesPerPixel = 4
            }
            guard width <= Int.max / bytesPerPixel else { return nil }
            let rowBytes = width * bytesPerPixel
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            guard stride >= rowBytes, stride <= Int.max / height else { return nil }
            return [CopyPlane(rows: height, activeBytes: rowBytes, stride: stride)]
        default:
            return nil
        }
    }

    /// The plane-aware memcpy shared by the pooled and unpooled paths. Reject
    /// mismatched buffers before locking and copy only active bytes in each row.
    static func copyContents(of source: CVPixelBuffer, into copy: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(source) == CVPixelBufferGetPixelFormatType(copy),
              CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(copy),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(copy),
              let sourceLayout = copyLayout(for: source),
              let destinationLayout = copyLayout(for: copy),
              sourceLayout.count == destinationLayout.count else { return false }
        for plane in sourceLayout.indices {
            guard sourceLayout[plane].rows == destinationLayout[plane].rows,
                  sourceLayout[plane].activeBytes == destinationLayout[plane].activeBytes else {
                return false
            }
        }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            return false
        }
        guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            return false
        }
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        for plane in sourceLayout.indices {
            let src: UnsafeMutableRawPointer?
            let dst: UnsafeMutableRawPointer?
            if sourceLayout.count == 1 {
                src = CVPixelBufferGetBaseAddress(source)
                dst = CVPixelBufferGetBaseAddress(copy)
            } else {
                src = CVPixelBufferGetBaseAddressOfPlane(source, plane)
                dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane)
            }
            guard let src, let dst else { return false }
            let sourcePlane = sourceLayout[plane]
            let copyPlane = destinationLayout[plane]
            for row in 0..<sourcePlane.rows {
                memcpy(dst.advanced(by: row * copyPlane.stride),
                       src.advanced(by: row * sourcePlane.stride),
                       sourcePlane.activeBytes)
            }
        }
        return true
    }

    // MARK: - Metric alignment

    /// A fit plus the data support it is valid over (counsel MATH-1).
    struct InverseDepthFit {
        let a: Float
        let b: Float
        let relMin: Float
        let relMax: Float
        let maxTrustedDepth: Float
    }

    /// Least-squares fit of `1/lidarDepth ≈ a·rel + b` over a sparse grid where
    /// LiDAR is trustworthy (0.4–4 m). Rejected unless the fit is well-conditioned
    /// and actually explains the data (R² ≥ 0.6) — a bad alignment must fail
    /// toward "no occlusion", not toward hallucinated occluders.
    ///
    /// Counsel MATH-1: an affine alignment of relative depth is only valid across
    /// the interval the reference samples spanned. The fit therefore reports its
    /// own support (the observed `rel` band and the farthest observed depth plus
    /// margin), and returns nil outright when the supported band cannot reach any
    /// content the mid-field matte is allowed to act on — publishing such a fit
    /// would light the DPT chip while structurally unable to matte anything.
    static func fitInverseDepth(
        relative: CVPixelBuffer, lidar: CVPixelBuffer
    ) -> InverseDepthFit? {
        guard
            CVPixelBufferGetPixelFormatType(relative) == kCVPixelFormatType_OneComponent16Half,
            CVPixelBufferGetPixelFormatType(lidar) == kCVPixelFormatType_DepthFloat32
        else { return nil }

        CVPixelBufferLockBaseAddress(relative, .readOnly)
        CVPixelBufferLockBaseAddress(lidar, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(relative, .readOnly)
            CVPixelBufferUnlockBaseAddress(lidar, .readOnly)
        }
        guard
            let relBase = CVPixelBufferGetBaseAddress(relative),
            let lidarBase = CVPixelBufferGetBaseAddress(lidar)
        else { return nil }

        let relWidth = CVPixelBufferGetWidth(relative)
        let relHeight = CVPixelBufferGetHeight(relative)
        let relStride = CVPixelBufferGetBytesPerRow(relative) / MemoryLayout<UInt16>.size
        let relPixels = relBase.assumingMemoryBound(to: UInt16.self)

        let lidarWidth = CVPixelBufferGetWidth(lidar)
        let lidarHeight = CVPixelBufferGetHeight(lidar)
        let lidarStride = CVPixelBufferGetBytesPerRow(lidar) / MemoryLayout<Float>.size
        let lidarPixels = lidarBase.assumingMemoryBound(to: Float.self)

        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0, sumYY = 0.0
        var count = 0
        var relMin = Double.infinity, relMax = -Double.infinity
        var depthMax = 0.0
        let cols = 28, rows = 20
        for row in 0..<rows {
            for col in 0..<cols {
                let u = (Double(col) + 0.5) / Double(cols) * 0.9 + 0.05
                let v = (Double(row) + 0.5) / Double(rows) * 0.9 + 0.05
                let depth = lidarPixels[
                    Int(v * Double(lidarHeight)) * lidarStride + Int(u * Double(lidarWidth))
                ]
                guard depth > 0.4, depth < AppConfig.midDepthLiDARBandMax,
                      depth.isFinite else { continue }
                let bits = relPixels[
                    Int(v * Double(relHeight)) * relStride + Int(u * Double(relWidth))
                ]
                let rel = Double(Float(Float16(bitPattern: bits)))
                guard rel.isFinite else { continue }
                let y = 1.0 / Double(depth)
                sumX += rel; sumY += y
                sumXX += rel * rel; sumXY += rel * y; sumYY += y * y
                relMin = min(relMin, rel)
                relMax = max(relMax, rel)
                depthMax = max(depthMax, Double(depth))
                count += 1
            }
        }
        guard count >= 40 else { return nil }
        let n = Double(count)
        let varX = sumXX - sumX * sumX / n
        let covXY = sumXY - sumX * sumY / n
        let varY = sumYY - sumY * sumY / n
        guard varX > 1e-9, varY > 1e-12 else { return nil }
        let a = covXY / varX
        let b = (sumY - a * sumX) / n
        let r2 = (covXY * covXY) / (varX * varY)
        guard r2 >= 0.6, abs(a) > 1e-9 else { return nil }

        // MATH-1 support bound: trust only a small margin past the farthest
        // reference depth. A fit whose reference tops out too near to reach the
        // matte's own minimum content distance can never matte anything — refuse
        // it so the DPT chip stays honest and the shader never extrapolates.
        let maxTrustedDepth = min(
            depthMax * Double(AppConfig.midDepthSupportMargin),
            Double(AppConfig.midDepthMaxDistance)
        )
        guard maxTrustedDepth > Double(AppConfig.midDepthMinContentDistance) else {
            return nil
        }
        // Slight symmetric slack on the input band: sampling is sparse, so the
        // true support extends marginally past the observed extremes.
        let relSlack = (relMax - relMin) * 0.05
        return InverseDepthFit(
            a: Float(a),
            b: Float(b),
            relMin: Float(relMin - relSlack),
            relMax: Float(relMax + relSlack),
            maxTrustedDepth: Float(maxTrustedDepth)
        )
    }
}
