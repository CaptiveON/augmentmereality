import RealityKit
import XCTest

@testable import AugmentMeReality

/// ADR-047: the launch hang recurred — so main-thread health during asset
/// decode is now MEASURED on device, not assumed. A 10 ms main-actor ticker
/// runs while the heaviest bundled asset decodes; any long gap means the
/// loader is doing main-thread work and the fix is insufficient.
final class AssetLoadStallTests: XCTestCase {

    @MainActor
    private final class GapMeter {
        var maxGapMs: Double = 0
        func record(_ gap: TimeInterval) { maxGapMs = max(maxGapMs, gap * 1000) }
    }

    @MainActor
    func testHeaviestAssetDecodeDoesNotStallMainActor() async throws {
        let assets = DropEntityFactory.bundledAnimatedAssets
        try XCTSkipUnless(!assets.isEmpty, "no bundled assets")
        // Pick the biggest file — the worst case is the test.
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

        let template = await DropEntityFactory.decodeTemplate(heaviest)
        ticker.cancel()
        XCTAssertNotNil(template, "decode failed for \(heaviest)")

        // Bar: no main-actor gap above 250 ms during decode (a stall a user
        // would feel as a hang is far larger; healthy is <50 ms).
        XCTAssertLessThan(
            meter.maxGapMs, 250,
            "main actor stalled \(Int(meter.maxGapMs)) ms decoding \(heaviest)"
        )

        // Placement path: clone cost on main (this is what a tap pays).
        let start = Date()
        let clone = template!.clone(recursive: true)
        let cloneMs = Date().timeIntervalSince(start) * 1000
        _ = clone
        XCTAssertLessThan(
            cloneMs, 800,
            "clone of \(heaviest) took \(Int(cloneMs)) ms on main — needs pooling"
        )
    }
}
