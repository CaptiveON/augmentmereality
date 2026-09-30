import CoreLocation
import Foundation
import SwiftUI

/// A piece of virtual 3D content pinned to a real-world coordinate. Stored
/// fields are values; UI colors and locations are derived on the caller's side.
struct GeoDrop: Identifiable, Codable, Equatable, Hashable, Sendable {
    enum Content: String, Codable, CaseIterable, Identifiable, Sendable {
        case text3D
        case balloons
        case gift
        case heart
        case beacon
        /// A bundled animated USDZ model (ADR-021); `assetName` picks which one.
        case animated
        /// ADR-046 Tier-1 procedural hero: particle fireworks show (0 MB).
        case fireworks

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .text3D: return "3D Text"
            case .balloons: return "Balloons"
            case .gift: return "Gift Box"
            case .heart: return "Heart"
            case .beacon: return "Beacon"
            case .animated: return "Animated 3D"
            case .fireworks: return "Fireworks show"
            }
        }

        var symbolName: String {
            switch self {
            case .text3D: return "textformat"
            case .balloons: return "balloon.2.fill"
            case .gift: return "gift.fill"
            case .heart: return "heart.fill"
            case .beacon: return "mappin.and.ellipse"
            case .animated: return "cube.transparent"
            case .fireworks: return "fireworks"
            }
        }
    }

    var id: UUID = UUID()
    var content: Content = .text3D
    /// The text rendered for `.text3D`; a caption for everything else.
    var message: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    /// How this saved coordinate was authored and its estimated geographic
    /// uncertainty. Nil on legacy rows means unknown, never precise by default.
    var geographicQuality: GeographicQuality? = nil
    /// Offset above the selected terrain, roof or local support (metres).
    var heightAboveGround: Double = 2
    /// Display/geometry bound for damaged external rows. The stored authored
    /// value stays intact; geographic anchor admission checks that raw value.
    static let supportedHeightRange: ClosedRange<Double> = -2...20
    var presentationHeightAboveGround: Double {
        guard heightAboveGround.isFinite else { return 0 }
        return min(max(heightAboveGround, Self.supportedHeightRange.lowerBound),
                   Self.supportedHeightRange.upperBound)
    }
    /// Vertical support and optional geographic altitude. Nil on legacy rows:
    /// their reference is explicitly unresolved until measured or reauthored.
    var verticalPlacement: VerticalPlacement? = nil
    /// 1.0 = default size (3D text ≈ 0.6 m tall letters).
    var scale: Double = 1
    /// Compass bearing the content's front faces (degrees, 0 = north), chosen by
    /// the creator. `nil` = auto: face wherever the viewer first sees it from.
    var facingDegrees: Double?
    /// Bundled USDZ name (without extension) for `.animated` content.
    var assetName: String?
    var colorHex: String = "#FF4D6D"
    var createdBy: String = "Someone"
    var createdAt: Date = Date()
    /// Wave 6.2 sharing: "private" | "link" | "public" (cloud reads gate on it).
    var visibility: String = "private"
    /// ADR-042: "ground" | "rooftop". Rooftop drops resolve against Google's 3D
    /// building model — `heightAboveGround` then means height above the ROOF.
    var anchorMode: String = "ground"

    var isRooftop: Bool { preferredAnchorMode == "rooftop" }
    var verticalReference: String {
        verticalPlacement?.knownReference ?? VerticalPlacement.Reference.unresolved
    }

    /// A present but unknown reference is newer or damaged metadata. Keep it
    /// readable, but do not silently reinterpret that support as terrain.
    var requiresVerticalResolutionBeforeAnchor: Bool {
        verticalPlacement != nil
            && verticalReference == VerticalPlacement.Reference.unresolved
    }

    /// A known saved reference takes precedence. Legacy and local-only support
    /// keep the old terrain/rooftop anchor route, without claiming that an old
    /// row had a measured support or a geographic altitude.
    var preferredAnchorMode: String {
        switch verticalReference {
        case VerticalPlacement.Reference.rooftop: return "rooftop"
        case VerticalPlacement.Reference.terrain: return "ground"
        default: return anchorMode == "rooftop" ? "rooftop" : "ground"
        }
    }
    /// Creator's Firebase UID (set by the cloud store; nil on legacy/local drops).
    var ownerUid: String?
    /// Who this drop is for — shown in the share/receive flow.
    var recipientName: String?

    /// True when this device opened the drop via a magic link (viewer role:
    /// reaction bar instead of edit tools). Local-only, not synced.
    var receivedViaLink: Bool? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var uiColor: UIColor { UIColor(hex: colorHex) ?? .systemPink }
    var color: Color { Color(uiColor: uiColor) }

    /// Short label used on the map and in lists.
    var title: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return content.displayName }
        return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
    }
}

extension GeoDrop {
    /// AUDIT P0 (2026-07-09): synthesized decoding REQUIRES every non-optional
    /// key even when the property has a default — so adding fields (visibility,
    /// anchorMode, …) made pre-update JSON throw, and the corrupt-quarantine
    /// then silently emptied the user's library. Every field decodes with a
    /// default so old data — local or cloud — always survives an app update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // Raw-string decode so a FUTURE content type from a newer client never
        // fails the whole library decode (same P0 class as missing keys).
        let contentRaw = try c.decodeIfPresent(String.self, forKey: .content)
        content = contentRaw.flatMap(Content.init(rawValue:)) ?? .text3D
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude) ?? 0
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) ?? 0
        geographicQuality = try? c.decodeIfPresent(GeographicQuality.self, forKey: .geographicQuality)
        heightAboveGround = try c.decodeIfPresent(Double.self, forKey: .heightAboveGround) ?? 2
        // Missing/null is a legacy row. A present but damaged value is a
        // different case: keep the drop readable without granting its old
        // terrain/roof anchorMode authority over an unknown support.
        if c.contains(.verticalPlacement),
           (try? c.decodeNil(forKey: .verticalPlacement)) != true {
            verticalPlacement = (try? c.decode(VerticalPlacement.self, forKey: .verticalPlacement))
                ?? VerticalPlacement(reference: VerticalPlacement.Reference.unresolved)
        } else {
            verticalPlacement = nil
        }
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        facingDegrees = try c.decodeIfPresent(Double.self, forKey: .facingDegrees)
        assetName = try c.decodeIfPresent(String.self, forKey: .assetName)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FF4D6D"
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? "Someone"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "private"
        anchorMode = try c.decodeIfPresent(String.self, forKey: .anchorMode) ?? "ground"
        ownerUid = try c.decodeIfPresent(String.self, forKey: .ownerUid)
        recipientName = try c.decodeIfPresent(String.self, forKey: .recipientName)
        receivedViaLink = try c.decodeIfPresent(Bool.self, forKey: .receivedViaLink)
    }
}

extension UIColor {
    /// Parses "#RRGGBB" (leading # optional).
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
