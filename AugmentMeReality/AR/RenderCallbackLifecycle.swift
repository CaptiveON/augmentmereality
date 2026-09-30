import CoreVideo
import Foundation
import Metal
import os.lock

/// The main actor owns RealityKit's callback slots. A callback can nevertheless
/// arrive after its slot has been replaced, so each installed closure carries
/// an epoch and must ask this gate before reading the current scene.
final class RenderCallbackLifecycle: Sendable {
    struct Snapshot: Equatable, Sendable {
        let epoch: UInt64
        let active: Bool
        let uninstalled: Bool
        let cpuCallbacks: Int
        let gpuCommands: Int
    }

    private struct State {
        var epoch: UInt64 = 0
        var active = false
        var uninstalled = false
        var cpuCallbacks = 0
        var gpuCommands = 0

        func accepts(_ epoch: UInt64) -> Bool {
            active && !uninstalled && self.epoch == epoch
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Returns the new identity only for a real attach. A torn-down pass is
    /// terminal; a new camera session constructs a new pass.
    func attach() -> UInt64? {
        state.withLock { state in
            guard !state.active, !state.uninstalled else { return nil }
            state.epoch &+= 1
            state.active = true
            return state.epoch
        }
    }

    @discardableResult
    func detach() -> Bool {
        state.withLock { state in
            guard state.active else { return false }
            state.active = false
            return true
        }
    }

    func uninstall() {
        state.withLock { state in
            state.active = false
            state.uninstalled = true
        }
    }

    /// Count even a stale callback: it still owes RealityKit a target blit.
    /// The pass's separate state lock serializes actual resource use and teardown.
    func beginCPU(epoch: UInt64) -> Bool {
        state.withLock { state in
            state.cpuCallbacks += 1
            return state.accepts(epoch)
        }
    }

    func accepts(_ epoch: UInt64) -> Bool {
        state.withLock { $0.accepts(epoch) }
    }

    func finishCPU() {
        state.withLock { state in
            precondition(state.cpuCallbacks > 0)
            state.cpuCallbacks -= 1
        }
    }

    /// GPU work may outlive detach or uninstall. Its completion owns the
    /// corresponding resource lease and balances this count in every status.
    @discardableResult
    func submitGPU(epoch: UInt64) -> Bool {
        state.withLock { state in
            guard state.accepts(epoch) else { return false }
            state.gpuCommands += 1
            return true
        }
    }

    func finishGPU() {
        state.withLock { state in
            precondition(state.gpuCommands > 0)
            state.gpuCommands -= 1
        }
    }

    var snapshot: Snapshot {
        state.withLock { state in
            Snapshot(epoch: state.epoch, active: state.active,
                     uninstalled: state.uninstalled,
                     cpuCallbacks: state.cpuCallbacks, gpuCommands: state.gpuCommands)
        }
    }
}

/// Serializes Core Video cache operations across the render callback and Metal
/// completion queue. A detach flushes immediately, then requests one more
/// flush after the final outstanding GPU lease releases its wrappers.
final class RenderTextureCache: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let gpuLeases: Int
        let deferredFlush: Bool
    }

    // Core Video does not declare the cache Sendable. Every operation on this
    // exact cache, including completion-side recycling, takes this lock.
    private let lock = NSLock()
    private let cache: CVMetalTextureCache
    private var gpuLeases = 0
    private var deferredFlush = false

    init(_ cache: CVMetalTextureCache) {
        self.cache = cache
    }

    /// Plane accessors are invalid for non-planar images. Every source is
    /// validated before wrapping so an unsupported representation cannot be
    /// silently reinterpreted as another depth or confidence convention.
    func makeTexture(_ pixelBuffer: CVPixelBuffer, format: MTLPixelFormat,
                     plane: Int = 0) -> CVMetalTexture? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planes = CVPixelBufferGetPlaneCount(pixelBuffer)
        let width: Int, height: Int
        if planes > 0 {
            guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                  planes == 2, plane == 0 || plane == 1,
                  format == (plane == 0 ? .r8Unorm : .rg8Unorm) else { return nil }
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        } else {
            guard plane == 0 else { return nil }
            switch pixelFormat {
            case kCVPixelFormatType_OneComponent8:
                guard format == .r8Uint || format == .r8Unorm else { return nil }
            case kCVPixelFormatType_DepthFloat32:
                guard format == .r32Float else { return nil }
            case kCVPixelFormatType_OneComponent16Half:
                guard format == .r16Float else { return nil }
            default: return nil
            }
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
        }
        guard width > 0, height > 0 else { return nil }
        return makeTexture(pixelBuffer, format: format, width: width, height: height, plane: plane)
    }

    func makeTexture(_ pixelBuffer: CVPixelBuffer, format: MTLPixelFormat,
                     width: Int, height: Int, plane: Int) -> CVMetalTexture? {
        lock.lock()
        defer { lock.unlock() }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, format, width, height, plane, &texture
        )
        return status == kCVReturnSuccess ? texture : nil
    }

    func flush() {
        lock.lock()
        CVMetalTextureCacheFlush(cache, 0)
        lock.unlock()
    }

    func beginGPU() {
        lock.lock()
        gpuLeases += 1
        lock.unlock()
    }

    func finishGPU() {
        lock.lock()
        precondition(gpuLeases > 0)
        gpuLeases -= 1
        if gpuLeases == 0, deferredFlush {
            CVMetalTextureCacheFlush(cache, 0)
            deferredFlush = false
        }
        lock.unlock()
    }

    func flushAfterGPU() {
        lock.lock()
        CVMetalTextureCacheFlush(cache, 0)
        deferredFlush = gpuLeases > 0
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(gpuLeases: gpuLeases, deferredFlush: deferredFlush)
    }
}

/// A successful compute encode transfers its Core Video wrappers and Metal
/// resources here. The completion handler owns this lease through GPU finish,
/// even if the pass and its ARView have already been torn down.
final class RenderGPUResourceLease: Sendable {
    struct Snapshot: Equatable, Sendable {
        let wrappers: Int
        let textures: Int
        let pixelBuffers: Int
        let completed: Bool
    }

    private struct Resources: @unchecked Sendable {
        var wrappers: [CVMetalTexture]
        var textures: [MTLTexture]
        var pixelBuffers: [CVPixelBuffer]
        var pipeline: MTLComputePipelineState?
        var cache: RenderTextureCache?
        var completed = false
    }

    private let resources: OSAllocatedUnfairLock<Resources>

    init(wrappers: [CVMetalTexture], textures: [MTLTexture],
         pipeline: MTLComputePipelineState?, cache: RenderTextureCache?,
         pixelBuffers: [CVPixelBuffer] = []) {
        cache?.beginGPU()
        resources = OSAllocatedUnfairLock(initialState: Resources(
            wrappers: wrappers, textures: textures, pixelBuffers: pixelBuffers,
            pipeline: pipeline, cache: cache
        ))
    }

    /// Called once by Metal after success OR failure. Idempotence also makes a
    /// duplicate completion harmless if a test or future adapter invokes it.
    @discardableResult
    func complete() -> Bool {
        let (first, cache) = resources.withLock { resources -> (Bool, RenderTextureCache?) in
            guard !resources.completed else { return (false, nil) }
            resources.completed = true
            resources.wrappers.removeAll()
            resources.textures.removeAll()
            resources.pixelBuffers.removeAll()
            resources.pipeline = nil
            let cache = resources.cache
            resources.cache = nil
            return (true, cache)
        }
        cache?.finishGPU()
        return first
    }

    var snapshot: Snapshot {
        resources.withLock { resources in
            Snapshot(wrappers: resources.wrappers.count,
                     textures: resources.textures.count,
                     pixelBuffers: resources.pixelBuffers.count,
                     completed: resources.completed)
        }
    }
}
