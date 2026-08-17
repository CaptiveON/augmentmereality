import CoreLocation
import MapKit
import SwiftUI

/// UI revamp slice 2 (ADR-050): the create ritual — What → Where → Wrap.
/// Replaces the settings-form composer with the approved concept's toy-shop
/// flow: pick the surprise, pin the exact spot with purpose framing, wrap it
/// with a name and a note, then straight into the share moment — one
/// continuous gesture from impulse to sent link.
struct CreateWizard: View {
    /// Explore's map tap arrives with the spot already chosen.
    var initialCoordinate: CLLocationCoordinate2D?

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: DropLibrary
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("displayName") private var displayName = ""

    private enum Step: Int { case what, spot, wrap }

    @State private var step: Step = .what
    @State private var pushEdge: Edge = .trailing

    // What
    @State private var choice: SurpriseChoice?

    // Where
    @State private var pin: CLLocationCoordinate2D?
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var satellite = true
    @State private var nudgeStep = 1.0
    @State private var rooftop = false

    // Wrap
    @State private var recipientName = ""
    @State private var message = "HAPPY BIRTHDAY!"
    @State private var colorHex = CreateWizard.palette[0]
    @State private var scale = 3.0
    @State private var heightAboveGround = 3.0
    @State private var facing: FacingChoice = .auto
    @State private var moreOptions = false

    /// The freshly placed drop → straight into the share moment.
    @State private var placedDrop: GeoDrop?
    /// Wave C (counsel SWE-14): a failed save must stop the ritual — the share
    /// sheet used to open for a drop that never reached disk.
    @State private var placeError: String?

    static let palette = [
        "#FF4D6D", "#FF9F1C", "#FFD60A", "#34C759",
        "#32ADE6", "#5E5CE6", "#BF5AF2", "#FFFFFF",
    ]

    var body: some View {
        ZStack {
            Night.bgScreen.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 8)

                ZStack {
                    switch step {
                    case .what: whatStep.transition(.push(from: pushEdge))
                    case .spot: spotStep.transition(.push(from: pushEdge))
                    case .wrap: wrapStep.transition(.push(from: pushEdge))
                    }
                }
                .frame(maxHeight: .infinity)

                bottomBar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let initialCoordinate {
                pin = initialCoordinate
                cameraPosition = .region(MKCoordinateRegion(
                    center: initialCoordinate,
                    latitudinalMeters: 140, longitudinalMeters: 140
                ))
            }
        }
        .sheet(item: $placedDrop, onDismiss: {
            router.tab = .sent
            dismiss()
        }) { drop in
            ShareDropSheet(drop: drop)
        }
        .alert(
            "Couldn't save your drop",
            isPresented: Binding(
                get: { placeError != nil },
                set: { if !$0 { placeError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(placeError ?? "")
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button {
                if step == .what {
                    dismiss()
                } else {
                    go(to: Step(rawValue: step.rawValue - 1) ?? .what)
                }
            } label: {
                Image(systemName: step == .what ? "xmark" : "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Night.inkSecondary)
                    .frame(width: 34, height: 34)
                    .background(Night.glass, in: Circle())
                    .overlay(Circle().strokeBorder(Night.lineSubtle))
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index <= step.rawValue ? Night.gold : Night.lineSubtle)
                        .frame(width: index == step.rawValue ? 18 : 7, height: 5)
                }
            }
            .animation(.spring(duration: 0.3), value: step)
            Spacer()
            // Balance the leading button so the dots stay centered.
            Color.clear.frame(width: 34, height: 34)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            NightCTA(title: ctaTitle) { advance() }
                .disabled(!canAdvance)
                .opacity(canAdvance ? 1 : 0.45)
            if step == .spot, pin != nil {
                Text(pinDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(Night.inkTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
    }

    private var ctaTitle: String {
        switch step {
        case .what: return "Choose the spot"
        case .spot: return "Wrap it up"
        case .wrap: return "Drop it 🎁"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .what: return choice != nil
        case .spot: return pin != nil
        case .wrap:
            return choice?.content != .text3D
                || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func advance() {
        switch step {
        case .what: go(to: .spot)
        case .spot: go(to: .wrap)
        case .wrap: place()
        }
    }

    private func go(to target: Step) {
        pushEdge = target.rawValue > step.rawValue ? .trailing : .leading
        withAnimation(.spring(duration: 0.35)) { step = target }
    }

    // MARK: Step 1 — What (the toy shop)

    private var whatStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stepHeader(
                    "Pick the surprise",
                    sub: "What will they walk up to?"
                )
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(SurpriseChoice.catalog) { item in
                        surpriseCard(item)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
    }

    private func surpriseCard(_ item: SurpriseChoice) -> some View {
        let selected = choice == item
        return Button {
            choice = item
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(item.accent.opacity(0.16))
                        .frame(width: 52, height: 52)
                    Image(systemName: item.symbol)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(item.accent)
                }
                Text(item.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Night.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(item.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(Night.inkTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(Night.glass, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        selected ? Night.coral : Night.lineSubtle,
                        lineWidth: selected ? 1.6 : 1
                    )
            )
            .shadow(color: selected ? Night.coral.opacity(0.35) : .clear, radius: 12)
        }
        .animation(.spring(duration: 0.25), value: choice)
    }

    // MARK: Step 2 — Where (purpose-framed map)

    private var spotStep: some View {
        VStack(spacing: 0) {
            stepHeader(
                "Where will they find it?",
                sub: "Their doorstep, a bench, the spot you met — tap the exact place."
            )
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            MapReader { proxy in
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    if let pin {
                        Annotation("", coordinate: pin) {
                            ZStack {
                                Circle().strokeBorder(Night.coral.opacity(0.55), lineWidth: 1.5)
                                    .frame(width: 40, height: 40)
                                Circle().fill(Night.coral)
                                    .frame(width: 13, height: 13)
                                    .shadow(color: Night.coral.opacity(0.9), radius: 8)
                            }
                        }
                    }
                }
                .mapStyle(satellite
                    ? .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
                    : .standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .onTapGesture { screenPoint in
                    if let coordinate = proxy.convert(screenPoint, from: .local) {
                        pin = coordinate
                    }
                }
                .overlay(alignment: .top) { searchBar.padding(10) }
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 8) {
                        mapTool(satellite ? "map.fill" : "globe.americas.fill") {
                            satellite.toggle()
                        }
                        mapTool("location.fill") { dropWhereIStand() }
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, pin == nil ? 12 : 10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Night.lineSubtle))
            .padding(.horizontal, 14)

            if pin != nil {
                pinTuner
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: pin != nil)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Night.inkTertiary)
                TextField(
                    "", text: $searchText,
                    prompt: Text("Search their address or a place…")
                        .foregroundStyle(Night.inkTertiary)
                )
                .font(.system(size: 13.5))
                .foregroundStyle(Night.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await search() } }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(Night.bgBase.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(Night.lineSubtle))

            if let searchError {
                Text(searchError)
                    .font(.system(size: 11))
                    .foregroundStyle(Night.coral)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Night.bgBase.opacity(0.9), in: Capsule())
            }
        }
    }

    private func mapTool(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Night.ink)
                .frame(width: 38, height: 38)
                .background(Night.bgBase.opacity(0.92), in: Circle())
                .overlay(Circle().strokeBorder(Night.lineSubtle))
        }
    }

    /// ADR-041: a map tap is only ±5–20 m honest — arrows walk the pin to
    /// "exactly at the gate", and rooftop drops choose the roof here too.
    private var pinTuner: some View {
        NightCard {
            HStack {
                Picker("Step", selection: $nudgeStep) {
                    Text("1 m").tag(1.0)
                    Text("25 cm").tag(0.25)
                }
                .pickerStyle(.segmented)
                .frame(width: 128)
                Spacer()
                nudgeButton("arrow.up", bearing: 0)
                nudgeButton("arrow.down", bearing: 180)
                nudgeButton("arrow.left", bearing: 270)
                nudgeButton("arrow.right", bearing: 90)
            }
            Picker("Anchors to", selection: $rooftop) {
                Text("On the ground").tag(false)
                Text("On the rooftop").tag(true)
            }
            .pickerStyle(.segmented)
            if rooftop {
                Text("Lands on the building's real roof at the pin — works where Street View exists")
                    .font(.system(size: 11))
                    .foregroundStyle(Night.inkTertiary)
            }
        }
    }

    private func nudgeButton(_ icon: String, bearing: Double) -> some View {
        Button {
            guard let current = pin else { return }
            pin = GeoMath.coordinate(
                from: current, bearingDegrees: bearing, distanceMeters: nudgeStep
            )
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Night.ink)
                .frame(width: 34, height: 30)
                .background(Night.glass, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Night.lineSubtle))
        }
        .buttonStyle(.plain)
    }

    private func dropWhereIStand() {
        guard let here = locationService.location else { return }
        pin = here.coordinate
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: here.coordinate,
                latitudinalMeters: 120, longitudinalMeters: 120
            ))
        }
    }

    private func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let here = locationService.location?.coordinate {
            request.region = MKCoordinateRegion(
                center: here, latitudinalMeters: 50_000, longitudinalMeters: 50_000
            )
        }
        do {
            guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
                searchError = "No place found for “\(query)”"
                return
            }
            pin = item.placemark.coordinate
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: item.placemark.coordinate,
                    latitudinalMeters: 160, longitudinalMeters: 160
                ))
            }
        } catch {
            searchError = "Search failed: \(error.localizedDescription)"
        }
    }

    /// Distance + compass point from the user so the pin and the blue dot can
    /// never be confused (field feedback 2026-07-07).
    private var pinDescription: String {
        guard let pin else { return "" }
        guard let here = locationService.location else {
            return String(format: "Pinned at %.5f, %.5f", pin.latitude, pin.longitude)
        }
        let target = CLLocation(latitude: pin.latitude, longitude: pin.longitude)
        let distance = target.distance(from: here)
        if distance < 10 { return "Pinned right where you're standing" }
        return String(
            format: "Pinned %@ %@ of you — they'll see it in AR at the spot",
            GeoMath.distanceLabel(distance),
            GeoMath.compassPoint(for: GeoMath.bearing(from: here.coordinate, to: pin))
        )
    }

    // MARK: Step 3 — Wrap

    private var wrapStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                stepHeader(
                    "Wrap it up",
                    sub: choice.map { "A \($0.name.lowercased()) needs a name on the tag." }
                        ?? "Almost there."
                )

                NightCard {
                    HStack(spacing: 12) {
                        NightAvatar(
                            monogram: recipientName.isEmpty
                                ? "?" : String(recipientName.prefix(1)).uppercased(),
                            warm: true
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            TextField(
                                "", text: $recipientName,
                                prompt: Text("Who is it for?").foregroundStyle(Night.inkTertiary)
                            )
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Night.ink)
                            Text("Their name shows on the tag when they open it")
                                .font(.system(size: 11))
                                .foregroundStyle(Night.inkTertiary)
                        }
                    }
                }

                NightCard {
                    Text(choice?.content == .text3D ? "YOUR MESSAGE — IT BECOMES THE 3D TEXT" : "A NOTE WITH IT (OPTIONAL)")
                        .font(Night.mono(9)).kerning(1.1)
                        .foregroundStyle(Night.inkTertiary)
                    TextField(
                        "", text: $message,
                        prompt: Text("HAPPY BIRTHDAY!").foregroundStyle(Night.inkTertiary),
                        axis: .vertical
                    )
                    .font(choice?.content == .text3D ? Night.display(19) : .system(size: 14.5))
                    .foregroundStyle(Night.ink)
                    .lineLimit(1...3)
                }

                NightCard {
                    Text("COLOR")
                        .font(Night.mono(9)).kerning(1.1)
                        .foregroundStyle(Night.inkTertiary)
                    HStack(spacing: 10) {
                        ForEach(Self.palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(uiColor: UIColor(hex: hex) ?? .white))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().strokeBorder(
                                        colorHex == hex ? Night.ink : .clear, lineWidth: 2.5
                                    )
                                )
                                .onTapGesture { colorHex = hex }
                        }
                    }
                }

                NightCard {
                    HStack {
                        Text("SIZE")
                            .font(Night.mono(9)).kerning(1.1)
                            .foregroundStyle(Night.inkTertiary)
                        Spacer()
                        Text(sizeDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(Night.inkSecondary)
                    }
                    Slider(value: $scale, in: 0.5...50, step: 0.5)
                        .tint(Night.coral)
                }

                DisclosureGroup(isExpanded: $moreOptions) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("FLOATS")
                                .font(Night.mono(9)).kerning(1.1)
                                .foregroundStyle(Night.inkTertiary)
                            Spacer()
                            Text(String(
                                format: "%.1f m above the %@",
                                heightAboveGround, rooftop ? "rooftop" : "ground"
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(Night.inkSecondary)
                        }
                        Slider(value: $heightAboveGround, in: 0...20, step: 0.5)
                            .tint(Night.coral)
                        Picker("Faces", selection: $facing) {
                            ForEach(FacingChoice.allCases) { direction in
                                Text(direction.label).tag(direction)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Night.inkSecondary)
                        TextField(
                            "", text: $displayName,
                            prompt: Text("Your name (shown as the sender)")
                                .foregroundStyle(Night.inkTertiary)
                        )
                        .font(.system(size: 13.5))
                        .foregroundStyle(Night.ink)
                    }
                    .padding(.top, 10)
                } label: {
                    Text("More options")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Night.inkSecondary)
                }
                .padding(14)
                .background(Night.glass, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Night.lineSubtle))
                .tint(Night.inkTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var sizeDescription: String {
        switch choice?.content {
        case .text3D:
            return String(format: "letters ≈ %.1f m tall", 0.6 * scale)
        case .animated:
            return String(format: "≈ %.1f m at its largest side", 1.0 * scale)
        default:
            return String(format: "≈ %.1f m across", 0.8 * scale)
        }
    }

    private func stepHeader(_ title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Night.display(23))
                .foregroundStyle(Night.ink)
            Text(sub)
                .font(.system(size: 12.5))
                .foregroundStyle(Night.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Place

    private func place() {
        guard let choice, let pin else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let drop = GeoDrop(
            content: choice.content,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: pin.latitude,
            longitude: pin.longitude,
            heightAboveGround: heightAboveGround,
            scale: scale,
            facingDegrees: facing.degrees,
            assetName: choice.assetName,
            colorHex: colorHex,
            createdBy: name.isEmpty ? "Someone" : name,
            anchorMode: rooftop ? "rooftop" : "ground",
            recipientName: recipient.isEmpty ? nil : recipient
        )
        Task {
            do {
                // Wave C SWE-14: the share moment opens only after the drop is
                // actually on disk — never for a phantom.
                try await library.add(drop)
                placedDrop = drop
            } catch {
                placeError = error.localizedDescription
            }
        }
    }
}

/// One card in the toy-shop grid: a procedural content type, or one bundled
/// animated model. `locked` is the marketplace affordance (Wave 8) — every
/// launch item ships unlocked.
struct SurpriseChoice: Identifiable, Equatable {
    let id: String
    let content: GeoDrop.Content
    let assetName: String?
    let name: String
    let caption: String
    let symbol: String
    let accent: Color
    var locked = false

    @MainActor static let catalog: [SurpriseChoice] = {
        var items: [SurpriseChoice] = [
            .init(
                id: "text3D", content: .text3D, assetName: nil,
                name: "3D Message", caption: "Your words, giant, at the spot",
                symbol: "textformat", accent: Night.gold
            ),
            .init(
                id: "fireworks", content: .fireworks, assetName: nil,
                name: "Fireworks", caption: "A show that starts as they arrive",
                symbol: "fireworks", accent: Night.coral
            ),
            .init(
                id: "balloons", content: .balloons, assetName: nil,
                name: "Balloons", caption: "A bundle floating in the air",
                symbol: "balloon.2.fill", accent: Night.mint
            ),
            .init(
                id: "gift", content: .gift, assetName: nil,
                name: "Gift Box", caption: "Wrapped and waiting",
                symbol: "gift.fill", accent: Night.indigo
            ),
            .init(
                id: "heart", content: .heart, assetName: nil,
                name: "Heart", caption: "Say it without words",
                symbol: "heart.fill", accent: Night.coral
            ),
            .init(
                id: "beacon", content: .beacon, assetName: nil,
                name: "Beacon", caption: "A glowing meet-me-here marker",
                symbol: "mappin.and.ellipse", accent: Night.gold
            ),
        ]
        let accents: [Color] = [Night.mint, Night.indigo, Night.gold, Night.coral]
        for (index, asset) in DropEntityFactory.bundledAnimatedAssets.enumerated() {
            items.append(.init(
                id: "asset:\(asset)", content: .animated, assetName: asset,
                name: asset.replacingOccurrences(of: "_", with: " "),
                caption: "Animated 3D model",
                symbol: "cube.transparent", accent: accents[index % accents.count]
            ))
        }
        return items
    }()
}

/// Which way the content's front faces at the pin.
enum FacingChoice: String, CaseIterable, Identifiable {
    case auto, n, ne, e, se, s, sw, w, nw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Toward first viewer (auto)"
        case .n: return "North"
        case .ne: return "North-East"
        case .e: return "East"
        case .se: return "South-East"
        case .s: return "South"
        case .sw: return "South-West"
        case .w: return "West"
        case .nw: return "North-West"
        }
    }

    var degrees: Double? {
        switch self {
        case .auto: return nil
        case .n: return 0
        case .ne: return 45
        case .e: return 90
        case .se: return 135
        case .s: return 180
        case .sw: return 225
        case .w: return 270
        case .nw: return 315
        }
    }
}
