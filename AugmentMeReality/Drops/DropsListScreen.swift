import CoreLocation
import SwiftUI

struct DropsListScreen: View {
    @EnvironmentObject private var library: DropLibrary
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var account: AccountService

    @State private var sharingDrop: GeoDrop?
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            // Wave C round 2 (C12): the banners live ABOVE the empty/list
            // split — a fully unreadable library must never show a cheerful
            // "No drops yet" with the loss invisible.
            VStack(spacing: 0) {
                banners
                content
            }
            .navigationTitle("Drops")
            .sheet(item: $sharingDrop) { drop in
                ShareDropSheet(drop: drop)
            }
            .onChange(of: account.uid) { _, _ in
                // The old sheet's authored intent must not survive a new
                // account connection. The sheet also guards its own command.
                sharingDrop = nil
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await library.refresh(near: locationService.location) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    /// Wave C: every failure class gets a visible banner — cloud sync, local
    /// disk, and unreadable saved rows.
    @ViewBuilder private var banners: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !library.terminalSyncFailureIDs.isEmpty {
                // Round 4 (sync-1): drops that can never upload again.
                Label(
                    "\(library.terminalSyncFailureIDs.count) drop\(library.terminalSyncFailureIDs.count == 1 ? "" : "s") can't sync from this account connection",
                    systemImage: "xmark.icloud"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let error = library.lastSyncError {
                Label(error, systemImage: "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = library.lastPersistError {
                Label(error, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let actionError {
                Label(actionError, systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let warning = library.localReadWarning {
                HStack(spacing: 8) {
                    Label(warning, systemImage: "questionmark.folder")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    // Round 6 (counsel concurrency-5): the incident is
                    // user-resolvable — an empty library must not carry an
                    // undismissable banner forever.
                    Button("Dismiss") { library.acknowledgeReadIncident() }
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(
            .vertical,
            library.lastSyncError != nil || library.lastPersistError != nil
                || library.localReadWarning != nil
                || actionError != nil
                || !library.terminalSyncFailureIDs.isEmpty ? 6 : 0
        )
    }

    private var ownedDrops: [GeoDrop] {
        library.drops.filter { library.ownershipRole(id: $0.id) == .owned }
    }

    private var receivedDrops: [GeoDrop] {
        library.drops.filter { library.ownershipRole(id: $0.id) == .received }
    }

    private var legacyDrops: [GeoDrop] {
        library.drops.filter { library.ownershipRole(id: $0.id) == .legacyLocal }
    }

    private var unresolvedDrops: [GeoDrop] {
        library.drops.filter { library.ownershipRole(id: $0.id) == .unresolved }
    }

    @ViewBuilder private var content: some View {
        if library.drops.isEmpty {
            ContentUnavailableView(
                "No drops yet",
                systemImage: "sparkles",
                description: Text("Pin your first 3D surprise from the Map tab, then walk there and open the Camera tab.")
            )
        } else {
            // Capture the rendered section once. A refresh may reorder the
            // library before SwiftUI delivers a swipe's index offsets.
            let visibleOwned = ownedDrops
            List {
                if !visibleOwned.isEmpty {
                    Section("Yours") {
                        ForEach(visibleOwned) { drop in
                            row(drop)
                                .swipeActions(edge: .leading) {
                                    Button { openShare(id: drop.id) } label: {
                                        Label("Share", systemImage: "paperplane.fill")
                                    }
                                    .tint(.pink)
                                }
                                .contextMenu {
                                    Button { openShare(id: drop.id) } label: {
                                        Label("Send the magic link", systemImage: "paperplane.fill")
                                    }
                                }
                        }
                        .onDelete { offsets in
                            // Indexes belong to THIS displayed section, never
                            // to the differently filtered full library.
                            let ids = DropListSelection.ids(in: visibleOwned, at: offsets)
                            Task { await library.removeOwned(ids: ids) }
                        }
                    }
                }

                if !receivedDrops.isEmpty {
                    Section {
                        ForEach(receivedDrops) { drop in
                            row(drop, status: "A copy from \(drop.createdBy)")
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        removeLocalCopy(id: drop.id)
                                    } label: {
                                        Label("Remove local copy", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        removeLocalCopy(id: drop.id)
                                    } label: {
                                        Label("Remove local copy", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text("Received")
                    } footer: {
                        Text("Removing a received copy does not delete the sender's drop or revoke its link.")
                    }
                }

                if !legacyDrops.isEmpty {
                    Section {
                        ForEach(legacyDrops) { drop in
                            row(drop, status: "Ownership not yet verified")
                                .contextMenu {
                                    if AppConfig.firebaseConfigured {
                                        Button {
                                            do {
                                                try library.requestLegacyOwnershipClaim(id: drop.id)
                                                actionError = nil
                                            } catch {
                                                actionError = error.localizedDescription
                                            }
                                        } label: {
                                            Label("Verify ownership", systemImage: "icloud.and.arrow.up")
                                        }
                                    }
                                    if library.canRemoveLocalCopy(id: drop.id) {
                                        Button(role: .destructive) {
                                            removeLocalCopy(id: drop.id)
                                        } label: {
                                            Label("Remove local copy", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    } header: {
                        Text("Saved locally")
                    } footer: {
                        Text("Once this drop syncs to your account, you can share or delete it as the owner.")
                    }
                }

                if !unresolvedDrops.isEmpty {
                    Section("Needs account check") {
                        ForEach(unresolvedDrops) { drop in
                            row(drop, status: "Ownership cannot be confirmed right now")
                        }
                    }
                }
            }
        }
    }

    private func row(_ drop: GeoDrop, status: String? = nil) -> some View {
        DropRow(
            drop: drop,
            viewerLocation: locationService.location,
            cantSync: library.terminalSyncFailureIDs.contains(drop.id),
            status: status
        )
    }

    private func openShare(id: UUID) {
        guard library.canShare(id: id),
              let live = library.drops.first(where: { $0.id == id }) else {
            actionError = DropPermissionError.cannotShare.localizedDescription
            return
        }
        actionError = nil
        sharingDrop = live
    }

    private func removeLocalCopy(id: UUID) {
        Task {
            do {
                try await library.removeLocalCopy(id: id)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

enum DropListSelection {
    static func ids(in displayed: [GeoDrop], at offsets: IndexSet) -> [UUID] {
        offsets.compactMap { index in
            displayed.indices.contains(index) ? displayed[index].id : nil
        }
    }
}

private struct DropRow: View {
    let drop: GeoDrop
    let viewerLocation: CLLocation?
    /// Round 6 (counsel flows-5): the aggregate "N can't sync" banner is only
    /// actionable when the user can see WHICH rows it means.
    var cantSync: Bool = false
    var status: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: drop.content.symbolName)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(drop.color.gradient, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(drop.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("by \(drop.createdBy) · \(drop.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if cantSync {
                Image(systemName: "xmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Can't sync from this account connection")
            }

            if let viewerLocation {
                let distance = drop.location.distance(from: viewerLocation)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(GeoMath.distanceLabel(distance))
                        .font(.subheadline.monospacedDigit().bold())
                    Text(GeoMath.compassPoint(
                        for: GeoMath.bearing(from: viewerLocation.coordinate, to: drop.coordinate)
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    DropsListScreen()
        .environmentObject(DropLibrary())
        .environmentObject(LocationService())
        .environmentObject(AccountService())
}
