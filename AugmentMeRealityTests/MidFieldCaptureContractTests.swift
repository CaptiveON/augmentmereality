import CoreVideo
import XCTest
import simd
@testable import AugmentMeReality

final class MidFieldCaptureContractTests: XCTestCase {
    private func buffer(width: Int = 8, height: Int = 8,
                        format: OSType = kCVPixelFormatType_OneComponent16Half) throws
        -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, nil, &created),
                       kCVReturnSuccess)
        return try XCTUnwrap(created)
    }

    private func capture(generation: UInt64 = 7, stream: UInt64 = 1,
                         timestamp: TimeInterval = 10, translationX: Float = 0,
                         focalX: Float = 4) -> OcclusionCapture {
        let pose = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(translationX, 0, 0, 1)
        ))
        let intrinsics = simd_float3x3(columns: (
            SIMD3(focalX, 0, 0), SIMD3(0, 4, 0), SIMD3(4, 4, 1)
        ))
        return OcclusionCapture(
            identity: .init(sessionGeneration: generation, streamRevision: stream,
                            timestamp: timestamp),
            cameraToWorld: pose, intrinsics: intrinsics,
            imageResolution: .init(width: 8, height: 8), trackingNormal: true
        )
    }

    private func sample(_ buffer: CVPixelBuffer, capture: OcclusionCapture,
                        encoding: OcclusionDepthEncoding = .relativeInverseDepthFloat16,
                        confidence: OcclusionConfidenceMeaning = .none,
                        mapping: simd_float3x3 = matrix_identity_float3x3,
                        provenance: OcclusionSampleProvenance = .visionScaleFill,
                        ownership: OcclusionBufferOwnership = .appOwnedCopy)
        -> MidFieldDepthFeed.Sample {
        let raster = OcclusionRaster(
            capture: capture, resolution: .init(width: CVPixelBufferGetWidth(buffer),
                                                height: CVPixelBufferGetHeight(buffer)),
            captureToSample: mapping, encoding: encoding, confidence: confidence,
            support: .full, provenance: provenance, bufferOwnership: ownership
        )
        return .init(relativeDepth: buffer, a: 1, b: 0.25, relMin: 0,
                     relMax: 1, maxTrustedDepth: 5, raster: raster)
    }

    func testStreamRevisionInvalidatesAndOlderCompletionCannotReplaceSample() throws {
        let feed = MidFieldDepthFeed()
        feed.setWorkAdmission(true, generation: 7)
        feed.setStreamRevision(1)
        let token = try XCTUnwrap(feed.admissionToken())
        let first = sample(try buffer(), capture: capture())
        XCTAssertTrue(feed.publish(first, token: token))
        XCTAssertNotNil(feed.snapshot(for: capture(timestamp: 10.02),
                                      framesAfter: 9, maxAge: 0.1))

        feed.setStreamRevision(2)
        XCTAssertFalse(feed.hasSample)
        XCTAssertFalse(feed.publish(first, token: token))

        let newer = sample(try buffer(), capture: capture(stream: 2, timestamp: 11))
        XCTAssertTrue(feed.publish(newer, token: token))
        let delayed = sample(try buffer(), capture: capture(stream: 2, timestamp: 10.5))
        XCTAssertFalse(feed.publish(delayed, token: token))
        XCTAssertEqual(feed.snapshot(for: capture(stream: 2, timestamp: 11.02),
                                     framesAfter: 10, maxAge: 0.1)?.frameTimestamp, 11)
    }

    func testPublicationRejectsWrongFormatMappingAndUnownedOutput() throws {
        let feed = MidFieldDepthFeed()
        feed.setWorkAdmission(true, generation: 7)
        feed.setStreamRevision(1)
        let token = try XCTUnwrap(feed.admissionToken())
        let output = try buffer()
        let source = capture()

        XCTAssertFalse(feed.publish(sample(output, capture: source,
                                           encoding: .confidenceUNorm8,
                                           confidence: .classProbability), token: token))
        XCTAssertFalse(feed.publish(sample(output, capture: source,
                                           provenance: .arkitFrame), token: token))
        XCTAssertFalse(feed.publish(sample(output, capture: source,
                                           ownership: .frameworkPoolRetained), token: token))
        let shifted = simd_float3x3(columns: (
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0.1, 0, 1)
        ))
        XCTAssertFalse(feed.publish(sample(output, capture: source,
                                           mapping: shifted), token: token))
        XCTAssertFalse(feed.hasSample)
    }

    func testSnapshotUsesCapturePoseAndCalibration() throws {
        let feed = MidFieldDepthFeed()
        feed.setWorkAdmission(true, generation: 7)
        feed.setStreamRevision(1)
        let token = try XCTUnwrap(feed.admissionToken())
        XCTAssertTrue(feed.publish(sample(try buffer(), capture: capture()), token: token))

        XCTAssertNil(feed.snapshot(for: capture(timestamp: 10.02, translationX: 0.02),
                                   framesAfter: 9, maxAge: 0.1))
        XCTAssertNil(feed.snapshot(for: capture(timestamp: 10.02, focalX: 5),
                                   framesAfter: 9, maxAge: 0.1))
        XCTAssertNotNil(feed.snapshot(for: capture(timestamp: 10.02),
                                      framesAfter: 9, maxAge: 0.1))
    }

    func testCopyRejectsDifferentFormatOrDimensionsBeforeLocking() throws {
        let source = try buffer(width: 8, height: 4, format: kCVPixelFormatType_32BGRA)
        let wrongFormat = try buffer(width: 8, height: 4,
                                     format: kCVPixelFormatType_DepthFloat32)
        let wrongHeight = try buffer(width: 8, height: 5,
                                     format: kCVPixelFormatType_32BGRA)
        XCTAssertFalse(MidFieldDepthEstimator.copyContents(of: source, into: wrongFormat))
        XCTAssertFalse(MidFieldDepthEstimator.copyContents(of: source, into: wrongHeight))
    }
}
