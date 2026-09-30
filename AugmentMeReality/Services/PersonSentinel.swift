import CoreVideo
import Foundation
import os
import os.lock
import Vision

/// ADR-037: cheap person-presence probe. Apple's person-segmentation ML costs
/// 14–29 ms/frame on A17-class chips and community measurements show thermal
/// throttling within ~90 s of continuous use — but it only produces value while
/// a human is actually in frame. This sentinel runs Vision's lightweight
/// human-rectangle detector at ~2 Hz; the expensive segmentation stream is
/// requested from ARKit only while presence is likely. Cost of the trade:
/// someone entering frame is drawn over for up to ~1 s before occlusion engages.
final class PersonSentinel: Sendable {
    /// Wave D R2 (counsel RENDER-6): `.userInitiated`, not `.utility` — the
    /// closure holds an ARKit capture-pool buffer for the detector's run, and
    /// .utility is the QoS the system throttles hardest under exactly the
    /// thermal pressure that stresses the pool. The `busy` flag bounds the
    /// hold to ONE buffer; the duration is now measured, not asserted.
    private let queue = DispatchQueue(label: "person-sentinel", qos: .userInitiated)
    private struct State: @unchecked Sendable {
        var lastLongHoldLogAt = Date.distantPast
        var busy = false
        var lastRunAt = Date.distantPast
        var lastSeenAt = Date.distantPast
        var workAdmission = PerceptionWorkAdmission()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Round 4 (counsel RSCH-2): the app subsystem — the field capture
    /// filters on it, and the default-subsystem os_log line was silently
    /// dropped by that filter (an empty grep read as "no pressure").
    private let log = Logger(subsystem: "com.adnan.augmentmereality", category: "sentinel")
    /// The Vision request is reused only on the serial detector queue.
    private let worker = WorkerResources()

    private final class WorkerResources: @unchecked Sendable {
        var request: VNDetectHumanRectanglesRequest?
    }

    /// An immutable, single-job transfer of one ARKit capture buffer. Only the
    /// detector queue reads it; the buffer releases when that job exits.
    private final class CaptureBuffer: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
    }

    /// The manager closes admission before a lifecycle edge or policy shed.
    /// Existing Vision work may finish, but can no longer publish presence.
    func setWorkAdmission(_ allowed: Bool, generation: UInt64) {
        state.withLock { state in
            if state.workAdmission.setAllowed(allowed, generation: generation) {
                state.lastSeenAt = .distantPast
                state.lastRunAt = .distantPast
            }
        }
    }

    /// True while a person was detected within the last few seconds.
    var personLikely: Bool {
        state.withLock { state in
            state.workAdmission.allowed && Date().timeIntervalSince(state.lastSeenAt) < 5
        }
    }

    /// Feed camera frames; runs at most every `1/hz` seconds, never overlapping.
    func update(pixelBuffer: CVPixelBuffer, hz: Double = 2) {
        let token = state.withLock { state -> PerceptionWorkAdmission.Token? in
            guard let token = state.workAdmission.token, hz > 0,
                  !state.busy, Date().timeIntervalSince(state.lastRunAt) > 1.0 / hz else {
                return nil
            }
            state.busy = true
            state.lastRunAt = Date()
            return token
        }
        guard let token else { return }

        // Round 3 (counsel RENDER-LENS-2): the clock starts at the CALL SITE
        // — the buffer is retained from the enqueue, so the queue wait is
        // part of the hold, and under thermal pressure the wait IS the
        // failure mode the measurement exists to catch.
        let holdStart = Date()
        let holdTrace = ARBaselineMetrics.shared.measure("Person sentinel buffer hold")
        let capture = CaptureBuffer(pixelBuffer)
        queue.async { [weak self] in
            defer { ARBaselineMetrics.shared.end(holdTrace) }
            defer { withExtendedLifetime(capture) {} }
            guard let self else { return }
            defer {
                // RENDER-6: the "bounded hold" claim is measured, throttled
                // to once a minute — never latched off after one line (a
                // sustained sawtooth must keep reporting).
                let held = Date().timeIntervalSince(holdStart)
                let shouldLog = self.state.withLock { state in
                    state.busy = false
                    let shouldLog = held > 0.1
                        && Date().timeIntervalSince(state.lastLongHoldLogAt) > 60
                    if shouldLog { state.lastLongHoldLogAt = Date() }
                    return shouldLog
                }
                if shouldLog {
                    self.log.error("PersonSentinel buffer hold exceeded 100 ms (\(Int(held * 1000)) ms incl. queue wait) — capture pool under pressure")
                }
            }
            let admitted = self.state.withLock { $0.workAdmission.accepts(token) }
            guard admitted else { return }
            let request: VNDetectHumanRectanglesRequest
            if let existing = self.worker.request {
                request = existing
            } else {
                request = VNDetectHumanRectanglesRequest()
                request.upperBodyOnly = true
                self.worker.request = request
            }
            // ARKit delivers `capturedImage` in landscape sensor orientation while
            // the app is portrait-locked; Vision's detectors are trained on upright
            // people and default to `.up` when no orientation is given, so without
            // `.right` (rear camera, portrait) the detector sees sideways torsos
            // and the gate almost never opens — which kept `.personSegmentation`
            // out of the session entirely (counsel ARP-2).
            let handler = VNImageRequestHandler(
                cvPixelBuffer: capture.pixelBuffer, orientation: .right
            )
            let metrics = ARBaselineMetrics.shared
            let inferenceSucceeded: Bool = {
                let trace = metrics.measure("Person sentinel inference")
                defer { metrics.end(trace) }
                metrics.observe("Person sentinel inference")
                do {
                    try handler.perform([request])
                    return true
                } catch {
                    metrics.event("Person sentinel inference failed")
                    return false
                }
            }()
            guard inferenceSucceeded else { return }
            if let results = request.results, !results.isEmpty {
                self.state.withLock { state in
                    if state.workAdmission.accepts(token) {
                        state.lastSeenAt = Date()
                    }
                }
            }
        }
    }
}
