import CoreVideo
import Metal
import RealityKit
import simd
import XCTest
@testable import AugmentMeReality

final class RenderLifecycleTests: XCTestCase {
    func testDetachAndReattachRejectOldCallbackWhileCPUAndGPURemainInFlight() throws {
        let lifecycle = RenderCallbackLifecycle()
        let first = try XCTUnwrap(lifecycle.attach())
        let started = DispatchSemaphore(value: 0)
        let releaseCPU = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue(label: "render-lifecycle-overlap").async {
            let accepted = lifecycle.beginCPU(epoch: first)
            XCTAssertTrue(accepted)
            started.signal()
            guard releaseCPU.wait(timeout: .now() + 2) == .success else {
                XCTFail("controlled CPU overlap timed out")
                lifecycle.finishCPU()
                finished.signal()
                return
            }
            lifecycle.finishCPU()
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(lifecycle.submitGPU(epoch: first))
        XCTAssertEqual(lifecycle.snapshot.cpuCallbacks, 1)
        XCTAssertEqual(lifecycle.snapshot.gpuCommands, 1)

        XCTAssertTrue(lifecycle.detach())
        let second = try XCTUnwrap(lifecycle.attach())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(lifecycle.accepts(first))
        XCTAssertFalse(lifecycle.beginCPU(epoch: first))
        lifecycle.finishCPU() // the stale callback still performs a target blit
        XCTAssertFalse(lifecycle.submitGPU(epoch: first))
        XCTAssertTrue(lifecycle.beginCPU(epoch: second))
        lifecycle.finishCPU()

        releaseCPU.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(lifecycle.snapshot.cpuCallbacks, 0)
        XCTAssertEqual(lifecycle.snapshot.gpuCommands, 1)
        lifecycle.uninstall()
        XCTAssertFalse(lifecycle.accepts(second))
        XCTAssertNil(lifecycle.attach(), "an uninstalled pass is terminal")
        lifecycle.finishGPU()
        XCTAssertEqual(lifecycle.snapshot.gpuCommands, 0)
    }

    func testGPUResourceLeaseSurvivesDetachAndRecyclesOnlyAfterCompletion() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test host")
        }
        var cvCache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil, nil, device, nil, &cvCache), kCVReturnSuccess)
        let cache = RenderTextureCache(try XCTUnwrap(cvCache))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false
        )
        final class WeakTexture { weak var value: AnyObject? }
        let weakTexture = WeakTexture()
        let lease = try autoreleasepool { () -> RenderGPUResourceLease in
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            weakTexture.value = texture
            return RenderGPUResourceLease(
                wrappers: [], textures: [texture], pipeline: nil, cache: cache
            )
        }
        XCTAssertNotNil(weakTexture.value, "the completion lease must retain GPU inputs")
        XCTAssertEqual(cache.snapshot.gpuLeases, 1)

        cache.flushAfterGPU() // detach while the GPU command is outstanding
        XCTAssertTrue(cache.snapshot.deferredFlush)
        XCTAssertEqual(lease.snapshot.textures, 1)
        XCTAssertTrue(lease.complete())
        XCTAssertEqual(cache.snapshot.gpuLeases, 0)
        XCTAssertFalse(cache.snapshot.deferredFlush)
        XCTAssertEqual(lease.snapshot.textures, 0)
        XCTAssertFalse(lease.complete(), "duplicate completion cannot release/count twice")
        XCTAssertEqual(cache.snapshot.gpuLeases, 0)
        XCTAssertNil(weakTexture.value, "completion must release retained Metal resources")
    }

    func testCoreVideoWrapperStaysLeasedThroughActualMetalCompletion() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test host")
        }
        var rawCache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil, nil, device, nil, &rawCache), kCVReturnSuccess)
        let cache = RenderTextureCache(try XCTUnwrap(rawCache))
        var rawPixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        XCTAssertEqual(CVPixelBufferCreate(
            nil, 2, 2, kCVPixelFormatType_32BGRA, attributes as CFDictionary,
            &rawPixelBuffer
        ), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(rawPixelBuffer)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            XCTFail("could not lock Core Video input")
            return
        }
        do {
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
                .assumingMemoryBound(to: UInt8.self)
            base[0] = 17
            base[1] = 31
            base[2] = 79
            base[3] = 255
        }

        var wrapper: CVMetalTexture? = try XCTUnwrap(cache.makeTexture(
            pixelBuffer, format: .bgra8Unorm, width: 2, height: 2, plane: 0
        ))
        var cameraTexture: MTLTexture? = try XCTUnwrap(CVMetalTextureGetTexture(wrapper!))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false
        )
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
        encoder.copy(from: try XCTUnwrap(cameraTexture), to: target)
        encoder.endEncoding()

        let lease = RenderGPUResourceLease(
            wrappers: [try XCTUnwrap(wrapper)],
            textures: [try XCTUnwrap(cameraTexture), target],
            pipeline: nil, cache: cache
        )
        wrapper = nil
        cameraTexture = nil
        cache.flushAfterGPU() // detach before the encoded copy has run
        XCTAssertEqual(lease.snapshot.wrappers, 1)
        XCTAssertEqual(cache.snapshot.gpuLeases, 1)
        XCTAssertTrue(cache.snapshot.deferredFlush)

        let completed = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in
            lease.complete()
            completed.signal()
        }
        command.commit()
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(command.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes.withUnsafeMutableBytes { output in
            target.getBytes(output.baseAddress!, bytesPerRow: 8,
                            from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        }
        XCTAssertEqual(Array(bytes.prefix(4)), [17, 31, 79, 255])
        XCTAssertEqual(lease.snapshot.wrappers, 0)
        XCTAssertEqual(cache.snapshot.gpuLeases, 0)
        XCTAssertFalse(cache.snapshot.deferredFlush)
        XCTAssertFalse(lease.complete())
    }

    @MainActor
    func testOldProductionCallbackBlitsAfterReattachAndOutlivesUninstall() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test host")
        }
        let view = ARView(frame: .zero)
        var pass: SemanticOcclusionPass? = SemanticOcclusionPass(
            feed: SemanticFeed(), labelBuilding: 1, labelTree: 2,
            labelStructure: 3, personOcclusionEnabled: false, midDepthFeed: nil
        )
        weak let weakPass = pass
        pass?.prepare(on: view)
        pass?.setCallbacksActive(true)
        var oldCallback = try XCTUnwrap(view.renderCallbacks.postProcess)
        pass?.setCallbacksActive(false)
        pass?.setCallbacksActive(true)
        XCTAssertNotNil(view.renderCallbacks.postProcess)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false
        )
        descriptor.storageMode = .shared
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let input: [UInt8] = [23, 41, 89, 255, 23, 41, 89, 255,
                              23, 41, 89, 255, 23, 41, 89, 255]
        input.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: 8)
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let context = ARView.PostProcessContext(
            device, commandBuffer, source, source, target, matrix_identity_float4x4, 0
        )
        oldCallback(context)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        var output = [UInt8](repeating: 0, count: 16)
        output.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: 8,
                            from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        }
        XCTAssertEqual(output, input, "the retired callback still writes target")

        pass?.uninstall()
        pass = nil
        XCTAssertNotNil(weakPass, "a retained callback owns the pass until it finishes")
        XCTAssertNil(view.renderCallbacks.postProcess)
        oldCallback = { _ in }
    }
}
