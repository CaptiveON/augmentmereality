import XCTest
@testable import AugmentMeReality

final class OutstandingWorkBudgetTests: XCTestCase {
    func testRepeatedUpdatesCannotAccumulateBacklogAndOnlyCompletionReleasesSlot() throws {
        var budget = OutstandingWorkBudget(limit: 2)
        let oldSession = try XCTUnwrap(budget.begin())
        let second = try XCTUnwrap(budget.begin())
        for _ in 0..<100 { XCTAssertNil(budget.begin()) }
        // Invalidating relevance/session does not finish the old SDK task.
        XCTAssertEqual(budget.available, 0)
        budget.finish(oldSession)
        let newSession = try XCTUnwrap(budget.begin())
        budget.finish(oldSession) // a late/duplicate completion cannot free new work
        XCTAssertNil(budget.begin())
        budget.finish(second)
        budget.finish(newSession)
        XCTAssertEqual(budget.available, 2)
    }
}
