import CoreVideo
import Foundation
import os
import Vision

/// ADR-037: cheap person-presence probe. Apple's person-segmentation ML costs
/// 14–29 ms/frame on A17-class chips and community measurements show thermal
/// throttling within ~90 s of continuous use — but it only produces value while
/// a human is actually in frame. This sentinel runs Vision's lightweight
/// human-rectangle detector at ~2 Hz; the expensive segmentation stream is
/// requested from ARKit only while presence is likely. Cost of the trade:
/// someone entering frame is drawn over for up to ~1 s before occlusion engages.
final class PersonSentinel {
    /// Wave D R2 (counsel RENDER-6): `.userInitiated`, not `.utility` — the
    /// closure holds an ARKit capture-pool buffer for the detector's run, and
    /// .utility is the QoS the system throttles hardest under exactly the
    /// thermal pressure that stresses the pool. The `busy` flag bounds the
    /// hold to ONE buffer; the duration is now measured, not asserted.
    private let queue = DispatchQueue(label: "person-sentinel", qos: .userInitiated)
    private let lock = NSLock()
    private var loggedLongHold = false
    private var request: VNDetectHumanRectanglesRequest?
    private var busy = false
    private var lastRunAt = Date.distantPast
    private var lastSeenAt = Date.distantPast

    /// True while a person was detected within the last few seconds.
    var personLikely: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastSeenAt) < 5
    }

    /// Feed camera frames; runs at most every `1/hz` seconds, never overlapping.
    func update(pixelBuffer: CVPixelBuffer, hz: Double = 2) {
        lock.lock()
        guard !busy, Date().timeIntervalSince(lastRunAt) > 1.0 / hz else {
            lock.unlock()
            return
        }
        busy = true
        lastRunAt = Date()
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let holdStart = Date()
            defer {
                // RENDER-6: the "bounded hold" claim is measured. A hold past
                // 100 ms means the pool is under real pressure — log once so
                // field traces can attribute the fps sawtooth correctly.
                let held = Date().timeIntervalSince(holdStart)
                self.lock.lock()
                self.busy = false
                let shouldLog = held > 0.1 && !self.loggedLongHold
                if shouldLog { self.loggedLongHold = true }
                self.lock.unlock()
                if shouldLog {
                    os_log(.error, "PersonSentinel buffer hold exceeded 100 ms (%.0f ms) — capture pool under pressure", held * 1000)
                }
            }
            let request: VNDetectHumanRectanglesRequest
            if let existing = self.request {
                request = existing
            } else {
                request = VNDetectHumanRectanglesRequest()
                request.upperBodyOnly = true
                self.request = request
            }
            // ARKit delivers `capturedImage` in landscape sensor orientation while
            // the app is portrait-locked; Vision's detectors are trained on upright
            // people and default to `.up` when no orientation is given, so without
            // `.right` (rear camera, portrait) the detector sees sideways torsos
            // and the gate almost never opens — which kept `.personSegmentation`
            // out of the session entirely (counsel ARP-2).
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer, orientation: .right
            )
            guard (try? handler.perform([request])) != nil else { return }
            if let results = request.results, !results.isEmpty {
                self.lock.lock()
                self.lastSeenAt = Date()
                self.lock.unlock()
            }
        }
    }
}
