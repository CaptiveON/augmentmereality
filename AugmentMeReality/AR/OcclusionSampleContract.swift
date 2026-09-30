import CoreVideo
import Foundation
import simd

/// Pixel dimensions of a captured image or a derived raster. UVs in this file
/// use a top-left origin and the full image occupies [0, 1] on each axis.
struct OcclusionRasterSize: Sendable, Equatable {
    let width: Int
    let height: Int

    var isValid: Bool { width > 0 && height > 0 }
}

/// `timestamp` is ARFrame.timestamp (seconds on the session's uptime clock).
/// A session run may restart the capture stream without changing the perception
/// admission generation, so both counters are required to identify a capture.
struct OcclusionCaptureIdentity: Sendable, Equatable {
    let sessionGeneration: UInt64
    let streamRevision: UInt64
    let timestamp: TimeInterval

    var isValid: Bool { timestamp.isFinite && timestamp >= 0 }
}

/// AR camera geometry at capture time. Intrinsics are in pixels of
/// `imageResolution`, before display orientation or viewport crop. The pose is
/// the camera-to-world rigid transform in the generation's AR world frame.
struct OcclusionCapture: Sendable {
    let identity: OcclusionCaptureIdentity
    let cameraToWorld: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: OcclusionRasterSize
    let trackingNormal: Bool

    var sessionGeneration: UInt64 { identity.sessionGeneration }
    var streamRevision: UInt64 { identity.streamRevision }
    var timestamp: TimeInterval { identity.timestamp }

    var isValid: Bool {
        guard identity.isValid, imageResolution.isValid,
              Self.finite(cameraToWorld), Self.finite(intrinsics) else { return false }

        // Reject non-rigid or projective poses before comparing/reprojecting
        // them. ARKit's camera transform is a right-handed rigid transform.
        let x = SIMD3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y,
                      cameraToWorld.columns.0.z)
        let y = SIMD3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y,
                      cameraToWorld.columns.1.z)
        let z = SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y,
                      cameraToWorld.columns.2.z)
        let tolerance: Float = 0.02
        guard abs(cameraToWorld.columns.0.w) <= tolerance,
              abs(cameraToWorld.columns.1.w) <= tolerance,
              abs(cameraToWorld.columns.2.w) <= tolerance,
              abs(cameraToWorld.columns.3.w - 1) <= tolerance,
              abs(simd_length(x) - 1) <= tolerance,
              abs(simd_length(y) - 1) <= tolerance,
              abs(simd_length(z) - 1) <= tolerance,
              abs(simd_dot(x, y)) <= tolerance,
              abs(simd_dot(x, z)) <= tolerance,
              abs(simd_dot(y, z)) <= tolerance,
              simd_dot(simd_cross(x, y), z) > 0.95 else { return false }

        // K maps camera rays to pixels. Preserve the full matrix so a caller
        // does not silently treat a cropped image's calibration as the source.
        let k = intrinsics
        let determinant = k.columns.0.x * k.columns.1.y
            - k.columns.1.x * k.columns.0.y
        return k.columns.0.x > 0 && k.columns.1.y > 0 &&
            determinant.isFinite && determinant > 0 &&
            abs(k.columns.0.z) <= 0.001 &&
            abs(k.columns.1.z) <= 0.001 &&
            abs(k.columns.2.z - 1) <= 0.001
    }

    /// A pixel tolerance includes focal length, skew and principal point.
    /// Resolution must match; a scaled K is not interchangeable with its source.
    func hasCompatibleCalibration(
        with other: Self, tolerancePixels: Float
    ) -> Bool {
        guard isValid, other.isValid, imageResolution == other.imageResolution,
              tolerancePixels.isFinite, tolerancePixels >= 0 else { return false }
        for column in 0..<3 {
            for row in 0..<3 {
                if abs(intrinsics[column][row] - other.intrinsics[column][row]) > tolerancePixels {
                    return false
                }
            }
        }
        return true
    }

    /// Compare poses only in the same session and stream. Tracking quality is
    /// carried separately so admission policy can make its own explicit gate.
    func hasCompatiblePose(
        with other: Self,
        translationToleranceMeters: Float,
        rotationToleranceRadians: Float
    ) -> Bool {
        guard isValid, other.isValid,
              sessionGeneration == other.sessionGeneration,
              streamRevision == other.streamRevision,
              translationToleranceMeters.isFinite, translationToleranceMeters >= 0,
              rotationToleranceRadians.isFinite, rotationToleranceRadians >= 0 else {
            return false
        }
        let origin = SIMD3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y,
                           cameraToWorld.columns.3.z)
        let otherOrigin = SIMD3(other.cameraToWorld.columns.3.x,
                                other.cameraToWorld.columns.3.y,
                                other.cameraToWorld.columns.3.z)
        let translation = simd_length(origin - otherOrigin)
        guard translation.isFinite, translation <= translationToleranceMeters else { return false }

        // trace(R_self^T R_other) gives the relative rotation angle. The axes
        // have already passed the rigid-pose check above.
        let trace = simd_dot(Self.axis(cameraToWorld.columns.0),
                             Self.axis(other.cameraToWorld.columns.0))
            + simd_dot(Self.axis(cameraToWorld.columns.1),
                       Self.axis(other.cameraToWorld.columns.1))
            + simd_dot(Self.axis(cameraToWorld.columns.2),
                       Self.axis(other.cameraToWorld.columns.2))
        let cosine = min(1, max(-1, (trace - 1) * 0.5))
        let angle = acos(cosine)
        return angle.isFinite && angle <= rotationToleranceRadians
    }

    /// Validates the camera image without locking or mutating its CVPixelBuffer.
    func matchesCameraBuffer(_ buffer: CVPixelBuffer) -> Bool {
        guard isValid,
              CVPixelBufferGetPixelFormatType(buffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetWidth(buffer) == imageResolution.width,
              CVPixelBufferGetHeight(buffer) == imageResolution.height,
              CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) == 2 else {
            return false
        }
        let chromaWidth = imageResolution.width / 2 + imageResolution.width % 2
        let chromaHeight = imageResolution.height / 2 + imageResolution.height % 2
        return CVPixelBufferGetWidthOfPlane(buffer, 0) == imageResolution.width &&
            CVPixelBufferGetHeightOfPlane(buffer, 0) == imageResolution.height &&
            CVPixelBufferGetWidthOfPlane(buffer, 1) == chromaWidth &&
            CVPixelBufferGetHeightOfPlane(buffer, 1) == chromaHeight &&
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) >= imageResolution.width &&
            chromaWidth <= Int.max / 2 &&
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) >= chromaWidth * 2
    }

    private static func finite(_ matrix: simd_float4x4) -> Bool {
        for column in 0..<4 {
            for row in 0..<4 where !matrix[column][row].isFinite { return false }
        }
        return true
    }

    private static func axis(_ column: SIMD4<Float>) -> SIMD3<Float> {
        SIMD3(column.x, column.y, column.z)
    }

    private static func finite(_ matrix: simd_float3x3) -> Bool {
        for column in 0..<3 {
            for row in 0..<3 where !matrix[column][row].isFinite { return false }
        }
        return true
    }
}

/// Valid part of a sample texture in normalized, top-left-origin sample UVs.
struct OcclusionUVRect: Sendable {
    let minimum: SIMD2<Float>
    let maximum: SIMD2<Float>

    static let full = Self(minimum: .zero, maximum: SIMD2(1, 1))

    var isValid: Bool {
        minimum.x.isFinite && minimum.y.isFinite &&
            maximum.x.isFinite && maximum.y.isFinite &&
            minimum.x >= 0 && minimum.y >= 0 &&
            maximum.x <= 1 && maximum.y <= 1 &&
            minimum.x < maximum.x && minimum.y < maximum.y
    }

    func contains(_ uv: SIMD2<Float>) -> Bool {
        isValid && uv.x.isFinite && uv.y.isFinite &&
            uv.x >= minimum.x && uv.x <= maximum.x &&
            uv.y >= minimum.y && uv.y <= maximum.y
    }
}

/// Stored pixel semantics. Relative output remains relative until a separately
/// validated per-capture fit converts it to optical-axis metres.
enum OcclusionDepthEncoding: Sendable, Equatable {
    case categoricalUInt8
    case confidenceUNorm8
    case depthConfidenceLevelUInt8
    case opticalAxisMetersFloat32
    case relativeInverseDepthFloat16
}

/// What a UNorm8 confidence raster measures. Class confidence, foreground
/// coverage and ARKit's discrete depth confidence levels are different
/// quantities to the consumer.
enum OcclusionConfidenceMeaning: Sendable, Equatable {
    case none
    case classProbability
    case foregroundCoverage
    case depthConfidenceLevels
}

/// Evidence for which capture a raster describes. GAR's returned semantic
/// buffers are associated with a submitted ARFrame, but the SDK does not expose
/// an exact internal semantic capture timestamp; policy must account for that.
enum OcclusionSampleProvenance: Sendable, Equatable {
    case arkitFrame
    case visionScaleFill
    case garSubmittedFrameOpaque
}

/// The producer retains framework-pooled buffers or owns a copied buffer.
/// In either case the consumer must keep CVPixelBuffer/CVMetalTexture wrappers
/// alive until GPU completion, and drop retained buffers on reset/disable.
enum OcclusionBufferOwnership: Sendable, Equatable {
    case frameworkPoolRetained
    case appOwnedCopy
}

/// Immutable metadata for one raster. `captureToSample` maps homogeneous
/// normalized capture UVs to normalized sample UVs; it includes orientation,
/// crop and scale. `.visionScaleFill` on an `.up` capture uses identity mapping
/// even when its output pixel dimensions differ from the captured image.
struct OcclusionRaster: Sendable {
    let capture: OcclusionCapture
    let resolution: OcclusionRasterSize
    let captureToSample: simd_float3x3
    let encoding: OcclusionDepthEncoding
    let confidence: OcclusionConfidenceMeaning
    let support: OcclusionUVRect
    let provenance: OcclusionSampleProvenance
    let bufferOwnership: OcclusionBufferOwnership

    var isValid: Bool {
        guard capture.isValid, resolution.isValid, support.isValid else { return false }
        for column in 0..<3 {
            for row in 0..<3 where !captureToSample[column][row].isFinite { return false }
        }
        let transform = captureToSample
        let linearDeterminant = transform.columns.0.x * transform.columns.1.y
            - transform.columns.1.x * transform.columns.0.y
        guard linearDeterminant.isFinite, abs(linearDeterminant) > 1e-8,
              abs(transform.columns.0.z) <= 0.0001,
              abs(transform.columns.1.z) <= 0.0001,
              abs(transform.columns.2.z - 1) <= 0.0001 else { return false }
        switch encoding {
        case .confidenceUNorm8:
            return confidence == .classProbability || confidence == .foregroundCoverage
        case .depthConfidenceLevelUInt8:
            return confidence == .depthConfidenceLevels
        case .categoricalUInt8, .opticalAxisMetersFloat32,
             .relativeInverseDepthFloat16:
            return confidence == .none
        }
    }

    func sampleUV(forCaptureUV uv: SIMD2<Float>) -> SIMD2<Float>? {
        guard isValid, Self.unitContains(uv) else { return nil }
        let mapped = captureToSample * SIMD3(uv.x, uv.y, 1)
        guard mapped.z.isFinite, mapped.z != 0 else { return nil }
        let result = SIMD2(mapped.x / mapped.z, mapped.y / mapped.z)
        return support.contains(result) ? result : nil
    }

    func captureUV(forSampleUV uv: SIMD2<Float>) -> SIMD2<Float>? {
        guard isValid, support.contains(uv) else { return nil }
        let mapped = simd_inverse(captureToSample) * SIMD3(uv.x, uv.y, 1)
        guard mapped.z.isFinite, mapped.z != 0 else { return nil }
        let result = SIMD2(mapped.x / mapped.z, mapped.y / mapped.z)
        return Self.unitContains(result) ? result : nil
    }

    /// Checks the expected packed format, non-planar layout, dimensions and
    /// minimum stride. Buffer contents are deliberately not read or mutated.
    func matches(_ buffer: CVPixelBuffer) -> Bool {
        guard isValid,
              CVPixelBufferGetPixelFormatType(buffer) == expectedPixelFormat,
              CVPixelBufferGetWidth(buffer) == resolution.width,
              CVPixelBufferGetHeight(buffer) == resolution.height,
              !CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) == 0 else {
            return false
        }
        let bytesPerPixel: Int
        switch encoding {
        case .categoricalUInt8, .confidenceUNorm8,
             .depthConfidenceLevelUInt8: bytesPerPixel = 1
        case .opticalAxisMetersFloat32: bytesPerPixel = 4
        case .relativeInverseDepthFloat16: bytesPerPixel = 2
        }
        return resolution.width <= Int.max / bytesPerPixel &&
            CVPixelBufferGetBytesPerRow(buffer) >= resolution.width * bytesPerPixel
    }

    private var expectedPixelFormat: OSType {
        switch encoding {
        case .categoricalUInt8, .confidenceUNorm8,
             .depthConfidenceLevelUInt8:
            return kCVPixelFormatType_OneComponent8
        case .opticalAxisMetersFloat32:
            return kCVPixelFormatType_DepthFloat32
        case .relativeInverseDepthFloat16:
            return kCVPixelFormatType_OneComponent16Half
        }
    }

    private static func unitContains(_ uv: SIMD2<Float>) -> Bool {
        uv.x.isFinite && uv.y.isFinite && uv.x >= 0 && uv.x <= 1 &&
            uv.y >= 0 && uv.y <= 1
    }
}

/// The fit is evidence over a bounded relative-value interval and a bounded
/// optical-axis depth interval. It is intentionally separate from the raster's
/// storage encoding: an unfit model output has no metric depth.
struct OcclusionInverseDepthFit: Sendable {
    let a: Float
    let b: Float
    let relativeRange: ClosedRange<Float>
    let metricRange: ClosedRange<Float>

    var isValid: Bool {
        guard a.isFinite, b.isFinite, a != 0,
              relativeRange.lowerBound.isFinite, relativeRange.upperBound.isFinite,
              relativeRange.lowerBound < relativeRange.upperBound,
              metricRange.lowerBound.isFinite, metricRange.upperBound.isFinite,
              metricRange.lowerBound > 0,
              metricRange.lowerBound < metricRange.upperBound else { return false }
        let firstInverse = a * relativeRange.lowerBound + b
        let lastInverse = a * relativeRange.upperBound + b
        return firstInverse.isFinite && firstInverse > 0 &&
            lastInverse.isFinite && lastInverse > 0
    }
}

/// CPU reference adapters for the shader's depth conventions. Every result is
/// optical-axis metres; invalid, unsupported or out-of-image inputs return nil.
enum OcclusionDepthUnits {
    static func opticalAxisMeters(
        _ value: Float, support: ClosedRange<Float>
    ) -> Float? {
        guard valid(support), value.isFinite, value > 0,
              support.contains(value) else { return nil }
        return value
    }

    static func rayRangeMeters(
        _ range: Float, captureUV: SIMD2<Float>,
        capture: OcclusionCapture, support: ClosedRange<Float>
    ) -> Float? {
        guard capture.isValid, range.isFinite, range > 0,
              captureUV.x.isFinite, captureUV.y.isFinite,
              (0...1).contains(captureUV.x), (0...1).contains(captureUV.y) else {
            return nil
        }
        let pixel = SIMD3(
            captureUV.x * Float(capture.imageResolution.width),
            captureUV.y * Float(capture.imageResolution.height), 1
        )
        let ray = simd_inverse(capture.intrinsics) * pixel
        guard ray.x.isFinite, ray.y.isFinite, ray.z.isFinite, ray.z > 0 else {
            return nil
        }
        let axialRay = ray / ray.z
        let length = simd_length(axialRay)
        guard length.isFinite, length > 0 else { return nil }
        return opticalAxisMeters(range / length, support: support)
    }

    static func inverseAxisDepth(
        _ inverseMeters: Float, support: ClosedRange<Float>
    ) -> Float? {
        guard inverseMeters.isFinite, inverseMeters > 0 else { return nil }
        return opticalAxisMeters(1 / inverseMeters, support: support)
    }

    static func relativeDisparity(
        _ relative: Float, fit: OcclusionInverseDepthFit
    ) -> Float? {
        guard fit.isValid, relative.isFinite,
              fit.relativeRange.contains(relative) else { return nil }
        let inverseMeters = fit.a * relative + fit.b
        return inverseAxisDepth(inverseMeters, support: fit.metricRange)
    }

    private static func valid(_ support: ClosedRange<Float>) -> Bool {
        support.lowerBound.isFinite && support.upperBound.isFinite &&
            support.lowerBound > 0 && support.lowerBound <= support.upperBound
    }
}
