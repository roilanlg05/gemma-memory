import XCTest
import Foundation
@testable import MemoryCore

/// Spy implementing `ConsolidationRunning`: counts full (`runCycle`) and light (`runLight`) calls
/// so scheduler timing/debounce behaviour can be asserted without the real engine.
final class SpyRunner: ConsolidationRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _fullCycleCount = 0
    private var _lightCycleCount = 0
    var fullCycleCount: Int { lock.lock(); defer { lock.unlock() }; return _fullCycleCount }
    var lightCycleCount: Int { lock.lock(); defer { lock.unlock() }; return _lightCycleCount }

    func runLight(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async {
        lock.lock(); _lightCycleCount += 1; lock.unlock()
    }
    func runCycle(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async {
        lock.lock(); _fullCycleCount += 1; lock.unlock()
    }
}

@MainActor
final class ConsolidationSchedulerTests: XCTestCase {

    func test_debounce_runs_single_full_cycle_and_resets() async throws {
        let spy = SpyRunner()
        let sched = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { false },
                                           debounceInterval: .milliseconds(80))
        sched.armTurnEnd(threadId: "a")
        try await Task.sleep(for: .milliseconds(40))
        sched.armTurnEnd(threadId: "a")            // resets the debounce
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(spy.fullCycleCount, 0)      // not yet (was reset)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(spy.fullCycleCount, 1)      // one cycle after quiet
        XCTAssertEqual(spy.lightCycleCount, 0)     // no recurring light reflection
    }

    func test_userActivity_cancels_pending_debounce() async throws {
        let spy = SpyRunner()
        let sched = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { false },
                                           debounceInterval: .milliseconds(80))
        sched.armTurnEnd(threadId: "a")
        try await Task.sleep(for: .milliseconds(40))
        sched.noteUserActivity()                   // user resumed → cancel the pending cycle
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(spy.fullCycleCount, 0)
        XCTAssertEqual(spy.lightCycleCount, 0)
    }

    func test_manual_consolidateNow_runs_full_cycle_immediately() async throws {
        let spy = SpyRunner()
        let sched = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { false })
        sched.consolidateNow()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(spy.fullCycleCount, 1)
        XCTAssertEqual(spy.lightCycleCount, 0)
    }
}
