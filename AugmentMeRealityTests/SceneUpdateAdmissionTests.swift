import Dispatch
import os.lock
import XCTest
@testable import AugmentMeReality

final class SceneUpdateAdmissionTests: XCTestCase {
    func testConcurrentRenderNotificationsAdmitOnlyOneActorWakeup() throws {
        let admission = SceneUpdateAdmission()
        let generation = admission.start()
        let accepted = OSAllocatedUnfairLock(initialState: [SceneUpdateAdmission.Ticket]())
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if let ticket = admission.begin(generation: generation) {
                accepted.withLock { $0.append(ticket) }
            }
        }
        let tickets = accepted.withLock { $0 }
        XCTAssertEqual(tickets.count, 1)
        let ticket = try XCTUnwrap(tickets.first)
        XCTAssertTrue(admission.accepts(ticket))
        admission.finish(ticket)
        XCTAssertNotNil(admission.begin(generation: generation))
    }

    func testLifecycleChangesCannotAccumulateOldTasksOrClearANewerSlot() throws {
        let admission = SceneUpdateAdmission()
        let firstGeneration = admission.start()
        let old = try XCTUnwrap(admission.begin(generation: firstGeneration))
        admission.stop()
        let newGeneration = admission.start()
        XCTAssertFalse(admission.accepts(old))
        XCTAssertNil(admission.begin(generation: firstGeneration))
        XCTAssertNil(admission.begin(generation: newGeneration), "old task still owns the only slot")
        admission.finish(old)
        let current = try XCTUnwrap(admission.begin(generation: newGeneration))
        admission.finish(old)
        XCTAssertTrue(admission.accepts(current))
        XCTAssertNil(admission.begin(generation: newGeneration))
        admission.finish(current)
        admission.stop()
        XCTAssertNil(admission.begin(generation: newGeneration))
    }
}
