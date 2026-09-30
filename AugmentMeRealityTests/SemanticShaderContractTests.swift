import Foundation
import Metal
import simd
import XCTest

@testable import AugmentMeReality

/// GPU contract for the production kernel and its actual Swift uniform layout.
/// Keep this test in the app-hosted target: makeDefaultLibrary(bundle: .main)
/// must resolve the same metallib that SemanticOcclusionPass uses in the app.
final class SemanticShaderContractTests: XCTestCase {
    private let targetWidth = 4
    private let targetHeight = 6

    private func texture(
        device: MTLDevice, format: MTLPixelFormat, width: Int, height: Int,
        usage: MTLTextureUsage = [.shaderRead]
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func upload<Element>(_ values: [Element], to texture: MTLTexture,
                                 bytesPerRow: Int) {
        values.withUnsafeBufferPointer { elements in
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                            mipmapLevel: 0, withBytes: elements.baseAddress!,
                            bytesPerRow: bytesPerRow)
        }
    }

    private func render(
        viewToCapture: simd_float3x3,
        captureToSemantic: simd_float3x3 = matrix_identity_float3x3,
        labels: [UInt8]
    ) throws -> [SIMD4<Float>] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this test host")
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        let function = try XCTUnwrap(library.makeFunction(name: "semanticMatte"),
                                     "production semanticMatte kernel missing")
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        let sourceColor = try texture(device: device, format: .rgba16Float,
            width: targetWidth, height: targetHeight)
        let targetColor = try texture(device: device, format: .rgba16Float,
            width: targetWidth, height: targetHeight, usage: [.shaderWrite])
        let red: [UInt16] = [Float16(1).bitPattern, 0, 0, Float16(1).bitPattern]
        upload(Array(repeating: red, count: targetWidth * targetHeight).flatMap { $0 },
               to: sourceColor, bytesPerRow: targetWidth * 4 * MemoryLayout<UInt16>.stride)

        // 6x4 capture: each row has six distinct luma values. In the positive
        // fixture, rotated target pixels (3,0), (3,1), (3,2) sample exactly
        // columns 0, 1, 2 of the first row, respectively.
        let capturedY = try texture(device: device, format: .r32Float,
                                    width: 6, height: 4)
        let row: [Float] = [0.2, 0.4, 0.6, 0.8, 0.3, 0.7]
        upload(Array(repeating: row, count: 4).flatMap { $0 },
               to: capturedY, bytesPerRow: 6 * MemoryLayout<Float>.stride)
        let capturedCbCr = try texture(device: device, format: .rg32Float,
                                       width: 3, height: 2)
        upload([Float](repeating: 0.5, count: 3 * 2 * 2), to: capturedCbCr,
               bytesPerRow: 3 * 2 * MemoryLayout<Float>.stride)

        let semanticLabels = try texture(device: device, format: .r8Uint,
                                         width: 2, height: 3)
        XCTAssertEqual(labels.count, 6)
        upload(labels, to: semanticLabels, bytesPerRow: 2)
        let semanticConfidence = try texture(device: device, format: .r32Float,
                                             width: 2, height: 3)
        upload([Float](repeating: 1, count: 6), to: semanticConfidence,
               bytesPerRow: 2 * MemoryLayout<Float>.stride)

        let previousMatte = try texture(device: device, format: .r16Float,
            width: targetWidth, height: targetHeight)
        let nextMatte = try texture(device: device, format: .r16Float,
            width: targetWidth, height: targetHeight, usage: [.shaderWrite])
        let disabledSource = try texture(device: device, format: .r32Float,
                                         width: 1, height: 1)

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: targetWidth,
            height: targetHeight, mipmapped: false)
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        let sourceDepth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))

        var uniforms = SemanticOcclusionPass.MatteUniforms(
            viewToCapture: viewToCapture,
            captureToSemantic: captureToSemantic,
            captureToPerson: matrix_identity_float3x3,
            personToCapture: matrix_identity_float3x3,
            captureToDepth: matrix_identity_float3x3,
            captureToMid: matrix_identity_float3x3,
            attackAlpha: 1,
            releaseAlpha: 1,
            debugTint: 0,
            projZZ: 0,
            projZW: 1,
            projWSign: -1,
            distTree: 3,
            distBuilding: 10,
            personEnabled: 0,
            semanticEnabled: 1,
            depthBias: 0.1,
            edgeInner: 0.5,
            edgeOuter: 0.9,
            midEnabled: 0,
            midA: 0,
            midB: 0,
            midMinContent: 4,
            midMaxDepth: 5,
            midRelBias: 0.1,
            midRelMin: 0,
            midRelMax: 1,
            contentFarPlane: 10,
            historyValid: 0,
            refineRadius: 0,
            labelBuilding: 1,
            labelTree: 2,
            labelStructure: 3
        )

        let command = try XCTUnwrap(queue.makeCommandBuffer())
        // A real depth render pass initializes a depth32Float texture to 0.25.
        // The chosen projection constants decode that value to 4 metres, just
        // behind the 3-metre tree gate. No CPU depth-texture shortcut is used.
        let depthPass = MTLRenderPassDescriptor()
        depthPass.depthAttachment.texture = sourceDepth
        depthPass.depthAttachment.loadAction = .clear
        depthPass.depthAttachment.storeAction = .store
        depthPass.depthAttachment.clearDepth = 0.25
        let clear = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: depthPass))
        clear.endEncoding()

        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceColor, index: 0)
        encoder.setTexture(sourceDepth, index: 1)
        encoder.setTexture(targetColor, index: 2)
        encoder.setTexture(capturedY, index: 3)
        encoder.setTexture(capturedCbCr, index: 4)
        encoder.setTexture(semanticLabels, index: 5)
        encoder.setTexture(semanticConfidence, index: 6)
        encoder.setTexture(previousMatte, index: 7)
        encoder.setTexture(nextMatte, index: 8)
        encoder.setTexture(disabledSource, index: 9)
        encoder.setTexture(disabledSource, index: 10)
        encoder.setTexture(disabledSource, index: 11)
        encoder.setBytes(&uniforms, length: MemoryLayout<SemanticOcclusionPass.MatteUniforms>.stride,
                         index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()

        let completed = expectation(description: "semanticMatte GPU completion")
        command.addCompletedHandler { _ in completed.fulfill() }
        command.commit()
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(command.status, .completed)
        guard command.status == .completed else { return [] }

        let wordCount = targetWidth * targetHeight * 4
        var words = [UInt16](repeating: 0, count: wordCount)
        words.withUnsafeMutableBufferPointer { elements in
            targetColor.getBytes(elements.baseAddress!,
                bytesPerRow: targetWidth * 4 * MemoryLayout<UInt16>.stride,
                from: MTLRegionMake2D(0, 0, targetWidth, targetHeight), mipmapLevel: 0)
        }
        return stride(from: 0, to: wordCount, by: 4).map { offset in
            SIMD4(Float(Float16(bitPattern: words[offset])),
                  Float(Float16(bitPattern: words[offset + 1])),
                  Float(Float16(bitPattern: words[offset + 2])),
                  Float(Float16(bitPattern: words[offset + 3])))
        }
    }

    func testRotatedSemanticTreeRestoresOnlyThreeKnownCameraPixels() throws {
        // View (u,v) -> capture (v,1-u): a 90-degree rotation across a 4x6
        // target and 6x4 camera. With 2x3 nearest labels, tree at (0,0)
        // covers precisely target (3,0..2); all other pixels remain red.
        let rotation = simd_float3x3(columns: (
            SIMD3<Float>(0, -1, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 1)
        ))
        let pixels = try render(viewToCapture: rotation, labels: [2, 0, 0, 0, 0, 0])
        XCTAssertEqual(pixels.count, 24)
        guard pixels.count == 24 else { return }
        // Hand-computed camera luma^2.2 for 0.2, 0.4, 0.6. Neutral CbCr
        // makes each restored RGB channel equal to this linear value.
        let expectedGray: [Float] = [0.02899, 0.13321, 0.32504]
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                let pixel = pixels[y * targetWidth + x]
                if x == 3 && y < 3 {
                    for channel in 0..<3 {
                        XCTAssertEqual(pixel[channel], expectedGray[y], accuracy: 0.015,
                                       "restored camera at (\(x),\(y))")
                    }
                } else {
                    XCTAssertEqual(pixel.x, 1, accuracy: 0.005)
                    XCTAssertEqual(pixel.y, 0, accuracy: 0.005)
                    XCTAssertEqual(pixel.z, 0, accuracy: 0.005)
                }
                XCTAssertEqual(pixel.w, 1, accuracy: 0.005)
            }
        }
    }

    func testOutsideCaptureCoverageCannotClampTreeBorderIntoMatte() throws {
        var outside = matrix_identity_float3x3
        outside.columns.2.x = 1.05
        // A tree occupies the rightmost semantic border. An older shader that
        // clamps capture UVs would restore camera pixels; the coverage contract
        // writes the original solid red for every outside-mapped target pixel.
        let pixels = try render(viewToCapture: outside,
                                labels: [0, 2, 0, 2, 0, 2])
        XCTAssertEqual(pixels.count, 24)
        guard pixels.count == 24 else { return }
        for pixel in pixels {
            XCTAssertEqual(pixel.x, 1, accuracy: 0.005)
            XCTAssertEqual(pixel.y, 0, accuracy: 0.005)
            XCTAssertEqual(pixel.z, 0, accuracy: 0.005)
            XCTAssertEqual(pixel.w, 1, accuracy: 0.005)
        }
    }
}
