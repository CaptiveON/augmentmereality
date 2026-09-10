import Foundation
import MetricKit
import os

/// Round 5 (counsel RSCH4-02): the crash/hang instrument for BRIEF's 99.5%
/// crash-free bar. The bar is a FLEET ratio — no single-device field run can
/// sign it — so this subscriber is the mechanism that will eventually sign it
/// post-TestFlight, first-party and ~30 lines (no SDK, no new package, no new
/// privacy-manifest surface).
///
/// MXCrashDiagnostic carries the crash signature with a symbolicatable call
/// stack. MXHangDiagnostic is the one on-point for Wave D specifically: a main
/// actor blocked behind `SemanticOcclusionPass.stateLock` during a
/// render-thread encode manifests as a HANG, not a crash — the exact failure
/// shape that `renderFPS`'s 2-second mean smears away (counsel exit ruling).
///
/// Diagnostics arrive on MetricKit's background queue; metrics are aggregated
/// and delivered later, usually daily. Neither is a synchronous baseline-run
/// measurement. Each payload is persisted whole as JSON under
/// Application Support/diagnostics/ so a field session can be debriefed by
/// reading files off the device — no network, no third party.
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = CrashDiagnostics()
    private let log = Logger(
        subsystem: "com.adnan.augmentmereality", category: "diagnostics"
    )

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let directory = Self.diagnosticsDirectory()
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            // The grep key for field debriefs — same subsystem the capture
            // filters on (round 4, RSCH-2 lesson: default-subsystem lines
            // are silently dropped).
            log.error("MetricKit diagnostics: \(crashes) crash(es), \(hangs) hang(s)")
            guard let directory else { continue }
            let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd)
            let url = directory.appendingPathComponent("diagnostic-\(stamp).json")
            try? payload.jsonRepresentation().write(to: url, options: .atomic)
        }
    }

    /// Retain OS aggregates (including available CPU/GPU, memory, animation,
    /// and launch metrics) separately from run-local ARBaselineMetrics reports.
    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let directory = Self.diagnosticsDirectory() else { return }
        for payload in payloads {
            let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd)
            let url = directory.appendingPathComponent("metric-\(stamp).json")
            do {
                try payload.jsonRepresentation().write(to: url, options: .atomic)
                log.log("MetricKit aggregate metrics persisted")
            } catch {
                log.error("MetricKit metrics could not be persisted: \(error.localizedDescription)")
            }
        }
    }

    private static func diagnosticsDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let directory = base.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }
}
