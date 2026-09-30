import FirebaseFirestore
import XCTest
@testable import AugmentMeReality

final class GeographicPersistenceTests: XCTestCase {
    func testFirestoreValueCodecPreservesGeographicEvidence() throws {
        var drop = GeoDrop(latitude: 51.5, longitude: -0.12)
        // Use an exactly representable timestamp: the SDK's nanosecond
        // timestamp conversion need not preserve Date()'s sub-microsecond bits.
        drop.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        drop.geographicQuality = GeographicQuality(
            source: GeographicQuality.Source.vpsProjection,
            sensorHorizontalAccuracyMeters: 1,
            cameraHorizontalAccuracyMeters: 1,
            yawAccuracyDegrees: 2,
            projectionDistanceMeters: 5,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // Exercise the real SDK value codec, whose timestamp representation
        // differs from JSON. This makes no network request or Firebase app.
        let fields = try Firestore.Encoder().encode(drop)
        let restored = try Firestore.Decoder().decode(GeoDrop.self, from: fields)
        XCTAssertEqual(restored.geographicQuality, drop.geographicQuality)
        XCTAssertEqual(restored, drop)
        XCTAssertEqual(restored.geographicQuality?.measuredAt, drop.geographicQuality?.measuredAt)
    }

    func testLocalRelaunchPreservesQualityAndManualEditReplacesClaim() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drops.json")
        var drop = GeoDrop(latitude: 51.5, longitude: -0.12)
        drop.geographicQuality = GeographicQuality(
            source: GeographicQuality.Source.vpsProjection,
            sensorHorizontalAccuracyMeters: 1,
            cameraHorizontalAccuracyMeters: 1,
            yawAccuracyDegrees: 2,
            projectionDistanceMeters: 5,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await LocalDropStore(fileURL: url).save(drop)
        let restored = try await LocalDropStore(fileURL: url).loadDrops(near: nil, radius: 0)
        XCTAssertEqual(restored, [drop])

        drop.latitude += 0.001
        drop.geographicQuality = GeographicQuality(source: GeographicQuality.Source.mapSelection)
        try await LocalDropStore(fileURL: url).save(drop)
        let moved = try await LocalDropStore(fileURL: url).loadDrops(near: nil, radius: 0)
        XCTAssertEqual(moved, [drop])
        XCTAssertNil(moved.first?.geographicQuality?.horizontalEstimateMeters)
    }

    func testMalformedOptionalQualityDoesNotBecomeLostContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("drops.json")
        let id = UUID()
        try Data("""
        [{"id":"\(id.uuidString)","message":"Still readable",
          "latitude":51.5,"longitude":-0.12,"geographicQuality":"damaged"}]
        """.utf8).write(to: url)
        let store = LocalDropStore(fileURL: url)
        let drops = try await store.loadDrops(near: nil, radius: 0)
        XCTAssertEqual(drops.map(\.id), [id])
        XCTAssertEqual(drops.first?.message, "Still readable")
        XCTAssertNil(drops.first?.geographicQuality)
        let incident = await store.lastStorageIncident()
        XCTAssertNil(incident)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
