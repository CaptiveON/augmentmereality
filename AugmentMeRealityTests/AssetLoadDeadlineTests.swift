import Combine
import XCTest
@testable import AugmentMeReality

final class AssetLoadDeadlineTests: XCTestCase {
    @MainActor
    func testStalledDecoderFailsAndCancelsUpstream() async {
        let finished = expectation(description: "bounded decode failure")
        let cancelled = expectation(description: "upstream cancelled")
        let stalled = PassthroughSubject<String, Error>()
        let subscription = AssetLoadDeadline.applying(
            to: stalled.handleEvents(receiveCancel: { cancelled.fulfill() }), seconds: 0.03
        ).sink(receiveCompletion: { result in
            guard case .failure(let error) = result else {
                XCTFail("A silent decoder must fail visibly"); return
            }
            XCTAssertEqual((error as NSError).domain, "AugmentMeReality.AssetLoad")
            finished.fulfill()
        }, receiveValue: { _ in XCTFail("A stalled decoder has no template") })
        await fulfillment(of: [finished, cancelled], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testFirstDecodedResourceCompletesEvenIfPublisherDoesNotFinish() async {
        let finished = expectation(description: "resource delivered")
        let upstream = PassthroughSubject<String, Error>()
        var values: [String] = []
        let subscription = AssetLoadDeadline.applying(to: upstream, seconds: 1)
            .sink(receiveCompletion: { result in
                if case .failure = result { XCTFail("A valid resource must succeed") }
                finished.fulfill()
            }, receiveValue: { values.append($0) })
        upstream.send("template")
        upstream.send("unexpected duplicate")
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(values, ["template"])
        withExtendedLifetime(subscription) {}
    }
}
