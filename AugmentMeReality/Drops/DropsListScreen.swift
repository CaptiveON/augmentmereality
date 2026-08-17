import CoreLocation
import SwiftUI

struct DropsListScreen: View {
    @EnvironmentObject private var library: DropLibrary
    @EnvironmentObject private var locationService: LocationService

    @State private var sharingDrop: GeoDrop?

    var body: some View {
        NavigationStack {
            // Wave C round 2 (C12): the banners live ABOVE the empty/list
            // split — a fully unreadable library must never show a cheerful
            // "No drops yet" with the loss invisible.
            VStack(spacing: 0) {
                banners
                content
            }
            .navigationTitle("Sent")
            .sheet(item: $sharingDrop) { drop in
                ShareDropSheet(drop: drop)
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
                || !library.terminalSyncFailureIDs.isEmpty ? 6 : 0
        )
    }

    @ViewBuilder private var content: some View {
            Group {
                if library.drops.isEmpty {
                    ContentUnavailableView(
                        "No drops yet",
                        systemImage: "sparkles",
                        description: Text("Pin your first 3D surprise from the Map tab, then walk there and open the Camera tab.")
                    )
                } else {
                    List {
                        ForEach(library.drops) { drop in
                            DropRow(
                                drop: drop,
                                viewerLocation: locationService.location,
                                cantSync: library.terminalSyncFailureIDs.contains(drop.id)
                            )
                                .swipeActions(edge: .leading) {
                                    Button {
                                        sharingDrop = drop
                                    } label: {
                                        Label("Share", systemImage: "paperplane.fill")
                                    }
                                    .tint(.pink)
                                }
                                .contextMenu {
                                    Button {
                                        sharingDrop = drop
                                    } label: {
                                        Label("Send the magic link", systemImage: "paperplane.fill")
                                    }
                                }
                        }
                        .onDelete { indexSet in
                            let doomed = indexSet.map { library.drops[$0] }
                            Task {
                                // Round 4 (sync-5): per-item outcomes — one
                                // delete's success never erases another's
                                // failure; the aggregate lands in the banner.
                                await library.remove(contentsOf: doomed)
                            }
                        }
                    }
                }
            }
    }
}

private struct DropRow: View {
    let drop: GeoDrop
    let viewerLocation: CLLocation?
    /// Round 6 (counsel flows-5): the aggregate "N can't sync" banner is only
    /// actionable when the user can see WHICH rows it means.
    var cantSync: Bool = false

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
}
