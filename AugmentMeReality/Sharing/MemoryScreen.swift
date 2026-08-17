import SwiftUI

/// Stage 05 · MEMORY (Figma 2:29) — the graceful close: session becomes a
/// keepsake, and the loop invites the reply.
struct MemoryScreen: View {
    let drop: GeoDrop
    let snapshot: UIImage?
    let watchedSeconds: Int
    let myReaction: String?
    /// Round 8 (counsel B2/ux-1): the delivery outcome of MY reaction. This
    /// screen is the loop's payoff and the only artifact the user can save to
    /// Photos — `.delivered`, `.queued` and `.failed` must render distinctly;
    /// a rejected send must never read as received.
    let delivery: ReactionSession.Delivery?
    /// "Send one back" → route to the map composer.
    var onSendOneBack: () -> Void

    @EnvironmentObject private var reactions: ReactionService
    @Environment(\.dismiss) private var dismiss
    /// Round 10 (counsel ux-2/flows-2): the recap carries provenance — nil is
    /// still-loading; `serverAnswered == false` renders as UNKNOWN, never as
    /// a confident zero or (worse) a cache-fabricated receipt.
    @State private var recap: ReactionService.ReactionRecap?
    @State private var saved = false

    var body: some View {
        ZStack {
            Night.bgScreen.ignoresSafeArea()
            confetti
            VStack(spacing: 14) {
                HStack {
                    NightChip(text: "SESSION CLOSED")
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Night.inkSecondary)
                            .frame(width: 34, height: 34)
                            .background(Night.glass, in: Circle())
                            .overlay(Circle().strokeBorder(Night.lineSubtle))
                    }
                }

                polaroid
                    .rotationEffect(.degrees(-2.5))
                    .padding(.vertical, 6)

                Text("That made \(possessive) day.")
                    .font(Night.display(26))
                    .foregroundStyle(Night.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    // Round 8 (counsel B2/ux-1): my reaction renders with its
                    // TRUE delivery outcome; the summary below counts only
                    // SERVER-confirmed reactions from others (round 10,
                    // counsel ux-2/flows-2). Nothing on this screen
                    // fabricates a receipt.
                    if let myReaction {
                        recapLine(
                            left: myReaction,
                            leftBold: myReactionStatus,
                            right: myReactionBadge,
                            tint: delivery == .failed ? Night.coral : Night.ink
                        )
                    }
                    if let recap {
                        if recap.serverAnswered, !reactionSummary.isEmpty {
                            recapLine(
                                left: reactionSummary,
                                leftBold: "on this drop",
                                right: firstReactionLabel
                            )
                        } else if !recap.serverAnswered {
                            // Round 12 (counsel SURF-lens-3): no cause is
                            // asserted (the read may have been denied, not
                            // offline) and no landing place is promised —
                            // this screen's read is one-shot.
                            recapLine(
                                left: "☁️",
                                leftBold: "Reactions couldn't be checked right now",
                                right: "",
                                tint: Night.inkTertiary
                            )
                        }
                    }
                    recapLine(left: "👀", leftBold: "Watched live", right: "\(watchedSeconds) S")
                }

                Spacer()

                NightCTA(title: saved ? "Saved to Photos ✓" : "Save memory") {
                    saveToPhotos()
                }
                NightGhost(title: "Send one back") {
                    // Wave D (counsel SWE-7): the closure performs ONE
                    // destination change — a dismiss()+present pair here was
                    // exactly the racing-bindings pattern that dropped covers.
                    onSendOneBack()
                }
                Text("Closed itself — short & battery-kind by design")
                    .font(.system(size: 11))
                    .foregroundStyle(Night.inkTertiary)
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
        .task { recap = await reactions.reactions(for: drop) }
    }

    private var polaroid: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.094, green: 0.125, blue: 0.21),
                                     Color(red: 0.051, green: 0.066, blue: 0.098)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                if let snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(drop.title)
                        .font(Night.display(24))
                        .foregroundStyle(Night.ctaGradient)
                        .rotationEffect(.degrees(-4))
                }
            }
            .frame(height: 210)
            HStack {
                Text(Date().formatted(.dateTime.day().month(.wide).hour().minute()).uppercased())
                Spacer()
                Text("AUGMENTME")
            }
            .font(Night.mono(10))
            .kerning(1)
            .foregroundStyle(Color(red: 0.43, green: 0.39, blue: 0.34))
            .padding(.horizontal, 2)
        }
        .padding(10)
        .background(Color(red: 0.97, green: 0.95, blue: 0.93), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.75), radius: 22, y: 14)
    }

    private var confetti: some View {
        GeometryReader { geo in
            ForEach(0..<8, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill([Night.coral, Night.gold, Night.mint, Night.indigo][index % 4])
                    .frame(width: 5, height: 5)
                    .opacity(0.5)
                    .rotationEffect(.degrees(20))
                    .position(
                        x: geo.size.width * [0.12, 0.82, 0.31, 0.65, 0.91, 0.21, 0.55, 0.74][index],
                        y: geo.size.height * [0.10, 0.13, 0.20, 0.08, 0.25, 0.34, 0.16, 0.29][index]
                    )
            }
        }
        .ignoresSafeArea()
    }

    private var possessive: String {
        drop.recipientName == nil ? "their" : "\(drop.recipientName!)'s"
    }

    /// Round 8 (counsel B2/ux-1) + round 10 (counsel ux-2): counts ONLY
    /// server-confirmed reactions from OTHERS — never a fabricated local tap,
    /// never a cache-served copy of my own unflushed write.
    private var reactionSummary: String {
        let counts = Dictionary(grouping: recap?.rows ?? [], by: \.emoji)
        return counts.map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: "  ")
    }

    private var myReactionStatus: String {
        switch delivery {
        case .delivered: return "Your reaction reached \(drop.createdBy)"
        case .queued: return "Sends to \(drop.createdBy) when you're back online"
        case .failed: return "Couldn't send — it lives in this memory only"
        case .sending, nil: return "Sending to \(drop.createdBy)…"
        }
    }

    private var myReactionBadge: String {
        switch delivery {
        case .delivered: return "SENT"
        case .queued: return "QUEUED"
        case .failed: return "NOT SENT"
        case .sending, nil: return "SENDING"
        }
    }

    private var firstReactionLabel: String {
        // Round 10 (counsel ux-2): the badge keys on a SERVER-confirmed row.
        // Round 12 (counsel SURF-lens-6): timed over ALL confirmed reactions
        // including the viewer's own — never crowning a later reaction
        // "first" because the true first was excluded from the count.
        guard let recap, recap.serverAnswered, let firstAt = recap.firstAt else { return "" }
        let delta = max(0, Int(firstAt.timeIntervalSince(drop.createdAt)))
        return delta < 600 ? "FIRST IN \(delta) S" : ""
    }

    private func recapLine(
        left: String, leftBold: String, right: String, tint: Color = Night.ink
    ) -> some View {
        HStack(spacing: 6) {
            Text(left).font(.system(size: 14)).foregroundStyle(Night.coral)
            Text(leftBold).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            Spacer()
            Text(right).font(Night.mono(11)).foregroundStyle(Night.inkTertiary)
        }
    }

    private func saveToPhotos() {
        guard let snapshot else { return }
        UIImageWriteToSavedPhotosAlbum(snapshot, nil, nil, nil)
        saved = true
    }
}
