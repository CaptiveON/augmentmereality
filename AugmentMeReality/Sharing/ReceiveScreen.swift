import CoreLocation
import SwiftUI

/// Stage 02 · RECEIVE (Figma 2:23) — the invitation moment after opening a
/// magic link. Fetches the shared drop, then hands off to the AR camera.
struct ReceiveScreen: View {
    let dropID: UUID
    /// Called with the fetched drop when the receiver taps "Reveal in AR".
    var onReveal: (GeoDrop) -> Void

    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var arHolder: ARSessionHolder
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss

    /// Round 12 (counsel SURF-lens-2): the two verdicts, mapped from the
    /// tri-state fetch. `.gone` renders only on a served server answer;
    /// `.unknown` claims NO cause (under the deployed rules a denied read is
    /// indistinguishable from offline) and offers retry.
    private enum LoadFailure {
        case gone, unknown
    }

    @State private var drop: GeoDrop?
    @State private var failure: LoadFailure?

    var body: some View {
        ZStack {
            Night.bgScreen.ignoresSafeArea()
            RadialGradient(
                colors: [Night.coral.opacity(0.10), .clear],
                center: .init(x: 0.5, y: 0.28), startRadius: 10, endRadius: 320
            )
            .ignoresSafeArea()

            if let drop {
                invitation(drop)
            } else if let failure {
                failedView(failure)
            } else {
                ProgressView()
                    .tint(Night.coral)
                    .scaleEffect(1.4)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // ADR-043: opening a drop link IS camera intent — start the session
            // behind the invitation so "Reveal in AR" lands in a live camera.
            arHolder.beginRevealWarmup(heroID: dropID)
        }
        // Round 12 (counsel SURF-lens-2): a first-ever launch from a link
        // races anonymous sign-in — the fetch waits for the uid instead of
        // burning its answer on an unauthenticated read. Round 14 (counsel
        // seams-1/flows-lens-2): the wait is BOUNDED — a stalled or failed
        // sign-in falls through to the honest retryable state instead of an
        // unbounded, unlabelled spinner on the acquisition path.
        .task(id: account.uid ?? "-") {
            guard drop == nil else { return }
            guard account.uid != nil else {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, account.uid == nil,
                      drop == nil, failure == nil else { return }
                failure = .unknown
                return
            }
            await load()
        }
    }

    private func invitation(_ drop: GeoDrop) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text(Date().formatted(date: .omitted, time: .shortened))
                .font(Night.mono(13))
                .kerning(2)
                .foregroundStyle(Night.inkTertiary)

            ZStack {
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [Night.gold, Night.coral, Night.gold],
                            center: .center
                        ),
                        lineWidth: 5
                    )
                    .frame(width: 92, height: 92)
                NightAvatar(
                    monogram: String(drop.createdBy.prefix(1)).uppercased(),
                    size: 68, warm: true
                )
            }
            .padding(.bottom, 6)

            (Text("\(drop.createdBy) left a\n")
                + Text("surprise").foregroundStyle(Night.coral)
                + Text(" for you"))
                .font(Night.display(27))
                .multilineTextAlignment(.center)
                .foregroundStyle(Night.ink)

            HStack(spacing: 7) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Night.mint)
                Text(placeLine(drop))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Night.inkSecondary)
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Night.glass, in: Capsule())
            .overlay(Capsule().strokeBorder(Night.lineSubtle))

            Spacer().frame(height: 22)

            NightCTA(title: "Reveal in AR") {
                onReveal(drop)
                dismiss()
            }
            NightGhost(title: "Later") { dismiss() }
            // Round 14 (counsel surf-lens-4): no access-control claim the
            // rules don't implement — the link is shareable, not one-time.
            Text("Only people with this link can find it · your camera stays private")
                .font(.system(size: 11))
                .foregroundStyle(Night.inkTertiary)
            Spacer()
        }
        .padding(26)
    }

    private func failedView(_ failure: LoadFailure) -> some View {
        VStack(spacing: 12) {
            Text(failure == .gone
                ? "This drop isn't available"
                : "This link can't be opened right now")
                .font(Night.display(22))
                .foregroundStyle(Night.ink)
            Text(failure == .gone
                ? "The sender may have taken it back, or the link expired."
                // Round 12 (counsel SURF-lens-2): no cause is claimed — a
                // denied read, offline, and auth-in-flight are one state here.
                : "It may still be waiting — check your connection and try again in a moment.")
                .font(.system(size: 13))
                .foregroundStyle(Night.inkSecondary)
            if failure == .unknown {
                NightCTA(title: "Try again") {
                    Task { await load() }
                }
                .frame(width: 200)
            }
            NightGhost(title: "Close") { dismiss() }
                .frame(width: 180)
        }
        .padding(30)
    }

    private func placeLine(_ drop: GeoDrop) -> String {
        if let here = locationService.location {
            let meters = drop.location.distance(from: here)
            return "Waiting at the pinned spot · \(GeoMath.distanceLabel(meters)) away"
        }
        return "Waiting at the pinned spot"
    }

    private func load() async {
        failure = nil
        switch await DropSharingService.fetchSharedDrop(id: dropID) {
        case .found(let fetched):
            drop = fetched
        case .absent:
            failure = .gone // the SERVER answered: the document is not there
        case .unknown:
            failure = .unknown // no authoritative answer — retryable
        }
    }
}
