import Foundation

/// The saved vertical *meaning* of a drop. `GeoDrop.heightAboveGround` remains
/// the offset above this support, in metres. A local AR world-space Y is never
/// a geographic altitude and must not be written to this value.
struct VerticalPlacement: Codable, Equatable, Hashable, Sendable {
    enum Reference {
        static let unresolved = "unresolved"
        static let terrain = "terrain"
        static let rooftop = "rooftop"
        static let localSupport = "localSupport"
    }

    enum Datum {
        /// WGS84 ellipsoid height, in metres. No geoid conversion is implied.
        static let wgs84Ellipsoid = "wgs84Ellipsoid"
    }

    enum Provenance {
        static let vpsProjection = "vpsProjection"
        static let geographicSensor = "geographicSensor"
        static let surveyed = "surveyed"
        static let localARRaycast = "localARRaycast"
    }

    /// Strings preserve newer writers' values without granting them semantics
    /// that this version of the app does not understand.
    var reference: String
    var resolvedSupportAltitudeMeters: Double?
    var verticalDatum: String?
    var verticalUncertaintyMeters: Double?
    var measuredAt: Date?
    var provenance: String?

    init(
        reference: String = Reference.unresolved,
        resolvedSupportAltitudeMeters: Double? = nil,
        verticalDatum: String? = nil,
        verticalUncertaintyMeters: Double? = nil,
        measuredAt: Date? = nil,
        provenance: String? = nil
    ) {
        self.reference = reference
        self.resolvedSupportAltitudeMeters = resolvedSupportAltitudeMeters
        self.verticalDatum = verticalDatum
        self.verticalUncertaintyMeters = verticalUncertaintyMeters
        self.measuredAt = measuredAt
        self.provenance = provenance
        sanitize()
    }

    private enum CodingKeys: String, CodingKey {
        case reference, resolvedSupportAltitudeMeters, verticalDatum
        case verticalUncertaintyMeters, measuredAt, provenance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reference = (try? c.decode(String.self, forKey: .reference)) ?? Reference.unresolved
        resolvedSupportAltitudeMeters = try? c.decode(Double.self, forKey: .resolvedSupportAltitudeMeters)
        verticalDatum = try? c.decode(String.self, forKey: .verticalDatum)
        verticalUncertaintyMeters = try? c.decode(Double.self, forKey: .verticalUncertaintyMeters)
        measuredAt = try? c.decode(Date.self, forKey: .measuredAt)
        provenance = try? c.decode(String.self, forKey: .provenance)
        sanitize()
    }

    private mutating func sanitize() {
        if reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reference = Reference.unresolved
        }
        if let altitude = resolvedSupportAltitudeMeters,
           !altitude.isFinite || abs(altitude) > 20_000 {
            resolvedSupportAltitudeMeters = nil
        }
        if let uncertainty = verticalUncertaintyMeters,
           !uncertainty.isFinite || uncertainty <= 0 {
            verticalUncertaintyMeters = nil
        }
        if let date = measuredAt, !date.timeIntervalSince1970.isFinite {
            measuredAt = nil
        }
        if let datum = verticalDatum,
           datum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            verticalDatum = nil
        }
        if let provenance = provenance,
           provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.provenance = nil
        }
    }

    /// Only a known datum and geographic source permit altitude arithmetic.
    /// An AR plane/mesh height remains a session-local support measurement even
    /// if it is associated with a saved latitude/longitude.
    var usableResolvedSupportAltitudeMeters: Double? {
        guard reference == Reference.terrain || reference == Reference.rooftop
                || reference == Reference.localSupport,
              verticalDatum == Datum.wgs84Ellipsoid,
              let source = provenance,
              [Provenance.vpsProjection, Provenance.geographicSensor,
               Provenance.surveyed].contains(source),
              let date = measuredAt, date.timeIntervalSince1970.isFinite,
              let uncertainty = verticalUncertaintyMeters,
              uncertainty.isFinite, uncertainty > 0, uncertainty <= 3,
              let altitude = resolvedSupportAltitudeMeters,
              altitude.isFinite, abs(altitude) <= 20_000 else { return nil }
        return altitude
    }

    var knownReference: String {
        switch reference {
        case Reference.terrain, Reference.rooftop, Reference.localSupport:
            return reference
        default:
            return Reference.unresolved
        }
    }
}
