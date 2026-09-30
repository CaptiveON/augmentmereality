import Foundation

/// The saved inputs that define a geographic anchor. Comparing this value
/// catches a remote change before an existing terrain, roof or absolute anchor
/// is reused with yesterday's coordinate or vertical meaning.
struct GeographicAnchorIntent: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let heightAboveGround: Double
    private let heightWasFinite: Bool
    let facingDegrees: Double?
    let preferredAnchorMode: String
    let verticalReference: String
    let requiresVerticalResolutionBeforeAnchor: Bool
    let usableSupportAltitudeMeters: Double?
    let supportAltitudeDatum: String?

    init(_ drop: GeoDrop) {
        latitude = drop.latitude
        longitude = drop.longitude
        // NaN is unequal to itself. Canonicalize only the intent key so an
        // unchanged damaged row cannot invalidate its old state every tick.
        let finiteHeight = drop.heightAboveGround.isFinite
        heightWasFinite = finiteHeight
        heightAboveGround = finiteHeight ? drop.heightAboveGround : 0
        facingDegrees = drop.facingDegrees
        preferredAnchorMode = drop.preferredAnchorMode
        verticalReference = drop.verticalReference
        requiresVerticalResolutionBeforeAnchor = drop.requiresVerticalResolutionBeforeAnchor
        usableSupportAltitudeMeters = drop.verticalPlacement?.usableResolvedSupportAltitudeMeters
        supportAltitudeDatum = usableSupportAltitudeMeters == nil
            ? nil : drop.verticalPlacement?.verticalDatum
    }

    private var hasSupportedOffset: Bool {
        heightWasFinite
            && GeoDrop.supportedHeightRange.contains(heightAboveGround)
    }

    /// ARGeoAnchor without altitude resolves terrain only. Legacy ground rows
    /// keep their old route; an explicit unknown reference never gains one.
    var allowsTerrainGeoAnchor: Bool {
        hasSupportedOffset && !requiresVerticalResolutionBeforeAnchor
            && preferredAnchorMode == "ground"
            && verticalReference != VerticalPlacement.Reference.localSupport
    }

    /// Local support needs the absolute WGS84 anchor API. It must not silently
    /// fall back to a terrain or rooftop anchor if its altitude is missing.
    var requiresAbsoluteVPS: Bool {
        hasSupportedOffset
            && verticalReference == VerticalPlacement.Reference.localSupport
            && usableSupportAltitudeMeters != nil
            && supportAltitudeDatum == VerticalPlacement.Datum.wgs84Ellipsoid
    }

    var allowsRooftopVPS: Bool {
        hasSupportedOffset && !requiresVerticalResolutionBeforeAnchor
            && verticalReference != VerticalPlacement.Reference.localSupport
            && preferredAnchorMode == "rooftop"
    }

    var allowsTerrainVPS: Bool { allowsTerrainGeoAnchor }

    var canRequestVPSAnchor: Bool {
        requiresAbsoluteVPS || allowsRooftopVPS || allowsTerrainVPS
    }

    var absoluteAltitudeMeters: Double? {
        guard requiresAbsoluteVPS, heightAboveGround.isFinite,
              let support = usableSupportAltitudeMeters else { return nil }
        let altitude = support + heightAboveGround
        return altitude.isFinite ? altitude : nil
    }
}
