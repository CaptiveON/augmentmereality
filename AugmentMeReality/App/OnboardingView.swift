import SwiftUI

/// UI revamp (ADR-048): three beats, skippable, value-before-signup.
/// Beat 2 leaves this cover entirely — the user lights REAL fireworks on
/// their own floor (Playground + the procedural show), then returns here for
/// beat 3 (a name, not a signup).
struct OnboardingView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var arHolder: ARSessionHolder
    @AppStorage("displayName") private var displayName = ""

    /// 0 = promise, 1 = demo invite, 2 = name. Round 2 (counsel FLOW-1):
    /// lives on the ROUTER — the single-cover model tears this view down
    /// during the fireworks hand-off, so view-local @State was destroyed and
    /// beat 3 was unreachable.
    private var beat: Int { router.onboardingBeat }
    @State private var draftName = ""

    var body: some View {
        ZStack {
            Night.bgScreen.ignoresSafeArea()
            RadialGradient(
                colors: [Night.coral.opacity(0.14), .clear],
                center: .init(x: 0.5, y: 0.3), startRadius: 20, endRadius: 340
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    if beat < 2 {
                        Button("Skip") { finish() }
                            .font(.system(size: 12.5))
                            .foregroundStyle(Night.inkTertiary)
                    }
                }
                Spacer()

                switch beat {
                case 0: promise
                case 1: demoInvite
                default: nameBeat
                }

                Spacer()
                dots
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    private var promise: some View {
        VStack(spacing: 16) {
            orb(size: 62)
            Text("Hide magic in the\nreal world")
                .font(Night.display(28))
                .multilineTextAlignment(.center)
                .foregroundStyle(Night.ink)
            Text("3D surprises, waiting at real places,\nfor people you love.")
                .font(.system(size: 13.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(Night.inkSecondary)
            NightCTA(title: "Show me") {
                withAnimation(.easeInOut) { router.onboardingBeat = 1 }
            }
            .frame(width: 230)
            .padding(.top, 8)
        }
    }

    private var demoInvite: some View {
        VStack(spacing: 16) {
            Text("🎆").font(.system(size: 52))
            Text("Try one — right here,\nright now")
                .font(Night.display(26))
                .multilineTextAlignment(.center)
                .foregroundStyle(Night.ink)
            Text("Real fireworks, on your floor,\nin the next twenty seconds.")
                .font(.system(size: 13.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(Night.inkSecondary)
            NightCTA(title: "Light fireworks on my floor") {
                startDemo()
            }
            .padding(.top, 8)
            Text("uses your camera — that's all")
                .font(.system(size: 11))
                .foregroundStyle(Night.inkTertiary)
        }
    }

    private var nameBeat: some View {
        VStack(spacing: 16) {
            orb(size: 46)
            Text("Who's dropping?")
                .font(Night.display(26))
                .foregroundStyle(Night.ink)
            Text("Just a name — so friends know\nwho the magic is from.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Night.inkSecondary)
            TextField(
                "", text: $draftName,
                prompt: Text("Your name").foregroundStyle(Night.inkTertiary)
            )
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Night.ink)
            .multilineTextAlignment(.center)
            .padding(14)
            .background(Night.glass, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Night.lineSubtle))
            NightCTA(title: "Start dropping") {
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    displayName = name
                    let handle = name.lowercased().replacingOccurrences(of: " ", with: "")
                    Task { await account.updateProfile(displayName: name, handle: handle) }
                }
                finish()
            }
            Text("No email. No password. Your drops sync automatically.")
                .font(.system(size: 10.5))
                .foregroundStyle(Night.inkTertiary)
        }
        .onAppear { draftName = displayName }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index == beat ? Night.gold : Night.inkTertiary.opacity(0.5))
                    .frame(width: index == beat ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut, value: beat)
    }

    private func orb(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Night.gold, Night.coral], center: .topLeading,
                    startRadius: 3, endRadius: size * 0.85
                )
            )
            .frame(width: size, height: size)
            .shadow(color: Night.coral.opacity(0.8), radius: 22)
    }

    private func startDemo() {
        arHolder.beginRevealWarmup()
        // Round 2 (counsel RSCH-1): the demo is IDEMPOTENT — a repeated loop
        // must never accumulate fireworks emitters on the floor.
        arHolder.manager.clearRoomDrops()
        router.beginFireworksDemo() // advances the beat on the router
        // Place the fireworks once the session has real frames.
        let manager = arHolder.manager
        Task { @MainActor in
            for _ in 0..<25 where !manager.sessionFrameReady {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            manager.placeRoomDrop(content: .fireworks)
        }
    }

    private func finish() {
        router.finishOnboarding()
    }
}
