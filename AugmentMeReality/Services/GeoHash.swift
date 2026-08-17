import CoreLocation
import Foundation

/// Geohash encoding + query-bounds for Firestore geo-queries (ADR-039).
/// Firestore has no native geo index; the standard pattern (GeoFire) stores a
/// geohash per document and queries prefix ranges covering the search circle.
/// Self-contained (~100 lines) — no dependency needed.
enum GeoHash {
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")
    private static let base32Lookup: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (i, c) in base32.enumerated() { map[c] = i }
        return map
    }()

    /// Encode a coordinate to a geohash of the given precision (characters).
    static func encode(
        latitude: Double, longitude: Double, precision: Int = 9
    ) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bit = 0
        var index = 0
        var evenBit = true
        while hash.count < precision {
            if evenBit {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid { index = index * 2 + 1; lonRange.0 = mid }
                else { index *= 2; lonRange.1 = mid }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid { index = index * 2 + 1; latRange.0 = mid }
                else { index *= 2; latRange.1 = mid }
            }
            evenBit.toggle()
            bit += 1
            if bit == 5 {
                hash.append(base32[index])
                bit = 0
                index = 0
            }
        }
        return hash
    }

    /// Center of a geohash cell (for tests and coarse display).
    static func decode(_ hash: String) -> CLLocationCoordinate2D? {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var evenBit = true
        for character in hash.lowercased() {
            guard let value = base32Lookup[character] else { return nil }
            for shift in stride(from: 4, through: 0, by: -1) {
                let bit = (value >> shift) & 1
                if evenBit {
                    let mid = (lonRange.0 + lonRange.1) / 2
                    if bit == 1 { lonRange.0 = mid } else { lonRange.1 = mid }
                } else {
                    let mid = (latRange.0 + latRange.1) / 2
                    if bit == 1 { latRange.0 = mid } else { latRange.1 = mid }
                }
                evenBit.toggle()
            }
        }
        return CLLocationCoordinate2D(
            latitude: (latRange.0 + latRange.1) / 2,
            longitude: (lonRange.0 + lonRange.1) / 2
        )
    }

    /// Approximate cell height (meters) per precision — for picking a precision
    /// whose cells are at least as large as the search radius.
    private static let cellHeightMeters: [Double] = [
        5_009_400, 626_170, 156_540, 19_570, 4_890, 611, 153, 19.1, 4.77, 0.596
    ]

    /// Prefix ranges covering a search circle: the center cell + its 8 neighbors
    /// at a precision where one cell spans the radius. Query each range as
    /// `geohash >= start && geohash < end`.
    static func queryBounds(
        center: CLLocationCoordinate2D, radiusMeters: Double
    ) -> [(start: String, end: String)] {
        var precision = 1
        for (index, height) in cellHeightMeters.enumerated()
        where height >= radiusMeters * 2 {
            precision = index + 1
        }
        precision = min(max(precision, 1), 9)
        let centerHash = encode(
            latitude: center.latitude, longitude: center.longitude, precision: precision
        )
        var cells = Set([centerHash])
        for cell in neighbors(of: centerHash) { cells.insert(cell) }
        return cells.sorted().map { ($0, $0 + "~") } // '~' > every base32 char
    }

    /// The 8 surrounding cells, via decode-shift-encode (simple and correct at
    /// non-polar latitudes — our use is street-scale).
    static func neighbors(of hash: String) -> [String] {
        guard let center = decode(hash), !hash.isEmpty else { return [] }
        let precision = hash.count
        // Cell size from the bit split: lon bits = ceil(5p/2), lat bits = floor.
        let totalBits = precision * 5
        let lonBits = (totalBits + 1) / 2
        let latBits = totalBits / 2
        let latSize = 180.0 / pow(2.0, Double(latBits))
        let lonSize = 360.0 / pow(2.0, Double(lonBits))
        var result: [String] = []
        for dLat in [-1.0, 0.0, 1.0] {
            for dLon in [-1.0, 0.0, 1.0] where !(dLat == 0 && dLon == 0) {
                let lat = min(max(center.latitude + dLat * latSize, -90), 90)
                var lon = center.longitude + dLon * lonSize
                if lon > 180 { lon -= 360 }
                if lon < -180 { lon += 360 }
                result.append(encode(latitude: lat, longitude: lon, precision: precision))
            }
        }
        return result
    }
}
