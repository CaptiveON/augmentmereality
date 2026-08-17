import ARKit
import CoreML
import CoreVideo
import Vision
import XCTest

@testable import AugmentMeReality

/// ADR-031: the bundled Depth Anything V2 model must load and predict ON DEVICE,
/// and the LiDAR alignment fit must be exact on synthetic data and refuse noise.
final class MidFieldDepthTests: XCTestCase {

    func testBundledModelLoadsAndPredicts() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc"),
            "compiled model missing from app bundle"
        )
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let vnModel = try VNCoreMLModel(for: model)

        let input = try XCTUnwrap(Self.makeGradientImage(width: 518, height: 392))
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill

        let started = Date()
        try VNImageRequestHandler(cvPixelBuffer: input).perform([request])
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        let observation = try XCTUnwrap(request.results?.first as? VNPixelBufferObservation)
        let depth = observation.pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(depth), 518)
        XCTAssertEqual(CVPixelBufferGetHeight(depth), 392)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(depth),
            kCVPixelFormatType_OneComponent16Half
        )
        // First prediction includes ANE warm-up; just prove it's not pathological.
        XCTAssertLessThan(elapsedMs, 5000, "first prediction unreasonably slow")
    }

    func testInverseDepthFitRecoversKnownAlignment() throws {
        // Synthetic: rel = gradient; lidar = 1 / (a·rel + b) for known a, b.
        // The estimator samples the inner 90% of the frame (rel ≈ 0.23–0.77),
        // so these constants put the OBSERVED depth band at ~0.5–3.9 m — wide
        // enough that the support gate (MATH-1: a band that cannot reach the
        // matte's minimum content distance is refused) accepts the fit.
        let a: Float = 3.23, b: Float = -0.4866
        let rel = try XCTUnwrap(Self.makeHalfFloatBuffer(width: 518, height: 392) { u, _ in
            0.2 + 0.6 * u
        })
        let lidar = try XCTUnwrap(Self.makeDepthBuffer(width: 256, height: 192) { u, _ in
            1.0 / (a * (0.2 + 0.6 * u) + b)
        })
        let fit = try XCTUnwrap(MidFieldDepthEstimator.fitInverseDepth(relative: rel, lidar: lidar))
        XCTAssertEqual(fit.a, a, accuracy: 0.03)
        XCTAssertEqual(fit.b, b, accuracy: 0.03)
    }

    func testFitReportsItsSupportBand() throws {
        // Counsel MATH-1 regression: a fit calibrated on 0.4–4 m LiDAR must
        // report a trusted ceiling just past its reference band — NEVER street
        // range. (Pre-fix, this exact fit was evaluated out to 60 m, where the
        // intercept silently capped all depth at 1/b and sky pixels decoded to
        // a hallucinated near wall that ate far content.)
        // Same constants as the alignment test: observed band ~0.5–3.9 m.
        let a: Float = 3.23, b: Float = -0.4866
        let rel = try XCTUnwrap(Self.makeHalfFloatBuffer(width: 518, height: 392) { u, _ in
            0.2 + 0.6 * u
        })
        let lidar = try XCTUnwrap(Self.makeDepthBuffer(width: 256, height: 192) { u, _ in
            1.0 / (a * (0.2 + 0.6 * u) + b)
        })
        let fit = try XCTUnwrap(MidFieldDepthEstimator.fitInverseDepth(relative: rel, lidar: lidar))
        // Input support ≈ the rel band that had LiDAR references (small slack).
        XCTAssertEqual(fit.relMin, 0.2, accuracy: 0.05)
        XCTAssertEqual(fit.relMax, 0.8, accuracy: 0.05)
        // Output ceiling = farthest observed reference × margin. The invariant,
        // not the sampling arithmetic: it must clear the matte's 4 m minimum
        // (else the fit is refused) yet stay under 4 m × margin — the hard
        // bound the 0.4–4 m acceptance band imposes.
        XCTAssertGreaterThan(fit.maxTrustedDepth, AppConfig.midDepthMinContentDistance)
        XCTAssertLessThanOrEqual(fit.maxTrustedDepth, 4.0 * AppConfig.midDepthSupportMargin)
        XCTAssertLessThan(
            fit.maxTrustedDepth, 50,
            "a 0.4–4 m-band fit must never claim to measure street range"
        )
    }

    func testFitRefusesBandThatCannotReachContent() throws {
        // MATH-1 honesty gate: reference depths top out at 2.5 m ⇒ trusted
        // ceiling ~3.1 m < the matte's 4 m minimum content distance. Publishing
        // this fit would light the DPT chip while structurally unable to matte
        // anything — it must be refused outright.
        let a: Float = 2.667, b: Float = -0.133
        let rel = try XCTUnwrap(Self.makeHalfFloatBuffer(width: 518, height: 392) { u, _ in
            0.2 + 0.6 * u
        })
        let lidar = try XCTUnwrap(Self.makeDepthBuffer(width: 256, height: 192) { u, _ in
            1.0 / (a * (0.2 + 0.6 * u) + b)
        })
        XCTAssertNil(MidFieldDepthEstimator.fitInverseDepth(relative: rel, lidar: lidar))
    }

    func testInverseDepthFitRejectsUncorrelatedData() throws {
        // rel constant (zero variance) — must refuse rather than hallucinate.
        let rel = try XCTUnwrap(Self.makeHalfFloatBuffer(width: 518, height: 392) { _, _ in 0.5 })
        let lidar = try XCTUnwrap(Self.makeDepthBuffer(width: 256, height: 192) { u, v in
            0.5 + 3.0 * abs(sin(u * 20 + v * 13))
        })
        XCTAssertNil(MidFieldDepthEstimator.fitInverseDepth(relative: rel, lidar: lidar))
    }

    // MARK: - Buffer helpers

    private static func makeGradientImage(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
        )
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                pixels[offset] = UInt8((x * 255) / width)
                pixels[offset + 1] = UInt8((y * 255) / height)
                pixels[offset + 2] = 128
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    private static func makeHalfFloatBuffer(
        width: Int, height: Int, value: (Float, Float) -> Float
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent16Half, nil, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt16>.size
        let pixels = base.assumingMemoryBound(to: UInt16.self)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(Float(x) / Float(width), Float(y) / Float(height))
                pixels[y * stride + x] = Float16(v).bitPattern
            }
        }
        return buffer
    }

    private static func makeDepthBuffer(
        width: Int, height: Int, value: (Float, Float) -> Float
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_DepthFloat32, nil, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        let pixels = base.assumingMemoryBound(to: Float.self)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * stride + x] = value(Float(x) / Float(width), Float(y) / Float(height))
            }
        }
        return buffer
    }
}
