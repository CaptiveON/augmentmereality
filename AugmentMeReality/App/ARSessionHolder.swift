import Foundation
import RealityKit
import SwiftUI

/// App-level owner of the ARView + placement engine (ADR-013, master plan §5.1).
///
/// Killer #1 demands content on screen at camera frame one. The single biggest cold
/// cost is bringing up the camera, VIO, and VPS *after* the user taps the camera tab —
/// so the session is pre-warmed while intent is forming (map tab, app foreground) and
/// kept alive for a bounded window when the camera tab is left. The window
/// (`AppConfig.prewarmWindowSeconds`) bounds battery use and how long the system
/// camera indicator stays on outside the camera tab.
@MainActor
final class ARSessionHolder: ObservableObject {
    let manager = GeoARSessionManager()

    @Published private(set) var arView: ARView?

    private weak var locationService: LocationService?
    private weak var library: DropLibrary?
    private var pauseTask: Task<Void, Never>?
    private var cameraVisible = false
    private var sessionRunning = false

    /// Idempotent; must run before the first prewarm/activate.
    func configure(locationService: LocationService, library: DropLibrary) {
        if self.locationService == nil {
            self.locationService = locationService
            self.library = library
            // ADR-032/035: warm the model cache without blocking (async loads),
            // and only after the launch window — cold start already pays camera
            // + VIO + VPS bring-up; piling asset decodes on top was part of the
            // 3-minute heat ramp.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                DropEntityFactory.preloadAnimatedAssets()
            }
        }
    }

    /// ADR-043: warm everything that does NOT touch the camera — the ARView
    /// exists (Metal surface allocated), models decode, location/heading stream.
    /// The capture session itself starts only on camera intent, so the green
    /// indicator can never appear while the user is on the map.
    func warmWithoutCamera() {
        guard GeoARSessionManager.isDeviceSupported else { return }
        if arView == nil {
            let trace = ARBaselineMetrics.shared.measure("ARView prepare")
            defer { ARBaselineMetrics.shared.end(trace) }
            arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        }
    }

    /// Explicit camera intent from the Receive flow: the user tapped a drop
    /// link, the invitation is on screen — start the session now so "Reveal in
    /// AR" lands in an already-running camera.
    func beginRevealWarmup(heroID: UUID? = nil) {
        guard GeoARSessionManager.isDeviceSupported else { return }
        manager.markCameraIntent(heroID: heroID)
        startIfNeeded()
        schedulePause()
    }

    func cameraDidAppear() {
        cameraVisible = true
        pauseTask?.cancel()
        // Round 4 (counsel F-D3-02): visibility is marked BEFORE the session
        // (re)starts — resumeSession computes its plan from manager state,
        // and marking after meant the visibility term was false on every
        // reachable resume (a double session.run at the reveal instant).
        manager.markCameraVisible()
        startIfNeeded()
    }

    func cameraDidDisappear() {
        cameraVisible = false
        manager.markCameraHidden()
        schedulePause()
    }

    func appDidEnterBackground() {
        pauseTask?.cancel()
        suspend()
    }

    /// Counsel SWE-1: backgrounding suspends the session, and NOTHING resumed
    /// it — a phone call or two-second app switch left a frozen viewfinder
    /// reading "Paused" until the user manually closed and reopened the camera.
    /// If the camera cover is still up when the scene returns to `.active`,
    /// bring the session back (a warm resume — placements survive, ARP-4).
    /// The manager's own visibility flag must be restored too: suspendSession
    /// cleared it, and a resume without it leaves the power governor pinned
    /// idle — every occluder silently off (counsel Wave B review C10/C16).
    func appDidBecomeActive() {
        guard cameraVisible, !sessionRunning else { return }
        // Round 4 (counsel F-D3-02): visibility BEFORE the restart — same
        // ordering contract as cameraDidAppear.
        manager.markCameraVisible()
        startIfNeeded()
    }

    private var attached = false
    private func startIfNeeded() {
        guard let locationService, let library else { return }
        if arView == nil {
            let trace = ARBaselineMetrics.shared.measure("ARView prepare")
            defer { ARBaselineMetrics.shared.end(trace) }
            arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        }
        if !attached {
            manager.attach(arView: arView!, locationService: locationService, library: library)
            attached = true
            sessionRunning = true
        } else if !sessionRunning {
            manager.resumeSession()
            sessionRunning = true
        }
    }

    private func schedulePause() {
        guard !cameraVisible else { return }
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(AppConfig.pauseGraceSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled, let self, !self.cameraVisible else { return }
            self.suspend()
        }
    }

    private func suspend() {
        guard sessionRunning else { return }
        manager.suspendSession()
        sessionRunning = false
    }
}
