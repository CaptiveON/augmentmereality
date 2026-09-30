import CoreVideo
import Metal
import XCTest
@testable import AugmentMeReality

final class OcclusionTextureBindingTests: XCTestCase {
    func testOcclusionBuffersUseTheirActualNonplanarDimensions() throws {
        let cache = try makeCache()
        let cases: [(OSType, MTLPixelFormat)] = [
            (kCVPixelFormatType_OneComponent8, .r8Uint),       // GAR labels
            (kCVPixelFormatType_OneComponent8, .r8Unorm),     // confidence/person
            (kCVPixelFormatType_DepthFloat32, .r32Float),     // ARKit scene depth
            (kCVPixelFormatType_OneComponent16Half, .r16Float), // model output
        ]

        for (pixelFormat, metalFormat) in cases {
            let buffer = try makeBuffer(width: 18, height: 10, format: pixelFormat)
            XCTAssertEqual(CVPixelBufferGetPlaneCount(buffer), 0)
            let wrapper = try XCTUnwrap(cache.makeTexture(buffer, format: metalFormat),
                                        "failed to wrap \(pixelFormat) as \(metalFormat)")
            let texture = try XCTUnwrap(CVMetalTextureGetTexture(wrapper))
            XCTAssertEqual(texture.width, 18)
            XCTAssertEqual(texture.height, 10)
            XCTAssertEqual(texture.pixelFormat, metalFormat)
        }
    }

    func testPlanarCameraPlanesHaveTheirOwnDimensions() throws {
        let cache = try makeCache()
        let buffer = try makeBuffer(
            width: 18, height: 10,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(buffer), 2)

        let luma = try XCTUnwrap(cache.makeTexture(buffer, format: .r8Unorm, plane: 0))
        let lumaTexture = try XCTUnwrap(CVMetalTextureGetTexture(luma))
        XCTAssertEqual(lumaTexture.width, 18)
        XCTAssertEqual(lumaTexture.height, 10)
        XCTAssertEqual(lumaTexture.pixelFormat, .r8Unorm)

        let chroma = try XCTUnwrap(cache.makeTexture(buffer, format: .rg8Unorm, plane: 1))
        let chromaTexture = try XCTUnwrap(CVMetalTextureGetTexture(chroma))
        XCTAssertEqual(chromaTexture.width, 9)
        XCTAssertEqual(chromaTexture.height, 5)
        XCTAssertEqual(chromaTexture.pixelFormat, .rg8Unorm)
    }

    func testInvalidPlaneAndFormatAreRejectedBeforeCoreVideoWrapping() throws {
        let cache = try makeCache()
        let label = try makeBuffer(width: 8, height: 6,
                                   format: kCVPixelFormatType_OneComponent8)
        let depth = try makeBuffer(width: 8, height: 6,
                                   format: kCVPixelFormatType_DepthFloat32)
        let camera = try makeBuffer(
            width: 8, height: 6,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        XCTAssertNil(cache.makeTexture(label, format: .r8Unorm, plane: 1))
        XCTAssertNil(cache.makeTexture(label, format: .r8Unorm, plane: -1))
        XCTAssertNil(cache.makeTexture(camera, format: .r8Unorm, plane: 2))
        XCTAssertNil(cache.makeTexture(depth, format: .r8Unorm))
        XCTAssertNil(cache.makeTexture(label, format: .r32Float))
        XCTAssertNil(cache.makeTexture(camera, format: .r32Float, plane: 1))
    }

    func testNonplanarWrappedPixelsRemainReadableThroughMetalCompletion() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test host")
        }
        let cache = try makeCache(device: device)
        let buffer = try makeBuffer(width: 8, height: 4,
                                    format: kCVPixelFormatType_OneComponent8)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
                .assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<4 {
                for x in 0..<8 { base[y * stride + x] = UInt8(y * 17 + x) }
            }
        }

        var wrapper: CVMetalTexture? = try XCTUnwrap(
            cache.makeTexture(buffer, format: .r8Unorm)
        )
        var source: MTLTexture? = try XCTUnwrap(CVMetalTextureGetTexture(wrapper!))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 8, height: 4, mipmapped: false
        )
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
        encoder.copy(from: try XCTUnwrap(source), to: target)
        encoder.endEncoding()

        let lease = RenderGPUResourceLease(
            wrappers: [try XCTUnwrap(wrapper)],
            textures: [try XCTUnwrap(source), target],
            pipeline: nil, cache: cache
        )
        wrapper = nil
        source = nil
        cache.flushAfterGPU() // simulate detach before GPU completion
        XCTAssertEqual(lease.snapshot.wrappers, 1)
        XCTAssertEqual(cache.snapshot.gpuLeases, 1)

        let completed = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in
            lease.complete()
            completed.signal()
        }
        command.commit()
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(command.status, .completed)
        var pixels = [UInt8](repeating: 0, count: 32)
        pixels.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: 8,
                            from: MTLRegionMake2D(0, 0, 8, 4), mipmapLevel: 0)
        }
        XCTAssertEqual(pixels, (0..<4).flatMap { y in (0..<8).map { UInt8(y * 17 + $0) } })
        XCTAssertEqual(lease.snapshot.wrappers, 0)
        XCTAssertEqual(cache.snapshot.gpuLeases, 0)
        XCTAssertFalse(cache.snapshot.deferredFlush)
    }

    func testCopiedDepthOutputCanBeWrappedAndReadByMetal() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test host")
        }
        let cache = try makeCache(device: device)
        let source = try makeBuffer(width: 8, height: 4,
                                    format: kCVPixelFormatType_OneComponent16Half)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
        do {
            defer { CVPixelBufferUnlockBaseAddress(source, []) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source))
                .assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRow(source) / MemoryLayout<UInt16>.size
            for y in 0..<4 {
                for x in 0..<8 { base[y * stride + x] = Float16(y * 8 + x).bitPattern }
            }
        }

        let copied = try XCTUnwrap(MidFieldDepthEstimator.copyPixelBuffer(source))
        let wrapper = try XCTUnwrap(cache.makeTexture(copied, format: .r16Float))
        let texture = try XCTUnwrap(CVMetalTextureGetTexture(wrapper))
        XCTAssertEqual(texture.width, 8)
        XCTAssertEqual(texture.height, 4)
        XCTAssertEqual(texture.pixelFormat, .r16Float)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: 8, height: 4, mipmapped: false
        )
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
        encoder.copy(from: texture, to: target)
        encoder.endEncoding()

        let lease = RenderGPUResourceLease(
            wrappers: [wrapper], textures: [texture, target],
            pipeline: nil, cache: cache, pixelBuffers: [copied]
        )
        XCTAssertEqual(lease.snapshot.pixelBuffers, 1)
        let completed = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in
            lease.complete()
            completed.signal()
        }
        command.commit()
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(command.status, .completed)

        var readback = [UInt16](repeating: 0, count: 32)
        readback.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: 16,
                            from: MTLRegionMake2D(0, 0, 8, 4), mipmapLevel: 0)
        }
        XCTAssertEqual(readback, (0..<32).map { Float16($0).bitPattern })
        XCTAssertEqual(lease.snapshot.pixelBuffers, 0)
    }

    private func makeCache(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws
        -> RenderTextureCache {
        guard let device else { throw XCTSkip("Metal device unavailable on this test host") }
        var raw: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil, nil, device, nil, &raw), kCVReturnSuccess)
        return RenderTextureCache(try XCTUnwrap(raw))
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var raw: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format,
                                           attributes as CFDictionary, &raw), kCVReturnSuccess)
        return try XCTUnwrap(raw)
    }
}
