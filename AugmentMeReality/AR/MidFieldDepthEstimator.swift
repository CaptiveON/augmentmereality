import ARKit
import CoreML
import CoreVideo
import Foundation
import Vision
import os

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
        /// ARFrame.timestamp the inference ran on — stale samples are unusable
        /// (the camera has rotated away from the pixels they describe).
        let frameTimestamp: TimeInterval
        /// Lifecycle identity only; issue #11 owns the full synchronized pose,
        /// calibration and render-frame association contract.
        let sessionGeneration: UInt64
    }

    private let lock = NSLock()
    private var sample: Sample?
    private var publishedAt = Date.distantPast
    private var workAdmission = PerceptionWorkAdmission()

    @discardableResult
    func setWorkAdmission(_ allowed: Bool, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = workAdmission.setAllowed(allowed, generation: generation)
        if changed { sample = nil }
        return changed
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

    @discardableResult
    func publish(_ new: Sample, token: PerceptionWorkAdmission.Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard workAdmission.accepts(token), new.sessionGeneration == token.sessionGeneration else {
            return false
        }
        sample = new
        publishedAt = Date()
        return true
    }

    func invalidate() {
        lock.lock()
        sample = nil
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

    func snapshot(
        forFrameAt timestamp: TimeInterval, maxAge: TimeInterval, generation: UInt64
    ) -> Sample? {
        lock.lock()
        defer { lock.unlock() }
        guard workAdmission.allowed, workAdmission.sessionGeneration == generation,
              let sample, sample.sessionGeneration == generation,
              timestamp >= sample.frameTimestamp,
              timestamp - sample.frameTimestamp <= maxAge else { return nil }
        return sample
    }

    var hasSample: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sample != nil
    }
}

/// ADR-031 mid-field depth: Depth Anything V2 Small (CoreML, Neural Engine,
/// ~17 ms/frame on iPhone 15 Pro Max) fills the depth hole between LiDAR (~5 m)
/// and the far semantic matte — dense per-pixel depth for trees, cars, poles,
/// fences at 4–60 m, so occlusion there is real depth ordering, not class
/// heuristics. The model outputs RELATIVE depth; each run is aligned to metric
/// against the LiDAR depth map (the 0.4–4 m band where both are valid) with a
/// least-squares fit in inverse-depth space. No usable fit ⇒ no occlusion from
/// this source (fails toward draw-over, never toward eating content).
final class MidFieldDepthEstimator {
    let feed = MidFieldDepthFeed()

    private let queue = DispatchQueue(label: "midfield-depth", qos: .userInitiated)
    private let stateLock = NSLock()
    private var model: VNCoreMLModel?
    /// Reused across runs (only touched on the serial worker queue).
    private var request: VNCoreMLRequest?
    private var loading = false
    private var busy = false
    private var lastRunAt = Date.distantPast
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "middepth")

    func setWorkAdmission(_ allowed: Bool, generation: UInt64) {
        stateLock.lock()
        if feed.setWorkAdmission(allowed, generation: generation) {
            lastRunAt = .distantPast
        }
        stateLock.unlock()
    }

    /// Decode the model off the main thread at app start; ~50 MB of weights.
    func loadIfNeeded() {
        stateLock.lock()
        let token = feed.admissionToken()
        let shouldLoad = token != nil && model == nil && !loading
        if shouldLoad { loading = true }
        stateLock.unlock()
        guard shouldLoad, let token else { return }

        queue.async { [weak self] in
            guard let self else { return }
            guard self.feed.accepts(token) else {
                self.stateLock.lock()
                self.loading = false
                self.stateLock.unlock()
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
                self.stateLock.lock()
                self.loading = false
                self.stateLock.unlock()
                return
            }
            self.stateLock.lock()
            self.model = vnModel
            self.loading = false
            self.stateLock.unlock()
            metrics.event("Depth model ready")
            metrics.setWorkload("Depth model ready", enabled: true)
            self.log.log("Mid-field depth model loaded (Depth Anything V2 small f16)")
        }
    }

    /// Feed a frame; runs at most every `1/hz` seconds and never overlaps itself.
    /// Requires LiDAR scene depth in the frame for the metric alignment.
    func update(frame: ARFrame, hz: Double) {
        stateLock.lock()
        guard let token = feed.admissionToken(), let model, hz > 0,
              !busy, Date().timeIntervalSince(lastRunAt) > 1.0 / hz else {
            stateLock.unlock()
            return
        }
        busy = true
        lastRunAt = Date()
        stateLock.unlock()

        guard let lidarSource = frame.sceneDepth?.depthMap else {
            stateLock.lock(); busy = false; stateLock.unlock()
            return
        }
        let timestamp = frame.timestamp
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
                self.stateLock.lock()
                self.busy = false
                self.stateLock.unlock()
            }
            guard self.feed.accepts(token) else {
                sources.empty()
                return
            }
            let image = sources.image.flatMap { self.pooledCopy($0) }
            let lidar = sources.lidar.flatMap { self.pooledCopy($0) }
            sources.empty() // ARKit's buffers release HERE, pre-inference
            guard let image, let lidar else {
                ARBaselineMetrics.shared.event("Depth input copy failed")
                return
            }
            guard self.feed.accepts(token) else { return }
            let request: VNCoreMLRequest
            if let existing = self.request {
                request = existing
            } else {
                request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .scaleFill
                self.request = request
            }
            let metrics = ARBaselineMetrics.shared
            metrics.sample("Depth input age", milliseconds: (ProcessInfo.processInfo.systemUptime - timestamp) * 1000)
            let handler = VNImageRequestHandler(cvPixelBuffer: image)
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
            guard self.feed.accepts(token) else {
                metrics.event("Depth stale completion rejected")
                return
            }
            guard let observation = request.results?.first as? VNPixelBufferObservation else {
                metrics.event("Depth inference missing output")
                return
            }
            let relative = observation.pixelBuffer

            if let fit = Self.fitInverseDepth(relative: relative, lidar: lidar) {
                let published = self.feed.publish(.init(
                    relativeDepth: relative,
                    a: fit.a,
                    b: fit.b,
                    relMin: fit.relMin,
                    relMax: fit.relMax,
                    maxTrustedDepth: fit.maxTrustedDepth,
                    frameTimestamp: timestamp,
                    sessionGeneration: token.sessionGeneration
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

    /// Round 2 (counsel RENDER-5): copies land in POOLED buffers — no per-call
    /// IOSurface allocation at 5 Hz. Queue-confined (the serial `queue` is the
    /// only accessor). Falls back to a plain create if the pool fails.
    private var bufferPools: [String: CVPixelBufferPool] = [:]
    private func pooledCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let key = "\(width)x\(height)-\(format)"
        if bufferPools[key] == nil {
            var newPool: CVPixelBufferPool?
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            bufferPools[key] = newPool
        }
        if let pool = bufferPools[key] {
            var out: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
               let copy = out, Self.copyContents(of: source, into: copy) {
                return copy
            }
        }
        return Self.copyPixelBuffer(source)
    }

    /// Deep-copies a pixel buffer into an APP-OWNED allocation (all planes).
    /// The returned buffer has no ties to ARKit's capture pool — the original
    /// can be released immediately, which is the researcher-verified fix
    /// direction (retaining frames is the documented CAUSE of pool
    /// exhaustion, not the cure).
    static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        var copyOut: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        guard CVPixelBufferCreate(
            nil, width, height, format, attributes as CFDictionary, &copyOut
        ) == kCVReturnSuccess, let copy = copyOut else { return nil }
        return copyContents(of: source, into: copy) ? copy : nil
    }

    /// The plane-aware memcpy shared by the pooled and unpooled paths.
    static func copyContents(of source: CVPixelBuffer, into copy: CVPixelBuffer) -> Bool {
        let height = CVPixelBufferGetHeight(source)
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return false }
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                let rows = CVPixelBufferGetHeightOfPlane(source, plane)
                if srcStride == dstStride {
                    memcpy(dst, src, srcStride * rows)
                } else {
                    let rowBytes = min(srcStride, dstStride)
                    for row in 0..<rows {
                        memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
                    }
                }
            }
        } else {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(copy) else { return false }
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(copy)
            if srcStride == dstStride {
                memcpy(dst, src, srcStride * height)
            } else {
                let rowBytes = min(srcStride, dstStride)
                for row in 0..<height {
                    memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
                }
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
