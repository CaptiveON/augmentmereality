import Foundation
import simd

/// RealityKit exposes a projection and scene elapsed time, but no rendered
/// ARFrame identity or camera pose. This policy admits only an explicitly
/// APPROXIMATE association after recent captures establish bounded motion.
/// Its limits are admission limits, not measured pixel-registration guarantees.
struct RenderFrameAssociation: Sendable {
    enum Rejection: String, Sendable {
        case invalidCapture, generation, stream, beforeStream, tracking
        case future, expired, calibration, motion, viewport, projection
        case renderClock, warmingUp, captureGap
    }

    enum Decision: Equatable, Sendable {
        case approximate
        case rejected(Rejection)
    }

    struct Viewport: Sendable {
        let size: SIMD2<Float>
        /// UIInterfaceOrientation raw value; unknown is never inferred as portrait.
        let orientation: Int
        let observedAt: TimeInterval
    }

    struct Context: Sendable {
        let observedAt: TimeInterval
        /// Scene clock, used only for monotonic callback order. Never ARKit uptime.
        let sceneElapsedTime: TimeInterval
        let viewport: Viewport
        let targetSize: SIMD2<Float>
        let renderProjection: simd_float4x4
        let captureProjection: simd_float4x4
        let viewToCapture: simd_float3x3
    }

    struct Limits: Sendable {
        var maximumCaptureAge: TimeInterval = 0.05
        var maximumViewportAge: TimeInterval = 0.05
        var maximumCaptureGap: TimeInterval = 0.075
        var minimumHistorySpan: TimeInterval = 0.03
        var translationMeters: Float = 0.0015
        var rotationRadians: Float = 0.003
        var projectionPixelTolerance: Float = 1
    }

    let limits: Limits
    private var captures: [OcclusionCapture] = []
    private var previousContext: Context?

    init(limits: Limits = Limits()) { self.limits = limits }

    mutating func reset() {
        captures.removeAll(keepingCapacity: true)
        previousContext = nil
    }

    /// Only capture metadata is retained (at most four); never an ARFrame or image.
    mutating func evaluate(capture: OcclusionCapture, context: Context,
                           generation: UInt64, streamRevision: UInt64,
                           framesAfter: TimeInterval) -> Decision {
        guard capture.isValid else { reset(); return .rejected(.invalidCapture) }
        guard capture.sessionGeneration == generation else { reset(); return .rejected(.generation) }
        guard capture.streamRevision == streamRevision else { reset(); return .rejected(.stream) }
        guard framesAfter.isFinite, capture.timestamp > framesAfter else {
            reset(); return .rejected(.beforeStream)
        }
        guard capture.trackingNormal else { reset(); return .rejected(.tracking) }
        let age = context.observedAt - capture.timestamp
        guard age.isFinite, age >= 0 else { reset(); return .rejected(.future) }
        guard age <= limits.maximumCaptureAge else { reset(); return .rejected(.expired) }
        guard context.viewport.observedAt > framesAfter,
              Self.validViewport(context, maximumAge: limits.maximumViewportAge) else {
            reset(); return .rejected(.viewport)
        }
        guard Self.projectionsAgree(context, pixelTolerance: limits.projectionPixelTolerance) else {
            reset(); return .rejected(.projection)
        }
        guard context.sceneElapsedTime.isFinite, context.sceneElapsedTime >= 0 else {
            reset(); return .rejected(.renderClock)
        }
        if let old = previousContext {
            guard context.sceneElapsedTime > old.sceneElapsedTime else {
                reset(); return .rejected(.renderClock)
            }
            if context.viewport.orientation != old.viewport.orientation
                || context.viewport.size != old.viewport.size
                || context.targetSize != old.targetSize
                || !Self.sameMapping(context.viewToCapture, old.viewToCapture) {
                reset()
                previousContext = context
                captures = [capture]
                return .rejected(.viewport)
            }
        }
        previousContext = context
        if let last = captures.last {
            if let reason = Self.sampleRejection(last, relativeTo: capture,
                                                 framesAfter: framesAfter,
                                                 maxAge: limits.maximumCaptureGap,
                                                 translationMeters: limits.translationMeters,
                                                 rotationRadians: limits.rotationRadians) {
                captures = [capture]
                return .rejected(reason == .expired ? .captureGap : reason)
            }
        }
        if captures.last?.timestamp != capture.timestamp { captures.append(capture) }
        if captures.count > 4 { captures.removeFirst(captures.count - 4) }
        guard let first = captures.first,
              capture.timestamp - first.timestamp >= limits.minimumHistorySpan else {
            return .rejected(.warmingUp)
        }
        for old in captures {
            guard old.hasCompatibleCalibration(with: capture, tolerancePixels: 0.25) else {
                captures = [capture]
                return .rejected(.calibration)
            }
            guard old.hasCompatiblePose(with: capture,
                                        translationToleranceMeters: limits.translationMeters,
                                        rotationToleranceRadians: limits.rotationRadians) else {
                captures = [capture]
                return .rejected(.motion)
            }
        }
        return .approximate
    }

    /// Delayed inference has its own age/pose gate in addition to the render
    /// association. Static camera motion does not prove moving objects are static.
    static func sampleRejection(_ sample: OcclusionCapture, relativeTo current: OcclusionCapture,
                                framesAfter: TimeInterval, maxAge: TimeInterval,
                                translationMeters: Float = 0.0015,
                                rotationRadians: Float = 0.003) -> Rejection? {
        guard sample.isValid, current.isValid, maxAge.isFinite, maxAge >= 0 else { return .invalidCapture }
        guard sample.sessionGeneration == current.sessionGeneration else { return .generation }
        guard sample.streamRevision == current.streamRevision else { return .stream }
        guard framesAfter.isFinite, sample.timestamp > framesAfter else { return .beforeStream }
        guard sample.trackingNormal, current.trackingNormal else { return .tracking }
        let age = current.timestamp - sample.timestamp
        guard age >= 0 else { return .future }
        guard age <= maxAge else { return .expired }
        guard sample.hasCompatibleCalibration(with: current, tolerancePixels: 0.25) else { return .calibration }
        guard sample.hasCompatiblePose(with: current, translationToleranceMeters: translationMeters,
                                       rotationToleranceRadians: rotationRadians) else { return .motion }
        return nil
    }

    private static func validViewport(_ context: Context, maximumAge: TimeInterval) -> Bool {
        let size = context.viewport.size, target = context.targetSize
        let age = context.observedAt - context.viewport.observedAt
        guard (1...4).contains(context.viewport.orientation), age.isFinite,
              age >= 0, age <= maximumAge,
              size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0,
              target.x.isFinite, target.y.isFinite, target.x > 0, target.y > 0,
              abs(size.x / size.y - target.x / target.y) < 0.002 else { return false }
        let map = context.viewToCapture
        guard finite(map) && abs(simd_determinant(map)) > 1e-8
            && abs(map.columns.0.z) < 1e-6 && abs(map.columns.1.z) < 1e-6
            && abs(map.columns.2.z - 1) < 1e-6 else { return false }
        let corners: [SIMD3<Float>] = [[0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1], [0.5, 0.5, 1]]
        for uv in corners {
            let point = map * uv
            guard point.x >= -1e-5, point.y >= -1e-5,
                  point.x <= 1.00001, point.y <= 1.00001 else { return false }
        }
        return true
    }

    /// Compare projected x/y of asymmetric camera-space rays. Z near/far and
    /// forward/reverse depth conventions may differ; screen geometry may not.
    private static func projectionsAgree(_ context: Context, pixelTolerance: Float) -> Bool {
        let rays: [SIMD4<Float>] = [[0, 0, -1, 1], [0.23, -0.31, -1, 1],
                                    [-0.41, 0.17, -1, 1], [0.37, 0.29, -2, 1]]
        for ray in rays {
            let a = context.renderProjection * ray, b = context.captureProjection * ray
            guard finite(a), finite(b), abs(a.w) > 1e-6, abs(b.w) > 1e-6 else { return false }
            let error = abs(SIMD2(a.x / a.w - b.x / b.w, a.y / a.w - b.y / b.w))
                * context.targetSize * 0.5
            guard error.x <= pixelTolerance, error.y <= pixelTolerance else { return false }
        }
        return true
    }

    private static func sameMapping(_ a: simd_float3x3, _ b: simd_float3x3) -> Bool {
        (0..<3).allSatisfy { simd_length(a[$0] - b[$0]) <= 1e-5 }
    }

    private static func finite(_ m: simd_float3x3) -> Bool {
        (0..<3).allSatisfy { m[$0].x.isFinite && m[$0].y.isFinite && m[$0].z.isFinite }
    }
    private static func finite(_ v: SIMD4<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite
    }
}
