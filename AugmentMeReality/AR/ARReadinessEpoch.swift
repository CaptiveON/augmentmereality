import Foundation

/// Observations, not proof of display presentation. All times share ARFrame's
/// monotonic uptime clock. A selected hero stays fixed for the entire epoch.
struct ARReadinessEpoch {
    enum Kind: String { case coldStart, warmResume, recovery }

    let kind: Kind
    let generation: Int
    let startedAt: TimeInterval
    private(set) var heroID: UUID?
    private(set) var firstFreshFrameAt: TimeInterval?
    private(set) var placeholderAt: TimeInterval?
    private(set) var assetReadyAt: TimeInterval?
    private(set) var heroSceneUpdateProxyAt: TimeInterval?

    mutating func selectHero(_ id: UUID) {
        if heroID == nil { heroID = id }
    }

    mutating func observeCamera(capturedAt: TimeInterval, observedAt: TimeInterval,
                               sessionRunAt: TimeInterval) {
        guard firstFreshFrameAt == nil, capturedAt.isFinite, observedAt.isFinite,
              capturedAt > max(startedAt, sessionRunAt), observedAt >= capturedAt else { return }
        firstFreshFrameAt = observedAt
    }

    mutating func observeContent(id: UUID, ready: Bool, at: TimeInterval) {
        guard id == heroID, at.isFinite, at >= startedAt else { return }
        if ready {
            if assetReadyAt == nil { assetReadyAt = at }
        } else if placeholderAt == nil {
            placeholderAt = at
        }
    }

    mutating func observeSceneUpdate(id: UUID, contentReady: Bool, inViewport: Bool,
                                    freshCamera: Bool, at: TimeInterval) {
        guard heroSceneUpdateProxyAt == nil, id == heroID, contentReady, inViewport,
              freshCamera, let frameAt = firstFreshFrameAt, let readyAt = assetReadyAt,
              at.isFinite, at > max(frameAt, readyAt) else { return }
        heroSceneUpdateProxyAt = at
    }

    func milliseconds(to timestamp: TimeInterval?) -> Int? {
        timestamp.map { Int((($0 - startedAt) * 1000).rounded()) }
    }
}
