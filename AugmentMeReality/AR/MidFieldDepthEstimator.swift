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
    }

    private let lock = NSLock()
    private var sample: Sample?
    private var publishedAt = Date.distantPast

    func publish(_ new: Sample) {
        lock.lock()
        sample = new
        publishedAt = Date()
        lock.unlock()
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
    func invalidateIfStale(maxAge: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if sample != nil, Date().timeIntervalSince(publishedAt) > maxAge {
            sample = nil
        }
    }

    func snapshot(forFrameAt timestamp: TimeInterval, maxAge: TimeInterval) -> Sample? {
        lock.lock()
        defer { lock.unlock() }
        guard let sample, timestamp - sample.frameTimestamp <= maxAge else { return nil }
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

    /// Decode the model off the main thread at app start; ~50 MB of weights.
    func loadIfNeeded() {
        stateLock.lock()
        let shouldLoad = model == nil && !loading
        if shouldLoad { loading = true }
        stateLock.unlock()
        guard shouldLoad else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            guard
                let url = Bundle.main.url(
                    forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc"
                ),
                let mlModel = try? MLModel(contentsOf: url, configuration: configuration),
                let vnModel = try? VNCoreMLModel(for: mlModel)
            else {
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
            self.log.log("Mid-field depth model loaded (Depth Anything V2 small f16)")
        }
    }

    /// Feed a frame; runs at most every `1/hz` seconds and never overlaps itself.
    /// Requires LiDAR scene depth in the frame for the metric alignment.
    func update(frame: ARFrame, hz: Double) {
        stateLock.lock()
        guard let model, !busy, Date().timeIntervalSince(lastRunAt) > 1.0 / hz else {
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
        // Wave D (counsel ARP-12, researcher-corrected direction): COPY OUT and
        // promptly release — never hold ARKit's pool-managed buffers (and never
        // retain the ARFrame) for the 17–50 ms of a full inference + fit. The
        // capture pool is small; sustained pressure drops camera frames in a
        // sawtooth that reads as thermal throttling. The copies are app-owned;
        // ARKit gets its buffers back the moment this scope ends.
        guard let image = Self.copyPixelBuffer(frame.capturedImage),
              let lidar = Self.copyPixelBuffer(lidarSource) else {
            stateLock.lock(); busy = false; stateLock.unlock()
            return
        }
        let timestamp = frame.timestamp

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.busy = false
                self.stateLock.unlock()
            }
            let request: VNCoreMLRequest
            if let existing = self.request {
                request = existing
            } else {
                request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .scaleFill
                self.request = request
            }
            let handler = VNImageRequestHandler(cvPixelBuffer: image)
            guard
                (try? handler.perform([request])) != nil,
                let observation = request.results?.first as? VNPixelBufferObservation
            else { return }
            let relative = observation.pixelBuffer

            if let fit = Self.fitInverseDepth(relative: relative, lidar: lidar) {
                self.feed.publish(.init(
                    relativeDepth: relative,
                    a: fit.a,
                    b: fit.b,
                    relMin: fit.relMin,
                    relMax: fit.relMax,
                    maxTrustedDepth: fit.maxTrustedDepth,
                    frameTimestamp: timestamp
                ))
            } else {
                self.feed.invalidateIfStale(maxAge: AppConfig.midDepthMaxSampleAge)
            }
        }
    }

    // MARK: - Buffer ownership (Wave D, counsel ARP-12)

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

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return nil }
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
                  let dst = CVPixelBufferGetBaseAddress(copy) else { return nil }
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
        return copy
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
