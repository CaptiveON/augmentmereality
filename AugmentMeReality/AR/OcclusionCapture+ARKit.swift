import ARKit
import CoreVideo
import simd

extension OcclusionCapture {
    /// Extract values synchronously; this metadata never retains the ARFrame.
    init(frame: ARFrame, generation: UInt64, streamRevision: UInt64) {
        self.init(
            identity: .init(sessionGeneration: generation, streamRevision: streamRevision,
                            timestamp: frame.timestamp),
            cameraToWorld: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageResolution: .init(width: Int(frame.camera.imageResolution.width),
                                   height: Int(frame.camera.imageResolution.height)),
            trackingNormal: frame.camera.trackingState == .normal
        )
    }
}

extension OcclusionRaster {
    /// Guard the full-image adapter against a raster whose unknown crop/FOV
    /// cannot be inferred from its dimensions. Vision scaleFill deliberately
    /// changes aspect, so that separately declared adapter does not use this.
    var hasCompatibleCaptureAspect: Bool {
        guard isValid else { return false }
        return abs(Double(resolution.width) / Double(resolution.height)
                   - Double(capture.imageResolution.width) / Double(capture.imageResolution.height))
            <= 2.0 / Double(resolution.height)
    }

    /// These adapters operate on uncropped, sensor-oriented ARKit/GAR buffers
    /// or Vision's explicit `.up` + `.scaleFill` output. More providers must
    /// supply their own declared transform instead of inheriting this mapping.
    static func captureAligned(_ buffer: CVPixelBuffer, capture: OcclusionCapture,
                               encoding: OcclusionDepthEncoding,
                               confidence: OcclusionConfidenceMeaning = .none,
                               provenance: OcclusionSampleProvenance,
                               ownership: OcclusionBufferOwnership) -> Self {
        Self(capture: capture,
             resolution: .init(width: CVPixelBufferGetWidth(buffer),
                                height: CVPixelBufferGetHeight(buffer)),
             captureToSample: matrix_identity_float3x3, encoding: encoding,
             confidence: confidence, support: .full, provenance: provenance,
             bufferOwnership: ownership)
    }
}
