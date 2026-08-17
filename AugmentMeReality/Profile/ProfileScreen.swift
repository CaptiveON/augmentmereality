import SwiftUI

/// Wave 6.1 profile v1 — the trophy shelf's skeleton (PRODUCT-ROUTE §3A).
/// Identity + editable name/handle + headline stats. The Moments grid and the
/// full visual language arrive with Wave 6.2's design implementation.
struct ProfileScreen: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var library: DropLibrary

    @State private var editing = false
    @State private var draftName = ""
    @State private var draftHandle = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 1, green: 0.30, blue: 0.43),
                                                 Color(red: 1, green: 0.78, blue: 0.34)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 64, height: 64)
                            Text(account.profile?.monogram ?? "☺︎")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.profile?.displayName ?? "Setting up…")
                                .font(.headline)
                            Text("@\(account.profile?.handle ?? "…")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") {
                            draftName = account.profile?.displayName ?? ""
                            draftHandle = account.profile?.handle ?? ""
                            editing = true
                        }
                        .disabled(account.profile == nil)
                    }
                    .padding(.vertical, 4)
                }

                Section("Moments") {
                    statRow(
                        icon: "gift.fill", tint: .pink,
                        title: "Moments delivered",
                        value: account.profile?.momentsDelivered ?? 0
                    )
                    statRow(
                        icon: "heart.fill", tint: .red,
                        title: "Reactions received",
                        value: account.profile?.reactionsReceived ?? 0
                    )
                    statRow(
                        icon: "mappin.and.ellipse", tint: .mint,
                        title: "Active drops",
                        value: library.drops.count
                    )
                }

                Section {
                    if AppConfig.firebaseConfigured {
                        // Wave C (counsel PBS-4): "Synced" means the SERVER
                        // acknowledged every write — never "we have a config
                        // file". Round 8 (counsel B4): the good state needs
                        // POSITIVE evidence — problems outrank progress,
                        // progress outranks unknown, and "Synced" is earned
                        // only past a completed clean refresh, never reached
                        // by falling through.
                        // Round 14 (counsel seams-1 tail): the problem rungs
                        // come FIRST — a stalled sign-in ("Connecting…") must
                        // never hide a real, uid-independent problem.
                        if !library.terminalSyncFailureIDs.isEmpty {
                            // Round 4 (sync-1): terminal failures OUTRANK
                            // "Synced" — a drop that can never upload again is
                            // a problem, not progress, and never silence.
                            Label(
                                "\(library.terminalSyncFailureIDs.count) drop\(library.terminalSyncFailureIDs.count == 1 ? "" : "s") can't sync from this account connection",
                                systemImage: "xmark.icloud"
                            )
                            .foregroundStyle(.orange)
                            .font(.footnote)
                        } else if !library.unresolvedDeleteIDs.isEmpty {
                            // Round 8 (counsel ux-3): a durable give-up state
                            // with no surface anywhere was silent data
                            // divergence — the server copy stays live while
                            // the app reports all-clear.
                            Label(
                                "\(library.unresolvedDeleteIDs.count) deletion\(library.unresolvedDeleteIDs.count == 1 ? "" : "s") couldn't finish — the cloud copy may still exist",
                                systemImage: "xmark.icloud"
                            )
                            .foregroundStyle(.orange)
                            .font(.footnote)
                        } else if library.localReadWarning != nil {
                            // Round 8 (counsel flows-6): while the library
                            // can't read its own truth, no positive claim.
                            // Round 12 (counsel SURF-lens-5): and no FALSE
                            // claim either — sync of readable drops proceeds.
                            Label(
                                "Some saved drops couldn't be read",
                                systemImage: "exclamationmark.icloud"
                            )
                            .foregroundStyle(.orange)
                            .font(.footnote)
                        } else if account.uid == nil {
                            Label("Connecting…", systemImage: "icloud.slash")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        } else if library.hasCompletedCleanRefresh,
                                  library.unpushablePendingCount > 0 {
                            // Round 8 (counsel ux-4): pending writes whose row
                            // can't be loaded are a PROBLEM count — round 6
                            // removed them from progress; removing them from
                            // every surface made them silent. Round 10: the
                            // claim is made only from a KNOWN state — before
                            // the first clean refresh the rows simply haven't
                            // loaded yet, and the ladder says "checking".
                            Label(
                                "\(library.unpushablePendingCount) change\(library.unpushablePendingCount == 1 ? "" : "s") can't upload — the saved copy couldn't be read",
                                systemImage: "exclamationmark.icloud"
                            )
                            .foregroundStyle(.orange)
                            .font(.footnote)
                        } else if let error = library.lastSyncError {
                            Label("Sync issue — \(error)", systemImage: "exclamationmark.icloud")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                        } else if library.uploadingCount > 0 {
                            // Round 6: counts only drops that can actually be
                            // pushed (counsel flows-5) — and deletions are OUT
                            // of the ladder entirely: the user considers a
                            // deleted drop deleted; background cleanup must
                            // not block a positive status (round-5 researcher).
                            Label(
                                "Uploading \(library.uploadingCount) drop\(library.uploadingCount == 1 ? "" : "s")…",
                                systemImage: "arrow.triangle.2.circlepath.icloud"
                            )
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                        } else if !library.lostRowIDs.isEmpty {
                            // Round 14 (counsel surf-lens-2/own-1): the
                            // permanent loss record — OUTRANKS "Synced". A
                            // destroyed drop must leave a trace the reap,
                            // the banner dismissal and the evidence latch
                            // cannot erase; only the user clears it.
                            HStack {
                                Label(
                                    "\(library.lostRowIDs.count) drop\(library.lostRowIDs.count == 1 ? " was" : "s were") lost to a storage problem",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .foregroundStyle(.orange)
                                .font(.footnote)
                                Spacer()
                                Button("Clear") { library.acknowledgeLosses() }
                                    .font(.footnote.bold())
                            }
                        } else if !library.hasCompletedCleanRefresh {
                            // Round 8 (counsel B4): the honest cold-start state.
                            // Before a refresh has completed cleanly the app
                            // does not KNOW — and says so.
                            Label("Checking sync status…", systemImage: "icloud")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        } else {
                            Label(
                                "Synced — the server has confirmed your drops",
                                systemImage: "checkmark.icloud"
                            )
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                        }
                    } else {
                        Label(
                            "Cloud sync is off — add GoogleService-Info.plist (see README)",
                            systemImage: "icloud.slash"
                        )
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    }
                    if let status = account.statusText {
                        Text(status).font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Captures of opened drops appear here from Wave 6.2 — nothing is ever shared without you choosing to.")
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $editing) {
                NavigationStack {
                    Form {
                        TextField("Display name", text: $draftName)
                        TextField("Handle", text: $draftHandle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .navigationTitle("Edit profile")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let name = draftName, handle = draftHandle
                                Task { await account.updateProfile(displayName: name, handle: handle) }
                                editing = false
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editing = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func statRow(icon: String, tint: Color, title: String, value: Int) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 26)
            Text(title)
            Spacer()
            Text("\(value)")
                .font(.headline.monospacedDigit())
        }
    }
}
