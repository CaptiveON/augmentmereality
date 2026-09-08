import Foundation

/// Explicit measurement variants. Environment variables alone cannot change the
/// shipping workload; -ARBaselineExperiment is independent of -ARBaselineMetrics
/// so the identical experiment can run with instrumentation on and off.
struct ARBaselineExperiment: Sendable {
    enum Subsystem: String, CaseIterable, Sendable {
        case reconstruction, localization, neuralDepth, personSegmentation
        case sentinel, postprocess, assetPreload
    }

    static let current = ARBaselineExperiment(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    let enabled: Bool
    let disabled: Set<Subsystem>
    let delayedAsset: String?
    let assetDelaySeconds: Double
    let invalidOptions: [String]

    init(arguments: [String], environment: [String: String]) {
        enabled = arguments.contains("-ARBaselineExperiment")
        guard enabled else {
            disabled = []; delayedAsset = nil; assetDelaySeconds = 0; invalidOptions = []
            return
        }
        let names = (environment["AR_BASELINE_DISABLE"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        disabled = Set(names.compactMap(Subsystem.init(rawValue:)))
        var invalid = names.filter { Subsystem(rawValue: $0) == nil }
        let delay = Double(environment["AR_BASELINE_ASSET_DELAY_SECONDS"] ?? "0")
        if delay == nil || !(0...10).contains(delay!) {
            invalid.append("AR_BASELINE_ASSET_DELAY_SECONDS must be 0...10")
        }
        delayedAsset = environment["AR_BASELINE_DELAYED_ASSET"]
        if (delay ?? 0) > 0, delayedAsset?.isEmpty != false {
            invalid.append("AR_BASELINE_DELAYED_ASSET is required for delay")
        }
        assetDelaySeconds = delay.map { $0.isFinite ? min(10, max(0, $0)) : 0 } ?? 0
        invalidOptions = invalid
    }

    func allows(_ subsystem: Subsystem) -> Bool {
        !enabled || !invalidOptions.isEmpty || !disabled.contains(subsystem)
    }

    func delay(for asset: String) -> Double {
        enabled && invalidOptions.isEmpty && asset == delayedAsset ? assetDelaySeconds : 0
    }

    var description: String {
        if !enabled { return "shipping defaults" }
        if !invalidOptions.isEmpty { return "INVALID: \(invalidOptions.joined(separator: "; ")); shipping defaults retained" }
        return "disabled=\(disabled.map(\.rawValue).sorted().joined(separator: ",")); delayedAsset=\(delayedAsset ?? "none"); delaySeconds=\(assetDelaySeconds)"
    }
}
