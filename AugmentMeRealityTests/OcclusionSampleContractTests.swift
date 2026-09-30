import CoreVideo
import simd
import XCTest

@testable import AugmentMeReality

final class OcclusionSampleContractTests: XCTestCase {
    private func capture(
        timestamp: TimeInterval = 100,
        principalX: Float = 623,
        resolution: OcclusionRasterSize = .init(width: 1_600, height: 900),
        pose: simd_float4x4 = matrix_identity_float4x4
    ) -> OcclusionCapture {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(1_103, 0, 0),
            SIMD3<Float>(0, 713, 0),
            SIMD3<Float>(principalX, 411, 1)
        ))
        return .init(
            identity: .init(sessionGeneration: 7, streamRevision: 2,
                            timestamp: timestamp),
            cameraToWorld: pose,
            intrinsics: intrinsics,
            imageResolution: resolution,
            trackingNormal: true
        )
    }

    private func raster(
        capture source: OcclusionCapture,
        resolution: OcclusionRasterSize = .init(width: 53, height: 29),
        mapping: simd_float3x3 = matrix_identity_float3x3,
        encoding: OcclusionDepthEncoding = .categoricalUInt8,
        confidence: OcclusionConfidenceMeaning = .none,
        support: OcclusionUVRect = .full
    ) -> OcclusionRaster {
        .init(capture: source, resolution: resolution,
              captureToSample: mapping, encoding: encoding,
              confidence: confidence, support: support,
              provenance: .garSubmittedFrameOpaque,
              bufferOwnership: .frameworkPoolRetained)
    }

    private func buffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format,
                    attributes as CFDictionary, &result), kCVReturnSuccess)
        return try XCTUnwrap(result)
    }

    func testAsymmetricRotationCropAndInverseHaveIndependentExpectedCoordinates() throws {
        // Hand-calculated fixture, deliberately neither square nor centered:
        // sampleU = 1.25*captureV - 0.125; sampleV = 0.75 - 0.5*captureU.
        // It catches x/y swaps, missing orientation, crop offsets and assuming
        // the 53x29 labels share the camera's 1600x900 pixel coordinates.
        let mapping = simd_float3x3(columns: (
            SIMD3<Float>(0, -0.5, 0),
            SIMD3<Float>(1.25, 0, 0),
            SIMD3<Float>(-0.125, 0.75, 1)
        ))
        let labels = raster(capture: capture(), mapping: mapping,
            support: .init(minimum: [0.2, 0.3], maximum: [0.8, 0.7]))
        XCTAssertTrue(labels.isValid)
        let sample = try XCTUnwrap(labels.sampleUV(forCaptureUV: [0.2, 0.7]))
        XCTAssertEqual(sample.x, 0.75, accuracy: 1e-6)
        XCTAssertEqual(sample.y, 0.65, accuracy: 1e-6)
        let returned = try XCTUnwrap(labels.captureUV(forSampleUV: [0.75, 0.65]))
        XCTAssertEqual(returned.x, 0.2, accuracy: 1e-6)
        XCTAssertEqual(returned.y, 0.7, accuracy: 1e-6)
        XCTAssertNil(labels.sampleUV(forCaptureUV: [0, 0]))
        XCTAssertNil(labels.sampleUV(forCaptureUV: [1, 0.7]))
        XCTAssertNil(labels.sampleUV(forCaptureUV: [-0.01, 0.7]))
        XCTAssertNil(labels.captureUV(forSampleUV: [0.1, 0.65]))
    }

    func testCaptureCalibrationAndRigidPoseAreValidatedInTheirReferenceResolution() {
        let baseline = capture()
        XCTAssertTrue(baseline.isValid)
        XCTAssertTrue(baseline.hasCompatibleCalibration(
            with: capture(principalX: 623.2), tolerancePixels: 0.25))
        XCTAssertFalse(baseline.hasCompatibleCalibration(
            with: capture(principalX: 623.4), tolerancePixels: 0.25))
        XCTAssertFalse(baseline.hasCompatibleCalibration(
            with: capture(resolution: .init(width: 800, height: 450)),
            tolerancePixels: 0.25))
        XCTAssertFalse(capture(timestamp: .nan).isValid)
        XCTAssertFalse(capture(resolution: .init(width: 0, height: 900)).isValid)

        var shearedPose = matrix_identity_float4x4
        shearedPose.columns.1.x = 0.3
        XCTAssertFalse(capture(pose: shearedPose).isValid)
        let invalidK = simd_float3x3(columns: (
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 713, 0),
            SIMD3<Float>(623, 411, 1)
        ))
        XCTAssertFalse(OcclusionCapture(
            identity: baseline.identity, cameraToWorld: baseline.cameraToWorld,
            intrinsics: invalidK, imageResolution: baseline.imageResolution,
            trackingNormal: true).isValid)
    }

    func testRasterRefusesDegenerateMappingAndInvalidSupport() {
        let source = capture()
        var singular = matrix_identity_float3x3
        singular.columns.0 = .zero
        XCTAssertFalse(raster(capture: source, mapping: singular).isValid)
        let badSupport = OcclusionUVRect(minimum: [0.9, 0.2], maximum: [0.8, 0.7])
        XCTAssertFalse(raster(capture: source, support: badSupport).isValid)
        var nonFinite = matrix_identity_float3x3
        nonFinite.columns.2.x = .nan
        XCTAssertFalse(raster(capture: source, mapping: nonFinite).isValid)
    }

    func testCameraAndSourceRastersEnforceTheirActualFormatsAndDimensions() throws {
        let source = capture()
        XCTAssertTrue(source.matchesCameraBuffer(try buffer(
            width: 1_600, height: 900,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)))
        XCTAssertFalse(source.matchesCameraBuffer(try buffer(
            width: 1_600, height: 900,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
        XCTAssertFalse(source.matchesCameraBuffer(try buffer(
            width: 800, height: 450,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)))

        let labels = raster(capture: source)
        XCTAssertTrue(labels.matches(try buffer(
            width: 53, height: 29, format: kCVPixelFormatType_OneComponent8)))
        XCTAssertFalse(labels.matches(try buffer(
            width: 29, height: 53, format: kCVPixelFormatType_OneComponent8)))
        XCTAssertFalse(labels.matches(try buffer(
            width: 53, height: 29, format: kCVPixelFormatType_DepthFloat32)))

        let metric = raster(capture: source, resolution: .init(width: 160, height: 90),
                            encoding: .opticalAxisMetersFloat32)
        XCTAssertTrue(metric.matches(try buffer(
            width: 160, height: 90, format: kCVPixelFormatType_DepthFloat32)))
        XCTAssertFalse(metric.matches(try buffer(
            width: 160, height: 90, format: kCVPixelFormatType_OneComponent16Half)))

        let relative = raster(capture: source, resolution: .init(width: 518, height: 392),
                              encoding: .relativeInverseDepthFloat16)
        XCTAssertTrue(relative.matches(try buffer(
            width: 518, height: 392, format: kCVPixelFormatType_OneComponent16Half)))
    }

    func testClassProbabilityForegroundCoverageAndDepthConfidenceRemainDistinct() {
        let source = capture()
        XCTAssertTrue(raster(capture: source, encoding: .confidenceUNorm8,
                             confidence: .classProbability).isValid)
        XCTAssertTrue(raster(capture: source, encoding: .confidenceUNorm8,
                             confidence: .foregroundCoverage).isValid)
        XCTAssertFalse(raster(capture: source, encoding: .confidenceUNorm8,
                              confidence: .depthConfidenceLevels).isValid)
        XCTAssertTrue(raster(capture: source, encoding: .depthConfidenceLevelUInt8,
                             confidence: .depthConfidenceLevels).isValid)
        XCTAssertFalse(raster(capture: source, encoding: .depthConfidenceLevelUInt8,
                              confidence: .classProbability).isValid)
        XCTAssertFalse(raster(capture: source, encoding: .categoricalUInt8,
                              confidence: .classProbability).isValid)
    }

    func testDepthUnitsUseOpticalAxisMetresAndRejectUncalibratedValues() throws {
        let source = capture()
        let support: ClosedRange<Float> = 0.4...4
        XCTAssertEqual(try XCTUnwrap(OcclusionDepthUnits.opticalAxisMeters(
            2, support: support)), 2, accuracy: 1e-6)
        XCTAssertNil(OcclusionDepthUnits.opticalAxisMeters(2_000, support: support),
                     "millimetres must not silently pass as metres")
        XCTAssertNil(OcclusionDepthUnits.opticalAxisMeters(.nan, support: support))
        XCTAssertEqual(try XCTUnwrap(OcclusionDepthUnits.inverseAxisDepth(
            0.5, support: support)), 2, accuracy: 1e-6)
        XCTAssertNil(OcclusionDepthUnits.inverseAxisDepth(0, support: support))

        // Off-axis ray x/z = 0.5, y/z = 0. A 2*sqrt(1.25) m ray range
        // corresponds to 2 m optical-axis depth; at the principal point the
        // same axial value needs only 2 m of range.
        let principal = SIMD2<Float>(623.0 / 1_600.0, 411.0 / 900.0)
        let offAxis = SIMD2<Float>((623.0 + 1_103.0 * 0.5) / 1_600.0,
                                   411.0 / 900.0)
        XCTAssertEqual(try XCTUnwrap(OcclusionDepthUnits.rayRangeMeters(
            2, captureUV: principal, capture: source, support: support)),
            2, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(OcclusionDepthUnits.rayRangeMeters(
            2 * sqrt(1.25), captureUV: offAxis, capture: source, support: support)),
            2, accuracy: 1e-4)
        XCTAssertNil(OcclusionDepthUnits.rayRangeMeters(
            2, captureUV: [1.01, 0.5], capture: source, support: support))

        // Known positive disparity: inverse metres = 0.25*rel + 0.25.
        let fit = OcclusionInverseDepthFit(
            a: 0.25, b: 0.25, relativeRange: 1...3, metricRange: 1...3)
        XCTAssertTrue(fit.isValid)
        XCTAssertEqual(try XCTUnwrap(OcclusionDepthUnits.relativeDisparity(1, fit: fit)),
                       2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(OcclusionDepthUnits.relativeDisparity(3, fit: fit)),
                       1, accuracy: 1e-6)
        XCTAssertNil(OcclusionDepthUnits.relativeDisparity(0.9, fit: fit))
        XCTAssertNil(OcclusionDepthUnits.relativeDisparity(.infinity, fit: fit))
        XCTAssertFalse(OcclusionInverseDepthFit(
            a: 0, b: 0.5, relativeRange: 1...3, metricRange: 1...3).isValid)
    }
}
