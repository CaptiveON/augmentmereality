import Foundation

/// Granular effects implemented by the AR manager and deterministic test sinks.
@MainActor
protocol PerceptionSubsystemSink: AnyObject {
    func configure(reconstruction: Bool, person: Bool, depth: Bool)
    func setLocalizationAdmission(allowed: Bool, generation: UInt64)
    func setSemanticsRequested(_ requested: Bool) -> Bool
    var localizationCanUpdate: Bool { get }
    func setSentinelAdmission(allowed: Bool, generation: UInt64)
    func setDepthAdmission(allowed: Bool, generation: UInt64)
    func setPassAdmission(allowed: Bool, generation: UInt64, person: Bool, depth: Bool)
    func setSemanticConsumerEnabled(_ enabled: Bool)
    func setCallbacksActive(_ active: Bool)
}

/// Applies one demand plan to all producers and consumers. The injected clock
/// drives the existing callback idle/minimum-attachment dwell. Lifecycle and
/// thermal hard stops close that work immediately.
@MainActor
final class PerceptionCoordinator: PerceptionSubsystemAdapter {
    private weak var sink: (any PerceptionSubsystemSink)?
    private let now: () -> Date
    private var callbacksAttachedAt: Date?
    private var callbacksIdleSince: Date?
    private(set) var generation: UInt64 = 0
    private(set) var currentPlan = PerceptionPolicy.Plan()
    private(set) var semanticConsumerEnabled = false
    private(set) var localizationAdmitted = false
    private(set) var callbacksActive = false

    init(sink: any PerceptionSubsystemSink, now: @escaping () -> Date = Date.init) {
        self.sink = sink
        self.now = now
    }

    func applyPerceptionPlan(_ plan: PerceptionPolicy.Plan) {
        currentPlan = plan
        guard let sink else { return }
        let time = now()
        // Close use before reconfiguring producers. Even if ARCore refuses a
        // disable, an unusable matte cannot consume its retained inference.
        if !plan.semantics {
            semanticConsumerEnabled = false
            sink.setSemanticConsumerEnabled(false)
        }
        sink.setPassAdmission(allowed: !plan.hardShutdown, generation: generation,
                              person: plan.customPersonUse, depth: plan.midField)
        sink.setSentinelAdmission(allowed: plan.sentinel, generation: generation)
        sink.setDepthAdmission(allowed: plan.midField, generation: generation)
        // ARCore semantic enabling requires localization admission first.
        // Disabling can be retried while localization remains fully suspended.
        if plan.semantics {
            sink.setLocalizationAdmission(allowed: plan.localization, generation: generation)
        }
        let actualSemantics = sink.setSemanticsRequested(plan.semantics)
        let localizationAllowed = plan.localization && (plan.semantics || !actualSemantics)
        if !plan.semantics || !localizationAllowed {
            sink.setLocalizationAdmission(allowed: localizationAllowed, generation: generation)
        }
        localizationAdmitted = localizationAllowed && sink.localizationCanUpdate
        semanticConsumerEnabled = plan.semantics && actualSemantics && localizationAdmitted
        sink.setSemanticConsumerEnabled(semanticConsumerEnabled)
        sink.configure(reconstruction: plan.reconstruction, person: plan.person, depth: plan.depth)

        // Requested semantics alone cannot attach an empty pass after an
        // unsupported/rejected ARCore enable. Built-in person occlusion also
        // needs no custom postprocess callback.
        let passNeeded = plan.customPersonUse || plan.midField || semanticConsumerEnabled
        if plan.hardShutdown {
            setCallbacks(false, sink: sink, at: time)
            callbacksIdleSince = nil
        } else if passNeeded {
            callbacksIdleSince = nil
            setCallbacks(true, sink: sink, at: time)
        } else if callbacksActive {
            if callbacksIdleSince == nil { callbacksIdleSince = time }
            if let idleSince = callbacksIdleSince, let attachedAt = callbacksAttachedAt,
               Self.callbacksShouldDetach(idleFor: time.timeIntervalSince(idleSince),
                                          attachedFor: time.timeIntervalSince(attachedAt)) {
                setCallbacks(false, sink: sink, at: time)
            }
        }
    }

    /// Retires asynchronous results before pause/reset/resume. Reconstruction
    /// configuration is untouched here so a short hide can retain its mesh.
    func invalidate() {
        generation &+= 1
        currentPlan = PerceptionPolicy.Plan()
        semanticConsumerEnabled = false
        localizationAdmitted = false
        callbacksActive = false
        callbacksIdleSince = nil
        callbacksAttachedAt = nil
        guard let sink else { return }
        sink.setSemanticConsumerEnabled(false)
        sink.setPassAdmission(allowed: false, generation: generation, person: false, depth: false)
        sink.setCallbacksActive(false)
        sink.setSentinelAdmission(allowed: false, generation: generation)
        sink.setDepthAdmission(allowed: false, generation: generation)
        sink.setLocalizationAdmission(allowed: false, generation: generation)
        _ = sink.setSemanticsRequested(false)
    }

    nonisolated static func callbacksShouldDetach(idleFor: TimeInterval, attachedFor: TimeInterval) -> Bool {
        idleFor > 5 && attachedFor > 10
    }

    private func setCallbacks(_ active: Bool, sink: any PerceptionSubsystemSink, at time: Date) {
        guard active != callbacksActive else { return }
        callbacksActive = active
        callbacksAttachedAt = active ? time : nil
        sink.setCallbacksActive(active)
    }
}
