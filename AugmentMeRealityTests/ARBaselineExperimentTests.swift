import XCTest
@testable import AugmentMeReality

final class ARBaselineExperimentTests: XCTestCase {
    func testEnvironmentAloneCannotChangeShippingDefaults() {
        let options = ARBaselineExperiment(arguments: ["-ARBaselineMetrics"], environment: [
            "AR_BASELINE_DISABLE": "reconstruction,localization,neuralDepth",
            "AR_BASELINE_DELAYED_ASSET": "heavy", "AR_BASELINE_ASSET_DELAY_SECONDS": "10"
        ])
        XCTAssertTrue(ARBaselineExperiment.Subsystem.allCases.allSatisfy(options.allows))
        XCTAssertEqual(options.delay(for: "heavy"), 0)
    }

    func testExperimentDoesNotDependOnRecorderBeingEnabled() {
        let options = ARBaselineExperiment(arguments: ["-ARBaselineExperiment"], environment: [
            "AR_BASELINE_DISABLE": "reconstruction, neuralDepth",
            "AR_BASELINE_DELAYED_ASSET": "heavy", "AR_BASELINE_ASSET_DELAY_SECONDS": "3"
        ])
        XCTAssertFalse(options.allows(.reconstruction))
        XCTAssertFalse(options.allows(.neuralDepth))
        XCTAssertTrue(options.allows(.localization))
        XCTAssertEqual(options.delay(for: "heavy"), 3)
        XCTAssertEqual(options.delay(for: "another"), 0)
    }

    func testInvalidExperimentIsIdentifiedAndRetainsDefaults() {
        for value in ["-1", "11", "nan", "inf", "typo"] {
            let options = ARBaselineExperiment(arguments: ["-ARBaselineExperiment"], environment: [
                "AR_BASELINE_DISABLE": "reconstruction,typo",
                "AR_BASELINE_ASSET_DELAY_SECONDS": value
            ])
            XCTAssertFalse(options.invalidOptions.isEmpty)
            XCTAssertTrue(options.allows(.reconstruction))
            XCTAssertEqual(options.delay(for: "heavy"), 0)
        }
    }
}
