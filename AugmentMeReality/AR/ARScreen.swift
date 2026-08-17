import ARKit
import CoreLocation
import RealityKit
import SwiftUI

/// The camera surface. The ARView itself is owned by `ARSessionHolder` (ADR-013) so
/// it can be pre-warmed from the map tab and survive tab switches — this screen just
/// hosts it and draws the HUD.
struct ARScreen: View {
    /// True while this tab is selected.
    let isActive: Bool

    @EnvironmentObject private var holder: ARSessionHolder
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var reactionSession: ReactionSession

    var body: some View {
        ARScreenContent(
            isActive: isActive,
            holder: holder,
            manager: holder.manager,
            locationService: locationService
        )
        // Wave 6.2: watching a received drop → reaction chrome over the camera,
        // and the wrap ends by capturing the Memory snapshot.
        .overlay {
            if isActive, reactionSession.drop != nil {
                ReactionOverlay()
            }
        }
        .onChange(of: reactionSession.phase) { _, phase in
            if phase == .memory, reactionSession.memorySnapshot == nil {
                holder.arView?.snapshot(saveToHDR: false) { image in
                    reactionSession.memorySnapshot = image
                }
            }
        }
    }
}

private struct ARScreenContent: View {
    let isActive: Bool
    let holder: ARSessionHolder
    @ObservedObject var manager: GeoARSessionManager
    @ObservedObject var locationService: LocationService
    @EnvironmentObject private var reactionSession: ReactionSession
    @EnvironmentObject private var router: AppRouter
    private var watching: Bool { reactionSession.drop != nil }

    @AppStorage("vpsDisclosureShown") private var vpsDisclosureShown = false
    @State private var showVPSDisclosure = false
    /// Tap the camera anywhere → clean view (no HUD); tap again → HUD returns.
    @State private var hudHidden = false
    /// ADR-041: next camera tap re-homes the nearest drop to the tapped point.
    @State private var pinningToSpot = false
    /// ADR-043 reveal: masks camera+VIO bring-up as a designed moment. Dismissed
    /// by real readiness (first frame) or the hard cap — never an empty viewfinder.
    @State private var revealing = false
    @State private var revealStartedAt = Date.distantPast
    // Local slider values for the live adjust panel; synced per nearest drop.
    @State private var liveHeight = 3.0
    @State private var liveScale = 3.0
    @State private var liveRotation = 0.0
    /// Brief white flash confirming a clean screenshot was captured.
    @State private var shutterFlash = false

    var body: some View {
        content
            .onAppear {
                if AppConfig.vpsEnabled, !vpsDisclosureShown {
                    showVPSDisclosure = true
                }
                if isActive {
                    holder.cameraDidAppear()
                    // ADR-048: presented as a cover — reveal on appear too.
                    if !manager.sessionFrameReady {
                        revealing = true
                        revealStartedAt = Date()
                    }
                }
            }
            .onDisappear {
                holder.cameraDidDisappear()
            }
            .onChange(of: isActive) { _, active in
                if active {
                    holder.cameraDidAppear()
                } else {
                    holder.cameraDidDisappear()
                }
            }
            .alert("Precise positioning", isPresented: $showVPSDisclosure) {
                Button("Continue") { vpsDisclosureShown = true }
            } message: {
                Text("To pin content with street-level precision, visual data from this camera session is processed by Google's Visual Positioning Service.")
            }
    }

    private var content: some View {
        ZStack {
            if !GeoARSessionManager.isDeviceSupported {
                ContentUnavailableView(
                    "AR needs a real iPhone",
                    systemImage: "camera.metering.unknown",
                    description: Text("World tracking isn't available here (e.g. in the Simulator). The Map and My Drops tabs still work.")
                )
            } else if isActive, let arView = holder.arView {
                HostedARView(arView: arView)
                    .ignoresSafeArea()
                    .onTapGesture(coordinateSpace: .global) { location in
                        if pinningToSpot {
                            handlePinTap(at: location, in: arView)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                hudHidden.toggle()
                            }
                        }
                    }

                if pinningToSpot {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "scope")
                            Text("TAP THE EXACT SPOT FOR “\(manager.nearestDrop?.title.prefix(14) ?? "")”")
                                .font(Night.mono(10)).kerning(0.8)
                            Button {
                                pinningToSpot = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Night.ink)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Night.bgBase.opacity(0.88), in: Capsule())
                        .overlay(Capsule().strokeBorder(Night.gold.opacity(0.5)))
                        .padding(.top, 64)
                        Spacer()
                    }
                    .transition(.opacity)
                }

                if !hudHidden {
                    hudOverlay
                        .transition(.opacity)
                }

                // ADR-048: the camera is a presented moment — always escapable.
                VStack {
                    HStack {
                        Button {
                            if router.onboardingPhase == .fireworksDemo {
                                router.endFireworksDemo()
                            } else {
                                router.showCamera = false
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Night.ink)
                                .frame(width: 36, height: 36)
                                .background(Night.bgBase.opacity(0.7), in: Circle())
                                .overlay(Circle().strokeBorder(Night.lineSubtle))
                        }
                        .padding(.leading, 14)
                        Spacer()
                    }
                    .padding(.top, 4)
                    Spacer()
                }

                // Onboarding beat 2: the magic moment, then back to the story.
                if router.onboardingPhase == .fireworksDemo {
                    VStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Text("✨ Real fireworks. Your floor.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Night.ink)
                            NightCTA(title: "Magical — continue") {
                                router.endFireworksDemo()
                            }
                        }
                        .padding(16)
                        .background(Night.bgBase.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Night.gold.opacity(0.4)))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 30)
                    }
                    .transition(.opacity)
                }

                if shutterFlash {
                    Color.white.ignoresSafeArea()
                }

                if revealing {
                    revealOverlay
                        .transition(.opacity)
                }
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onChange(of: isActive) { _, active in
            if active, !manager.sessionFrameReady {
                revealing = true
                revealStartedAt = Date()
            }
        }
        .onChange(of: manager.sessionFrameReady) { _, ready in
            if ready { endRevealSoon() }
        }
        .task(id: revealing) {
            guard revealing else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(AppConfig.revealMaxSeconds * 1_000_000_000)
            )
            withAnimation(.easeOut(duration: 0.35)) { revealing = false }
        }
    }

    /// Hold the overlay just long enough to feel intentional (≥0.45 s), then fade.
    private func endRevealSoon() {
        let minimum: TimeInterval = 0.45
        let elapsed = Date().timeIntervalSince(revealStartedAt)
        Task {
            if elapsed < minimum {
                try? await Task.sleep(nanoseconds: UInt64((minimum - elapsed) * 1_000_000_000))
            }
            withAnimation(.easeOut(duration: 0.35)) { revealing = false }
        }
    }

    /// The viewfinder-opening moment (Night language, Figma-consistent).
    private var revealOverlay: some View {
        ZStack {
            Night.bgScreen.ignoresSafeArea()
            RadialGradient(
                colors: [Night.coral.opacity(0.12), .clear],
                center: .center, startRadius: 10, endRadius: 300
            )
            .ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [Night.gold, Night.coral, Night.gold], center: .center
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Night.gold, Night.coral], center: .topLeading,
                                startRadius: 2, endRadius: 40
                            )
                        )
                        .frame(width: 18, height: 18)
                        .shadow(color: Night.coral.opacity(0.9), radius: 14)
                }
                Text("Opening the viewfinder")
                    .font(Night.display(19))
                    .foregroundStyle(Night.ink)
                Text(manager.renderedDropCount > 0
                     ? "\(manager.renderedDropCount) drop\(manager.renderedDropCount == 1 ? "" : "s") nearby"
                     : "Finding what's around you…")
                    .font(Night.mono(11))
                    .kerning(1)
                    .foregroundStyle(Night.inkTertiary)
            }
        }
    }

    private var hudOverlay: some View {
        VStack(spacing: 0) {
            statusCard
                .padding(.top, 4)

            Spacer()

            let demoing = router.onboardingPhase == .fireworksDemo
            if manager.nearestDrop != nil, manager.renderedDropCount > 0, !demoing {
                adjustPanel
                    .padding(.bottom, 8)
            }

            if let drop = manager.nearestDrop,
               let distance = manager.nearestDropDistance,
               let viewer = locationService.location, !demoing {
                guidanceCard(drop: drop, distance: distance, viewer: viewer)
                    .padding(.bottom, 10)
            }

            if !watching && !demoing {
            HStack(spacing: 10) {
                // ADR-025: indoor-friendly — AR-space anchored, no GPS needed.
                // (Hidden while watching a received drop — the reaction bar owns
                // the bottom edge then.)
                Menu {
                    Button {
                        manager.placeRoomDrop(content: .text3D)
                    } label: {
                        Label("3D text", systemImage: "textformat")
                    }
                    ForEach(DropEntityFactory.bundledAnimatedAssets, id: \.self) { name in
                        Button {
                            manager.placeRoomDrop(content: .animated, assetName: name)
                        } label: {
                            Label(name, systemImage: "cube.transparent")
                        }
                    }
                    if manager.hasRoomDrops {
                        Button(role: .destructive) {
                            manager.clearRoomDrops()
                        } label: {
                            Label("Clear room drops", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Playground", systemImage: "house")
                        .font(.footnote.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)

                Button {
                    manager.placeDemoDrop()
                } label: {
                    Label(
                        locationService.location == nil
                            ? "Demo needs GPS…"
                            : "Demo: 15 m ahead",
                        systemImage: "wand.and.stars"
                    )
                    .font(.footnote.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(locationService.location == nil)

                // Clean capture: camera + content only, HUD never included.
                Button {
                    takeScreenshot()
                } label: {
                    Image(systemName: "camera.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
            }
            .padding(.bottom, 14)
            }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(manager.mode.badge)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        manager.mode == .geoTracking ? Color.green : Color.orange,
                        in: Capsule()
                    )
                Text("\(manager.renderedDropCount) in view range")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                if manager.occlusionActive {
                    chip("LiDAR", color: .blue)
                }
                if let vps = manager.vpsStatusText {
                    chip(vps, color: manager.vpsLocked ? .green : .orange)
                }
                if manager.semanticMatteArmed {
                    chip("SEM", color: .purple)
                }
                if manager.midDepthActive {
                    chip("DPT", color: .teal)
                }
                if manager.powerTier == .cruise {
                    chip("ECO", color: .gray)
                } else if manager.powerTier == .idle {
                    chip("IDLE", color: .gray)
                }
                if manager.windowModeActive {
                    chip("GLASS", color: .cyan)
                }
                if manager.renderPath == .transit {
                    chip("TRANSIT", color: .indigo)
                } else if manager.motionState == .vehicular {
                    chip("VEHICLE", color: .gray)
                }
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Text(manager.statusText)
                .font(.footnote)
                .multilineTextAlignment(.center)

            // Wave C round 2 (C20): persist/asset failures are visible IN AR.
            if let error = manager.persistErrorText {
                Text(error)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // ADR-020: viewer-side lighting mode. Natural = scene-lit PBR (real
            // shading from surrounding light); Bright = emissive glow for night.
            Button {
                manager.setContentFullBright(!manager.contentFullBright)
            } label: {
                Label(
                    manager.contentFullBright ? "Bright — tap for natural light" : "Natural light — tap for bright",
                    systemImage: manager.contentFullBright ? "sun.max.fill" : "cloud.sun"
                )
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    manager.contentFullBright ? Color.yellow.opacity(0.75) : Color.white.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(manager.contentFullBright ? .black : .white)
            }

            if manager.mode == .gpsCompass, needsCompassCalibration {
                Label("Wave the phone in a figure-8 to calibrate the compass",
                      systemImage: "gyroscope")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }

            if let diagnostics = manager.renderDiagnostics {
                Text(diagnostics)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.cyan)
            }

            if let ttfo = manager.timeToFirstObjectMs {
                Text(metricsLine(ttfo: ttfo))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ttfo <= 400 ? .mint : .yellow)
            }

            if let correction = manager.vpsCorrectionCm, correction > 0 {
                Text("vps corrections Σ \(correction) cm")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }

            if manager.thermalSerious {
                Label("Device is hot — AR quality may degrade", systemImage: "thermometer.high")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
    }

    /// Live controls for the nearest drop: slide height to sit it on the real
    /// ground, slide size while looking at it. Dragging moves the object every
    /// tick; releasing persists and (if VPS owns it) re-pins the terrain anchor.
    private var adjustPanel: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.and.down")
                    .frame(width: 20)
                Slider(
                    value: Binding(
                        get: { liveHeight },
                        set: { value in
                            liveHeight = value
                            manager.adjustNearestDrop(height: value, commit: false)
                        }
                    ),
                    in: -2...20
                ) { editing in
                    if !editing {
                        manager.adjustNearestDrop(height: liveHeight, commit: true)
                    }
                }
                Text(String(format: "%+.1f m", liveHeight))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 20)
                Slider(
                    value: Binding(
                        get: { liveScale },
                        set: { value in
                            liveScale = value
                            manager.adjustNearestDrop(scale: value, commit: false)
                        }
                    ),
                    in: 0.5...50
                ) { editing in
                    if !editing {
                        manager.adjustNearestDrop(scale: liveScale, commit: true)
                    }
                }
                Text(String(format: "×%.1f", liveScale))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Image(systemName: "rotate.right")
                    .frame(width: 20)
                Slider(
                    value: Binding(
                        get: { liveRotation },
                        set: { value in
                            liveRotation = value
                            manager.adjustNearestDrop(rotation: value, commit: false)
                        }
                    ),
                    in: 0...360
                ) { editing in
                    if !editing {
                        manager.adjustNearestDrop(rotation: liveRotation, commit: true)
                    }
                }
                Text(String(format: "%.0f°", liveRotation))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            // Raycasts the real surface under the drop (LiDAR/planes) — the
            // slider's 0 uses the coarse ground *estimate*, which can hover.
            HStack(spacing: 8) {
                Button {
                    manager.snapNearestDropToGround()
                    syncSliders()
                } label: {
                    Label("Place on ground", systemImage: "arrow.down.to.line")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.15), in: Capsule())
                }
                // ADR-041: tap the real spot in view → drop re-homes there
                // (VPS-grade coordinates when localized).
                Button {
                    pinningToSpot = true
                } label: {
                    Label("Pin to a spot", systemImage: "scope")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Night.gold.opacity(0.25), in: Capsule())
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .tint(.mint)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
        .onAppear { syncSliders() }
        .onChange(of: manager.nearestDrop?.id) { _, _ in syncSliders() }
    }

    private func syncSliders() {
        guard let drop = manager.nearestDrop else { return }
        liveHeight = drop.heightAboveGround
        liveScale = drop.scale
        liveRotation = manager.nearestDropFacingDegrees()
    }

    /// ADR-041: raycast the tapped pixel to a real surface and re-home the drop.
    private func handlePinTap(at location: CGPoint, in arView: ARView) {
        let results = arView.raycast(
            from: location, allowing: .estimatedPlane, alignment: .any
        )
        guard let hit = results.first else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let t = hit.worldTransform.columns.3
        manager.relocateNearestDrop(to: SIMD3(t.x, t.y, t.z))
        syncSliders()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { pinningToSpot = false }
    }

    /// Clean screenshot: `ARView.snapshot` renders only the camera + content —
    /// the SwiftUI HUD is a separate layer and never appears in it.
    private func takeScreenshot() {
        holder.arView?.snapshot(saveToHDR: false) { image in
            guard let image else { return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        shutterFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.25)) {
                shutterFlash = false
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.7), in: Capsule())
    }

    private func metricsLine(ttfo: Int) -> String {
        var parts = ["first object: \(ttfo) ms"]
        if let fps = manager.renderFPS { parts.append("\(fps) fps") }
        if let p95 = manager.frameP95Ms { parts.append("p95 \(p95) ms") }
        parts.append(manager.videoFormatDescription) // ADR-034 heat evidence
        return parts.joined(separator: " · ")
    }

    private var needsCompassCalibration: Bool {
        guard let accuracy = locationService.headingAccuracy else { return false }
        return accuracy < 0 || accuracy > 25
    }

    private func guidanceCard(drop: GeoDrop, distance: Double, viewer: CLLocation) -> some View {
        let bearing = GeoMath.bearing(from: viewer.coordinate, to: drop.coordinate)
        let heading = locationService.headingDegrees ?? 0
        // Signed relative angle in −180…180: negative = drop is to your left.
        let raw = (bearing - heading) * .pi / 180
        let relativeAngle = atan2(sin(raw), cos(raw)) * 180 / .pi

        let directionText: String
        if abs(relativeAngle) <= 30 {
            directionText = "straight ahead"
        } else if abs(relativeAngle) >= 150 {
            directionText = "behind you — turn around"
        } else if relativeAngle > 0 {
            directionText = "turn right →"
        } else {
            directionText = "← turn left"
        }

        return HStack(spacing: 12) {
            Image(systemName: "location.north.fill")
                .font(.title2)
                .foregroundStyle(abs(relativeAngle) <= 30 ? .green : .yellow)
                .rotationEffect(.degrees(relativeAngle))

            VStack(alignment: .leading, spacing: 2) {
                Text(drop.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(GeoMath.distanceLabel(distance)) · \(directionText)")
                    .font(.caption.bold())
                    .foregroundStyle(abs(relativeAngle) <= 30 ? .green : .yellow)
                Text("by \(drop.createdBy)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

/// Hosts the holder-owned ARView; lifecycle belongs to ARSessionHolder, not SwiftUI.
private struct HostedARView: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
