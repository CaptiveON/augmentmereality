import Combine
import SwiftUI

/// Stages 03–04 · WATCH/REACT — viewer-side session state. Watching a received
/// drop shows the reaction bar; the first reaction starts the graceful wrap
/// (15 s, extendable); the wrap ends in a Memory (PRODUCT-ROUTE §0 loop).
@MainActor
final class ReactionSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case watching
        case wrapping(remaining: Int)
        case memory
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var drop: GeoDrop?
    @Published private(set) var sentEmoji: String?
    @Published var memorySnapshot: UIImage?

    static let reactions = ["❤️", "😂", "🥹", "🤯"]
    private var wrapTask: Task<Void, Never>?
    private var watchStartedAt: Date?

    var watchedSeconds: Int {
        watchStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
    }

    func startWatching(_ drop: GeoDrop) {
        self.drop = drop
        sentEmoji = nil
        delivery = nil
        sendToken &+= 1 // round 6: any in-flight send for a previous drop is stale
        memorySnapshot = nil
        watchStartedAt = Date()
        phase = .watching
    }

    /// Round 6 (counsel round-5 critical 1): RITUAL and RECEIPT are separate.
    /// The wrap countdown is a LOCAL UI timer — it starts on the tap, always,
    /// so the Memory screen (the loop's payoff) never depends on network I/O.
    /// The delivery pill carries the honesty: Sending → Sent / Queued / Failed,
    /// where "queued" is the truthful offline outcome (Firestore's local write
    /// queue survives restarts and flushes on reconnect).
    enum Delivery: Equatable {
        case sending, delivered, queued, failed
    }
    @Published private(set) var delivery: Delivery?
    /// Round 6 (counsel flows-4): per-send identity — a late completion for an
    /// earlier tap (or an earlier DROP) must never repaint the current state.
    private var sendToken: UInt64 = 0

    /// The reaction tap: latch, start the RITUAL, and issue a send token the
    /// completion must present to be believed.
    func didReact(_ emoji: String) -> UInt64 {
        sentEmoji = emoji
        delivery = .sending
        sendToken &+= 1
        if case .watching = phase {
            startWrap(seconds: 15)
        }
        return sendToken
    }

    /// The server accepted the reaction — honestly "Sent".
    func reactionDelivered(token: UInt64) {
        guard token == sendToken else { return }
        delivery = .delivered
    }

    /// The write is durably queued (offline) — will send on reconnect.
    func reactionQueued(token: UInt64) {
        guard token == sendToken else { return }
        delivery = .queued
    }

    /// The server rejected — say so, offer retry.
    func reactionFailed(token: UInt64) {
        guard token == sendToken else { return }
        delivery = .failed
    }

    /// "Hold to keep watching" — resets the wrap window.
    func extendSession() {
        guard case .wrapping = phase else { return }
        startWrap(seconds: 30)
    }

    private func startWrap(seconds: Int) {
        wrapTask?.cancel()
        phase = .wrapping(remaining: seconds)
        wrapTask = Task { [weak self] in
            var remaining = seconds
            while remaining > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1
                guard let self, case .wrapping = self.phase else { return }
                self.phase = .wrapping(remaining: remaining)
            }
            guard let self, !Task.isCancelled else { return }
            self.phase = .memory
        }
    }

    func endSession() {
        wrapTask?.cancel()
        phase = .idle
        drop = nil
        sentEmoji = nil
        memorySnapshot = nil
    }
}

/// The glass reaction bar + wrap chip drawn over the AR view (Figma 03/04).
struct ReactionOverlay: View {
    @EnvironmentObject private var session: ReactionSession
    @EnvironmentObject private var reactions: ReactionService
    @EnvironmentObject private var account: AccountService

    var body: some View {
        VStack(spacing: 10) {
            if let drop = session.drop {
                // Top: presence pill (Figma "livepill")
                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(Night.mint)
                            .frame(width: 7, height: 7)
                            .shadow(color: Night.mint, radius: 5)
                        Text("LIVE")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Night.ink)
                        Text("· \(drop.createdBy) sees your reactions")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Night.inkSecondary)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(Night.bgBase.opacity(0.78), in: Capsule())
                    .overlay(Capsule().strokeBorder(Night.lineSubtle))
                    Spacer()
                    Button {
                        session.endSession()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Night.inkSecondary)
                            .frame(width: 34, height: 34)
                            .background(Night.bgBase.opacity(0.78), in: Circle())
                            .overlay(Circle().strokeBorder(Night.lineSubtle))
                    }
                }
                .padding(.top, 2)

                Spacer()
                if let emoji = session.sentEmoji {
                    // Round 4 (flows-6): the pill tells the truth — "Sent"
                    // appears only after the server acknowledged the write.
                    HStack(spacing: 7) {
                        Text(emoji)
                        Text(deliveryText(to: drop.createdBy))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(
                                session.delivery == .failed ? Night.coral : Night.ink
                            )
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Night.bgBase.opacity(0.85), in: Capsule())
                    .overlay(Capsule().strokeBorder(
                        session.delivery == .failed
                            ? Night.coral.opacity(0.8) : Night.coral.opacity(0.4)
                    ))
                    .transition(.scale.combined(with: .opacity))
                }

                if case .wrapping(let remaining) = session.phase {
                    NightChip(text: "SESSION WRAPS IN \(remaining) S")
                        .onTapGesture { session.extendSession() }
                }

                HStack(spacing: 8) {
                    ForEach(ReactionSession.reactions, id: \.self) { emoji in
                        Button {
                            var token: UInt64 = 0
                            withAnimation(.bouncy) { token = session.didReact(emoji) }
                            let drop = drop
                            Task {
                                do {
                                    let result = try await reactions.send(
                                        emoji, to: drop, from: account.profile
                                    )
                                    switch result {
                                    case .delivered: session.reactionDelivered(token: token)
                                    case .queued: session.reactionQueued(token: token)
                                    }
                                } catch {
                                    session.reactionFailed(token: token)
                                }
                            }
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(width: 46, height: 46)
                                .background(
                                    session.sentEmoji == emoji
                                        ? Night.coral.opacity(0.18) : .clear,
                                    in: Circle()
                                )
                                .overlay(
                                    Circle().strokeBorder(
                                        session.sentEmoji == emoji ? Night.coral : .clear,
                                        lineWidth: 2
                                    )
                                )
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Night.bgBase.opacity(0.78), in: Capsule())
                .overlay(Capsule().strokeBorder(Night.lineSubtle))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .animation(.easeOut(duration: 0.25), value: session.sentEmoji)
        .animation(.easeOut(duration: 0.25), value: session.delivery)
    }

    private func deliveryText(to sender: String) -> String {
        switch session.delivery {
        case .sending: return "Sending to \(sender)…"
        case .delivered: return "Sent to \(sender)"
        case .queued: return "Will send to \(sender) when you're back online"
        case .failed: return "Couldn't send — tap an emoji to retry"
        case nil: return "Sending to \(sender)…"
        }
    }
}
