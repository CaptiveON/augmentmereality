import CoreLocation
import MapKit
import SwiftUI

struct MapScreen: View {
    @EnvironmentObject private var library: DropLibrary
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var arHolder: ARSessionHolder
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var account: AccountService

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var searchText = ""
    @State private var searchedPlace: SearchedPlace?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var actionError: String?
    /// ADR-041: real imagery for precise pinning ("the gate", not "the street").
    @State private var satellite = false

    struct SearchedPlace: Identifiable {
        let id = UUID()
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    UserAnnotation()

                    ForEach(library.drops) { drop in
                        Annotation(drop.title, coordinate: drop.coordinate) {
                            DropMapBadge(drop: drop)
                                .contextMenu {
                                    if library.ownershipRole(id: drop.id) == .owned {
                                        Button(role: .destructive) {
                                            Task {
                                                do {
                                                    try await library.removeOwned(id: drop.id)
                                                    actionError = nil
                                                } catch {
                                                    actionError = error.localizedDescription
                                                }
                                            }
                                        } label: {
                                            Label("Delete your drop", systemImage: "trash")
                                        }
                                    } else if library.canRemoveLocalCopy(id: drop.id) {
                                        Button(role: .destructive) {
                                            Task {
                                                do {
                                                    try await library.removeLocalCopy(id: drop.id)
                                                    actionError = nil
                                                } catch {
                                                    actionError = error.localizedDescription
                                                }
                                            }
                                        } label: {
                                            Label("Remove local copy", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }

                    if let place = searchedPlace {
                        Annotation(place.name, coordinate: place.coordinate) {
                            Button {
                                router.beginCreate(at: place.coordinate)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(.white, .green)
                                    Text("Place here")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.green, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }
                .mapStyle(satellite
                    ? .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
                    : .standard(elevation: .flat))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 10) {
                        Button {
                            satellite.toggle()
                        } label: {
                            Image(systemName: satellite ? "map.fill" : "globe.americas.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(.regularMaterial, in: Circle())
                        }
                        // ADR-048: camera is presented, not a tab — the map
                        // offers the viewfinder for "see what's around me".
                        Button {
                            router.showCamera = true
                        } label: {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(.regularMaterial, in: Circle())
                        }
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, 96)
                }
                .onTapGesture { screenPoint in
                    guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                    // ADR-050: a tapped spot enters the create ritual pre-pinned.
                    router.beginCreate(at: coordinate)
                }
            }
            .navigationTitle("Pin a surprise")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { searchBar }
            .safeAreaInset(edge: .bottom) { hintBar }
            .task(id: locationService.location == nil) {
                await library.refresh(near: locationService.location)
            }
            .onAppear {
                // ADR-043: warm everything EXCEPT the camera — no green dot
                // until the user actually asks for the viewfinder.
                arHolder.warmWithoutCamera()
            }
            .onChange(of: account.uid) { _, _ in actionError = nil }
        }
    }

    private var searchBar: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search an address or place…", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                if isSearching {
                    ProgressView()
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchedPlace = nil
                        searchError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.top, 4)
    }

    private var hintBar: some View {
        Text(library.drops.isEmpty
             ? "Search your friend's address or tap the map to pin a 3D surprise 🎁"
             : "Tap anywhere on the map to pin another drop")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 6)
    }

    private func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let userCoordinate = locationService.location?.coordinate {
            request.region = MKCoordinateRegion(
                center: userCoordinate,
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                searchError = "No place found for “\(query)”"
                return
            }
            let coordinate = item.placemark.coordinate
            searchedPlace = SearchedPlace(
                name: item.name ?? query,
                coordinate: coordinate
            )
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 300,
                    longitudinalMeters: 300
                ))
            }
        } catch {
            searchError = "Search failed: \(error.localizedDescription)"
        }
    }
}

struct DropMapBadge: View {
    let drop: GeoDrop

    var body: some View {
        Image(systemName: drop.content.symbolName)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(8)
            .background(drop.color.gradient, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(radius: 3)
    }
}

#Preview {
    MapScreen()
        .environmentObject(DropLibrary())
        .environmentObject(LocationService())
}
