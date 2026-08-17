import XCTest

@testable import AugmentMeReality

/// ADR-033: the power policy is the product ("hours without heat") — every rule
/// is pinned here with an injectable clock.
final class PowerGovernorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(
        cameraVisible: Bool = true,
        hasContent: Bool = true,
        inView: Bool = true,
        nearest: Float? = 20,
        vpsConverging: Bool = false,
        editing: Bool = false,
        serious: Bool = false,
        critical: Bool = false
    ) -> PowerGovernor.Inputs {
        .init(
            cameraVisible: cameraVisible,
            hasRenderedContent: hasContent,
            contentInView: inView,
            nearestRenderedDistance: nearest,
            vpsConverging: vpsConverging,
            isLiveEditing: editing,
            thermalSerious: serious,
            thermalCritical: critical
        )
    }

    func testIdleWhenCameraHiddenOrNoContent() {
        var governor = PowerGovernor()
        XCTAssertEqual(governor.evaluate(inputs(cameraVisible: false), at: t0), .idle)
        XCTAssertEqual(governor.evaluate(inputs(hasContent: false), at: t0), .idle)
    }

    func testFullWhenContentInViewNearby() {
        var governor = PowerGovernor()
        XCTAssertEqual(governor.evaluate(inputs(nearest: 20), at: t0), .full)
    }

    func testFullWhileVPSConvergingEvenOutOfView() {
        var governor = PowerGovernor()
        XCTAssertEqual(
            governor.evaluate(inputs(inView: false, vpsConverging: true), at: t0), .full
        )
    }

    func testCruiseWhenContentExistsButOutOfView() {
        var governor = PowerGovernor()
        XCTAssertEqual(governor.evaluate(inputs(inView: false, nearest: 30), at: t0), .cruise)
    }

    func testUpgradeIsImmediateDowngradeWaits() {
        var governor = PowerGovernor(downgradeDelay: 6)
        XCTAssertEqual(governor.evaluate(inputs(inView: false), at: t0), .cruise)
        // Upgrade: instant.
        XCTAssertEqual(governor.evaluate(inputs(inView: true), at: t0.addingTimeInterval(1)), .full)
        // Downgrade request: held at full through the window…
        XCTAssertEqual(governor.evaluate(inputs(inView: false), at: t0.addingTimeInterval(2)), .full)
        XCTAssertEqual(governor.evaluate(inputs(inView: false), at: t0.addingTimeInterval(7)), .full)
        // …applies only after the delay elapses from the first candidate tick.
        XCTAssertEqual(governor.evaluate(inputs(inView: false), at: t0.addingTimeInterval(8.1)), .cruise)
    }

    func testFlappingConditionNeverDowngrades() {
        var governor = PowerGovernor(downgradeDelay: 6)
        _ = governor.evaluate(inputs(inView: true), at: t0)
        // In/out of view every 2 s: the downgrade candidate keeps resetting.
        var time = t0
        for step in 0..<8 {
            time = time.addingTimeInterval(2)
            let inView = step % 2 == 0
            let tier = governor.evaluate(inputs(inView: inView), at: time)
            XCTAssertEqual(tier, .full, "flapped to \(tier) at step \(step)")
        }
    }

    func testThermalSeriousKeepsTierSubsystemShedsHandleIt() {
        // ADR-034: .serious sheds subsystems (GAR cadence, neural depth, matte),
        // never the tier — person occlusion must survive while the user watches.
        var governor = PowerGovernor()
        XCTAssertEqual(governor.evaluate(inputs(serious: true), at: t0), .full)
    }

    func testThermalCriticalForcesIdleAfterDelay() {
        var governor = PowerGovernor(downgradeDelay: 6)
        XCTAssertEqual(governor.evaluate(inputs(), at: t0), .full)
        _ = governor.evaluate(inputs(critical: true), at: t0.addingTimeInterval(1))
        XCTAssertEqual(
            governor.evaluate(inputs(critical: true), at: t0.addingTimeInterval(8)), .idle
        )
    }

    func testLiveEditingHoldsFull() {
        var governor = PowerGovernor()
        XCTAssertEqual(governor.evaluate(inputs(inView: false, editing: true), at: t0), .full)
    }
}
