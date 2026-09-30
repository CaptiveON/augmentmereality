import Combine
import Foundation

enum AssetLoadDeadline {
    /// One final resource or a bounded failure. Cancellation propagates to the
    /// upstream publisher; callbacks are serialized on main for scene handoff.
    static func applying<P: Publisher>(to publisher: P, seconds: TimeInterval = 30)
        -> AnyPublisher<P.Output, Error> {
        publisher.mapError { $0 as Error }
            .first()
            .receive(on: DispatchQueue.main)
            .timeout(.seconds(seconds), scheduler: DispatchQueue.main, customError: {
                NSError(domain: "AugmentMeReality.AssetLoad", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The 3D model load timed out"])
            })
            .eraseToAnyPublisher()
    }
}
