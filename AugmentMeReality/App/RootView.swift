import SwiftUI

/// UI revamp (ADR-048) — "The Gift, not the Map".
/// Tabs: Home · Explore · [orb +] · Sent · You. The camera is a presented
/// moment (fullScreenCover), not a tab. The Wave-6.2 loop wiring
/// (receive → watch → react → memory, sender toasts) is unchanged underneath.
struct RootView: View {
    @EnvironmentObject private var library: DropLibrary
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var arHolder: ARSessionHolder

    @StateObject private var router = AppRouter()
    @StateObject private var reactionSession = ReactionSession()
    @StateObject private var reactionService = ReactionService()
    @State private var receiveDropID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    /// Wave D (counsel SWE-7): the single cover binding. Dismissals run their
    /// per-destination side effects HERE — one place, no racing bindings.
    private var destinationBinding: Binding<AppRouter.Destination?> {
        Binding(
            get: { router.destination },
            set: { newValue in
                let previous = router.destination
                router.destination = newValue
                guard newValue == nil, let previous else { return }
                switch previous {
                case .create:
                    router.createPrefill = nil
                case .onboardingStory:
                    if router.onboardingPhase == .story { router.finishOnboarding() }
                case .memory:
                    reactionSession.endSession()
                case .camera:
                    // Swiping the demo camera away returns to the story beat.
                    if router.onboardingPhase == .fireworksDemo {
                        router.endFireworksDemo()
                    }
                }
            }
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            screen
                .ignoresSafeArea(.keyboard)
            NightTabBar()
        }
        .environmentObject(router)
        .environmentObject(reactionSession)
        .environmentObject(reactionService)
        .onAppear { router.startOnboardingIfNeeded() }
        // ---- Wave D (counsel SWE-7): ONE full-screen destination ----
        // Camera, create, onboarding and memory were four stacked covers on
        // this view; flows that dismissed one and presented another in the
        // same update silently dropped a cover (onboarding beat 2 — the one
        // designed magic moment — could fail to present). A single
        // `fullScreenCover(item:)` makes every transition one state change.
        .fullScreenCover(item: destinationBinding) { destination in
            switch destination {
            case .camera:
                ARScreen(isActive: true)
                    .environmentObject(router)
                    .environmentObject(reactionSession)
                    .environmentObject(reactionService)
            case .create:
                CreateWizard(initialCoordinate: router.createPrefill)
                    .environmentObject(router)
            case .onboardingStory:
                OnboardingView()
                    .environmentObject(router)
            case .memory:
                if let drop = reactionSession.drop {
                    MemoryScreen(
                        drop: drop,
                        snapshot: reactionSession.memorySnapshot,
                        watchedSeconds: reactionSession.watchedSeconds,
                        myReaction: reactionSession.sentEmoji,
                        delivery: reactionSession.delivery,
                        onSendOneBack: {
                            // One destination change (memory → create); the
                            // session ends explicitly, not via a dismiss race.
                            reactionSession.endSession()
                            router.beginCreate()
                        }
                    )
                    .environmentObject(reactionService)
                }
            }
        }
        // The reaction session's phase drives the memory destination — one
        // source of presentation truth.
        .onChange(of: reactionSession.phase) { _, phase in
            if phase == .memory { router.destination = .memory }
        }
        // ---- Receive: magic link → invitation → camera ----
        // Wave D (counsel SWE-7): a link tapped while a cover is up is QUEUED,
        // never presented into a busy presenter (where it silently vanished).
        .onOpenURL { url in
            if let id = DropSharingService.dropID(from: url) {
                if router.destination == nil, receiveDropID == nil {
                    receiveDropID = id
                } else {
                    router.pendingReceiveDropID = id
                }
            }
        }
        .onChange(of: router.destination) { _, destination in
            if destination == nil, let queued = router.pendingReceiveDropID {
                router.pendingReceiveDropID = nil
                receiveDropID = queued
            }
        }
        .sheet(item: $receiveDropID) { id in
            ReceiveScreen(dropID: id) { drop in
                // Round 4 (counsel arui-3): a failed save of the received drop
                // is announced IN AR — the screen the user is about to be on.
                // The moment still plays (the drop lives in memory this
                // session); the user just isn't lied to about it persisting.
                // Round 10 (counsel lens-1/seams-4/flows-1): the receive flow
                // goes through redeem() — the tombstone always clears, and a
                // fetched copy can never overwrite a pending local edit.
                Task {
                    do {
                        try await library.redeem(drop)
                    } catch {
                        arHolder.manager.showPersistError(
                            "Couldn't save this drop — it may disappear after this session"
                        )
                    }
                }
                reactionSession.startWatching(drop)
                router.showCamera = true
            }
        }
        // ---- Sender: live reaction toast ----
        .overlay(alignment: .top) {
            if let reaction = reactionService.incoming {
                HStack(spacing: 8) {
                    Text(reaction.emoji).font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(reaction.byName) reacted")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Night.ink)
                        if let title = reactionService.incomingDropTitle {
                            Text(title)
                                .font(.system(size: 11))
                                .foregroundStyle(Night.inkSecondary)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Night.bgBase.opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(Night.coral.opacity(0.4)))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    reactionService.clearIncoming()
                }
            }
        }
        .animation(.spring(duration: 0.4), value: reactionService.incoming)
        // ---- Round 4 (counsel arui-3): global persist-failure backstop ----
        // lastPersistError was rendered only on the Sent tab; failures fired
        // from the Map or the receive flow were invisible. This banner renders
        // above every tab, dismissed by acknowledgement.
        .overlay(alignment: .bottom) {
            if let error = library.lastPersistError {
                HStack(spacing: 10) {
                    Label(error, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Night.ink)
                        .lineLimit(2)
                    Button("OK") { library.clearPersistError() }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Night.coral)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Night.bgBase.opacity(0.95), in: Capsule())
                .overlay(Capsule().strokeBorder(Night.coral.opacity(0.5)))
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: library.lastPersistError)
        // ---- Sender: listen on my shared drops ----
        // Counsel PBS-3: keyed on the watched-drop IDENTITY set (drop count
        // misses the in-place share mutation — the sender never heard about
        // reactions to the drop they just shared).
        .task(id: ReactionService.listenKey(for: library.drops, myUid: account.uid)) {
            reactionService.listenToMySharedDrops(library.drops, myUid: account.uid)
        }
        // ---- Wave D (counsel SWE-10/PBS-9): listeners are lifecycle-owned ----
        // Torn down when the scene leaves the foreground (each is a live
        // Firestore stream: network, battery, per-read billing) and re-attached
        // on return; the primed-set watermark makes the re-attach's initial
        // snapshot history, never a stale toast.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                reactionService.stop()
            case .active:
                reactionService.listenToMySharedDrops(library.drops, myUid: account.uid)
            default:
                break
            }
        }
        // ---- Wave C (counsel SWE-3): auth-ready reconciliation ----
        // Round 2 (C21 — CRITICAL): a full refresh, never a bare reconcile.
        // Reconcile must not run against a not-yet-loaded library, and refresh
        // also retries the cloud read a pre-auth launch skipped.
        .task(id: account.uid ?? "-") {
            // Round 12 (counsel SURF-lens-1/STATE-lens-3/FLOWS-lens-3): ONE
            // composed entry point. The old refresh-then-accountDidChange
            // sequence reset the evidence latch the refresh had just earned,
            // pinning the ladder at "Checking sync status…" every session.
            guard let uid = account.uid else { return }
            await library.authDidBecomeReady(uid: uid)
        }
    }

    @ViewBuilder private var screen: some View {
        switch router.tab {
        case .home: HomeScreen()
        case .explore: MapScreen()
        case .sent: DropsListScreen()
        case .you: ProfileScreen()
        }
    }
}

/// The floating Night tab bar with the breathing create-orb at center.
struct NightTabBar: View {
    @EnvironmentObject private var router: AppRouter
    @State private var breathe = false

    var body: some View {
        HStack(alignment: .bottom) {
            tab(.home, icon: "house.fill", label: "Home")
            tab(.explore, icon: "map.fill", label: "Explore")

            Button {
                router.beginCreate()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Night.gold, Night.coral],
                                center: .topLeading, startRadius: 4, endRadius: 44
                            )
                        )
                        .frame(width: 54, height: 54)
                        .shadow(color: Night.coral.opacity(0.65), radius: breathe ? 18 : 10, y: 4)
                        .scaleEffect(breathe ? 1.05 : 1.0)
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Night.onCTA)
                }
            }
            .offset(y: -18)
            .accessibilityLabel("Drop a surprise")

            tab(.sent, icon: "shippingbox.fill", label: "Sent")
            tab(.you, icon: "person.crop.circle.fill", label: "You")
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(
            Night.bgBase.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 26)
        )
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Night.lineSubtle))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    private func tab(_ target: AppRouter.Tab, icon: String, label: String) -> some View {
        Button {
            router.tab = target
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(router.tab == target ? Night.gold : Night.inkTertiary)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(label)
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

#Preview {
    RootView()
        .environmentObject(LocationService())
        .environmentObject(DropLibrary())
        .environmentObject(ARSessionHolder())
        .environmentObject(AccountService())
}
