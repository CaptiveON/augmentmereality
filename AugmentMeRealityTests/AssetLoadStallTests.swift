import RealityKit
import XCTest

@testable import AugmentMeReality

/// ADR-047/054: decode and clone must work on every test destination. The
/// 250 ms main-actor gap and 800 ms clone budgets apply to physical devices.
/// Simulator timings are diagnostics: ticker gaps also include host scheduling
/// delays and do not establish device performance or the decoder's thread.
final class AssetLoadStallTests: XCTestCase {

    @MainActor
    private final class GapMeter {
        var maxGapMs: Double = 0
        func record(_ gap: TimeInterval) { maxGapMs = max(maxGapMs, gap * 1000) }
    }

    @MainActor
    func testHeaviestAssetDecodesAndClonesWithPhysicalDeviceTimingBudgets() async throws {
        let assets = DropEntityFactory.bundledAnimatedAssets
        try XCTSkipUnless(!assets.isEmpty, "no bundled assets")
        // Retain ADR-047's largest-file fixture selection.
        let heaviest = assets.max { a, b in
            (Bundle.main.url(forResource: a, withExtension: "usdz")
                .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0)
            < (Bundle.main.url(forResource: b, withExtension: "usdz")
                .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0)
        }!

        let meter = GapMeter()
        let ticker = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
                let now = Date()
                meter.record(now.timeIntervalSince(last) - 0.01)
                last = now
            }
        }

        let decoded = await DropEntityFactory.decodeTemplate(heaviest)
        ticker.cancel()
        let template = try XCTUnwrap(decoded, "decode failed for \(heaviest)")

        // Placement path: clone cost on main (this is what a tap pays).
        let start = Date()
        let clone = template.clone(recursive: true)
        let cloneMs = Date().timeIntervalSince(start) * 1000
        XCTAssertFalse(clone === template, "clone must produce a distinct entity")

        #if targetEnvironment(simulator)
        let mode = "simulator diagnostics; physical timing budgets not evaluated"
        #else
        let mode = "physical device; timing budgets enforced"
        #endif
        let measurements = """
        asset=\(heaviest)
        mode=\(mode)
        maximumMainActorSchedulingGapMs=\(String(format: "%.3f", meter.maxGapMs))
        cloneMs=\(String(format: "%.3f", cloneMs))
        """
        let attachment = XCTAttachment(string: measurements)
        attachment.name = "Asset decode and clone timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("AssetLoadStallTests: \(measurements)")

        #if !targetEnvironment(simulator)
        // Keep ADR-047's device budgets unchanged; hosted simulator timings
        // cannot substitute for this physical-device release gate.
        XCTAssertLessThan(
            meter.maxGapMs, 250,
            "main actor stalled \(Int(meter.maxGapMs)) ms decoding \(heaviest)"
        )
        XCTAssertLessThan(
            cloneMs, 800,
            "clone of \(heaviest) took \(Int(cloneMs)) ms on main — needs pooling"
        )
        #endif
    }
}
