import CoreLocation
import SwiftUI

/// UI revamp (ADR-048): the front door. Answers "what now?" with emotional
/// state — what's waiting FOR you, what of yours is still unopened, and the
/// sandbox. The map is a tool elsewhere; this screen is about people.
struct HomeScreen: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var reactionSession: ReactionSession
    @EnvironmentObject private var library: DropLibrary
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var arHolder: ARSessionHolder

    var body: some View {
        ZStack {
            Night.bgScreen.ignoresSafeArea()
            RadialGradient(
                colors: [Night.coral.opacity(0.07), .clear],
                center: .init(x: 0.75, y: 0), startRadius: 20, endRadius: 420
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    header

                    if receivedDrops.isEmpty && inMotionDrops.isEmpty {
                        emptyHero
                    } else {
                        ForEach(receivedDrops.prefix(2)) { drop in
                            forYouCard(drop)
                        }
                        ForEach(inMotionDrops.prefix(3)) { drop in
                            inMotionCard(drop)
                        }
                    }

                    playgroundCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 110) // clear the floating tab bar
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Data

    private var myUid: String? { account.uid }

    private var receivedDrops: [GeoDrop] {
        library.drops
            .filter { $0.receivedViaLink == true }
            .sorted { distance(to: $0) < distance(to: $1) }
    }

    private var inMotionDrops: [GeoDrop] {
        library.drops.filter {
            $0.receivedViaLink != true && $0.visibility != "private"
        }
    }

    private func distance(to drop: GeoDrop) -> CLLocationDistance {
        guard let here = locationService.location else { return .greatestFiniteMagnitude }
        return drop.location.distance(from: here)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting)
                    .font(Night.display(22))
                    .foregroundStyle(Night.ink)
                Text(subline)
                    .font(.system(size: 12))
                    .foregroundStyle(Night.inkTertiary)
            }
            Spacer()
            Button {
                router.tab = .you
            } label: {
                NightAvatar(monogram: account.profile?.monogram ?? "☺︎", size: 36)
            }
        }
        .padding(.top, 8)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = account.profile?.displayName.split(separator: " ").first.map(String.init) ?? ""
        let base: String
        switch hour {
        case 5..<12: base = "Morning"
        case 12..<18: base = "Afternoon"
        default: base = "Evening"
        }
        return name.isEmpty ? base : "\(base), \(name)"
    }

    private var subline: String {
        let count = receivedDrops.count + inMotionDrops.count
        return count == 0 ? "your first drop awaits" : "\(count) moment\(count == 1 ? "" : "s") in motion"
    }

    private var emptyHero: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Night.gold, Night.coral], center: .topLeading,
                        startRadius: 4, endRadius: 46
                    )
                )
                .frame(width: 54, height: 54)
                .shadow(color: Night.coral.opacity(0.75), radius: 20)
            Text("Someone's day is about\nto be made")
                .font(Night.display(19))
                .multilineTextAlignment(.center)
                .foregroundStyle(Night.ink)
            Text("Drop a 3D surprise where they'll find it —\ntakes about a minute.")
                .font(.system(size: 12.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(Night.inkSecondary)
            NightCTA(title: "Drop a surprise") {
                router.beginCreate()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .background(
            RadialGradient(
                colors: [Night.coral.opacity(0.12), .clear],
                center: .init(x: 0.5, y: 0), startRadius: 10, endRadius: 260
            ),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Night.lineSubtle))
    }

    private func forYouCard(_ drop: GeoDrop) -> some View {
        Button {
            // Round 2 (counsel FLOW-10): watching a received drop STARTS the
            // watch session — the reaction bar, wrap and Memory only exist
            // for a session; without this the react→memory loop was link-only.
            reactionSession.startWatching(drop)
            router.showCamera = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("🎁 WAITING FOR YOU")
                    .font(Night.mono(9)).kerning(1.2)
                    .foregroundStyle(Night.mint)
                Text("\(drop.createdBy) left you \(drop.content == .text3D ? "“\(drop.title)”" : "a surprise")")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Night.ink)
                    .multilineTextAlignment(.leading)
                Text(forYouSub(drop))
                    .font(.system(size: 11))
                    .foregroundStyle(Night.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [Night.mint.opacity(0.14), Color(red: 0.2, green: 0.68, blue: 0.9).opacity(0.07)],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Night.mint.opacity(0.25)))
        }
    }

    private func forYouSub(_ drop: GeoDrop) -> String {
        guard let here = locationService.location else { return "open the camera when you're at the spot" }
        let meters = drop.location.distance(from: here)
        return meters < 60
            ? "you're here — open the camera →"
            : "\(GeoMath.distanceLabel(meters)) away · tap when you're close"
    }

    private func inMotionCard(_ drop: GeoDrop) -> some View {
        Button {
            router.tab = .sent
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("⏳ NOT OPENED YET")
                    .font(Night.mono(9)).kerning(1.2)
                    .foregroundStyle(Night.gold)
                Text("\(drop.content == .text3D ? "“\(drop.title)”" : drop.content.displayName) waits for \(drop.recipientName ?? "them")")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Night.ink)
                    .multilineTextAlignment(.leading)
                Text("sent \(drop.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundStyle(Night.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [Night.gold.opacity(0.13), Night.coral.opacity(0.07)],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Night.gold.opacity(0.22)))
        }
    }

    private var playgroundCard: some View {
        Button {
            router.showCamera = true
        } label: {
            HStack(spacing: 12) {
                Text("🎆").font(.system(size: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playground")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Night.ink)
                    Text("Try any object in your room — no location needed")
                        .font(.system(size: 11))
                        .foregroundStyle(Night.inkTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Night.inkTertiary)
            }
            .padding(14)
            .background(Night.glass, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Night.lineSubtle))
        }
    }
}
