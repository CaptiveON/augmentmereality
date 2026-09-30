import MapKit
import SwiftUI

/// Stage 01 · SHARE (Figma 2:21) — the send moment after composing a drop.
struct ShareDropSheet: View {
    let drop: GeoDrop

    @EnvironmentObject private var library: DropLibrary
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss

    @State private var recipientName: String
    @State private var showShareSheet = false
    @State private var preparedShare: GeoDrop?
    /// Wave C (counsel SWE-14/SWE-3): the link is only handed out after the
    /// share persisted; a failure shows here instead of a silent dead link.
    @State private var shareError: String?

    init(drop: GeoDrop) {
        self.drop = drop
        _recipientName = State(initialValue: drop.recipientName ?? "")
    }

    var body: some View {
        ZStack {
            Night.bgScreen.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Night.inkSecondary)
                            .frame(width: 34, height: 34)
                            .background(Night.glass, in: Circle())
                            .overlay(Circle().strokeBorder(Night.lineSubtle))
                    }
                    Spacer()
                    Text("Send your drop")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Night.ink)
                    Spacer()
                    NightChip(text: "READY")
                }

                // Map card with the glowing pin. Round 12 (counsel
                // SURF-lens-7): every preview reads liveDrop — the captured
                // copy and the persisted row must never tell two stories.
                ZStack {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: liveDrop.coordinate,
                        latitudinalMeters: 320, longitudinalMeters: 320
                    ))) {
                        Annotation("", coordinate: liveDrop.coordinate) {
                            ZStack {
                                Circle().strokeBorder(Night.coral.opacity(0.5), lineWidth: 1.5)
                                    .frame(width: 44, height: 44)
                                Circle().fill(Night.coral)
                                    .frame(width: 14, height: 14)
                                    .shadow(color: Night.coral.opacity(0.9), radius: 9)
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .allowsHitTesting(false)
                    .colorScheme(.dark)
                }
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Night.lineSubtle))

                NightCard {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Night.coral.opacity(0.1))
                                .overlay(RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Night.coral.opacity(0.35)))
                            Text(liveDrop.content == .text3D ? String(liveDrop.title.prefix(6)) : liveDrop.content.displayName)
                                .font(Night.display(12))
                                .foregroundStyle(Night.coral)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .padding(4)
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(liveDrop.content.displayName) · ×\(Int(liveDrop.scale))")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Night.ink)
                            Text("Placed once · waits at the spot")
                                .font(.system(size: 12))
                                .foregroundStyle(Night.inkTertiary)
                        }
                    }
                }

                NightCard {
                    HStack(spacing: 12) {
                        NightAvatar(
                            monogram: recipientName.isEmpty
                                ? "?" : String(recipientName.prefix(1)).uppercased()
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            TextField(
                                "", text: $recipientName,
                                prompt: Text("Who is it for?").foregroundStyle(Night.inkTertiary)
                            )
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Night.ink)
                            Text("Magic link — they open it straight into camera")
                                .font(.system(size: 12))
                                .foregroundStyle(Night.inkTertiary)
                        }
                    }
                }

                if !liveDrop.message.isEmpty {
                    NightCard {
                        Text("“\(liveDrop.message)”")
                            .font(.system(size: 14))
                            .foregroundStyle(Night.ink)
                        Text("shows when they open the link")
                            .font(.system(size: 12))
                            .foregroundStyle(Night.inkTertiary)
                    }
                }

                Spacer()

                NightCTA(title: "Send the magic link") {
                    Task { await sendLink() }
                }
                .disabled(!library.canShare(id: drop.id))
                if let shareError {
                    Text(shareError)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Night.coral)
                        .multilineTextAlignment(.center)
                } else if !library.canShare(id: drop.id) {
                    Text("Ownership must be verified on this account before this drop can be shared")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Night.coral)
                        .multilineTextAlignment(.center)
                } else if library.terminalSyncFailureIDs.contains(drop.id) {
                    // Round 4 (counsel flows-3): a terminal upload failure must
                    // OUTRANK every reassuring caption — the link is dead and
                    // the sender must know before they send it.
                    Text(library.syncFailureReasons[drop.id]
                        ?? "This drop can't upload from this account connection — the link won't work")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Night.coral)
                        .multilineTextAlignment(.center)
                } else if library.pendingSyncIDs.contains(drop.id) {
                    // Honest state: the link is real but the upload hasn't been
                    // acknowledged yet — it works once the drop reaches the cloud.
                    Text("Still uploading — the link starts working once your drop reaches the cloud")
                        .font(.system(size: 11))
                        .foregroundStyle(Night.gold)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Sharing makes this drop visible to anyone with the link")
                        .font(.system(size: 11))
                        .foregroundStyle(Night.inkTertiary)
                }
            }
            .padding(18)
        }
        .preferredColorScheme(.dark)
        // Round 10 (counsel ux-6): the refusal caption dies WITH its verdict —
        // when the background revalidation's ack clears the terminal set, the
        // sheet must not keep asserting a failure that no longer holds.
        .onChange(of: library.terminalSyncFailureIDs.contains(drop.id)) { _, isTerminal in
            if !isTerminal { shareError = nil }
        }
        .onChange(of: account.uid) { _, _ in
            preparedShare = nil
            showShareSheet = false
            shareError = "The account changed — reopen the drop to share it"
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            // Round 4 (flows-3): stay open on a terminal failure so the user
            // sees the truth instead of landing on the Sent tab reassured.
            if !library.terminalSyncFailureIDs.contains(drop.id) {
                dismiss()
            }
        }) {
            if let preparedShare {
                ActivitySheet(items: [DropSharingService.shareMessage(
                    for: preparedShare, senderName: senderName
                )])
            }
        }
    }

    /// Round 10 (counsel flows-3): presentation-captured value types go stale
    /// — the sheet reads the LIVE row whenever it exists, so the share copy
    /// and the captions always describe persisted truth.
    private var liveDrop: GeoDrop {
        library.drops.first(where: { $0.id == drop.id }) ?? drop
    }

    private var senderName: String {
        guard let profile = account.profile, profile.uid == account.uid else {
            return liveDrop.createdBy
        }
        return profile.displayName
    }

    private func sendLink() async {
        let accountUID = account.uid
        guard accountUID != nil, library.canShare(id: drop.id) else {
            shareError = DropPermissionError.cannotShare.localizedDescription
            return
        }
        // Round 4 (flows-3): never present the activity sheet for a drop the
        // app already KNOWS can't upload — a confidently shared dead link is
        // worse than an error. Round 6 (counsel sync-4): the refusal is no
        // longer a dead end — it kicks a background revalidation so a verdict
        // that no longer holds (e.g. after account relinking) can clear.
        guard !library.terminalSyncFailureIDs.contains(drop.id) else {
            shareError = library.syncFailureReasons[drop.id]
                ?? "This drop can't upload from this account connection"
            // Round 8 (counsel B6) + round 10 (counsel flows-3): revalidation
            // is BY ID — the library resolves the persisted row itself, so no
            // stale or mutated snapshot can ever be republished.
            library.retrySync(id: drop.id)
            return
        }
        do {
            // Persists locally (throws on failure) and enqueues the
            // server-acknowledged cloud upload (tracked in pendingSyncIDs).
            let saved = try await library.share(id: drop.id, recipientName: recipientName)
            guard account.uid == accountUID, library.canShare(id: drop.id) else {
                throw DropPermissionError.ownershipChanged
            }
            preparedShare = saved
            shareError = nil
            showShareSheet = true
        } catch {
            // Wave C SWE-14: never hand out a link for a share that didn't save.
            shareError = "Couldn't save the share — \(error.localizedDescription)"
        }
    }
}

/// UIKit share sheet bridge.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
