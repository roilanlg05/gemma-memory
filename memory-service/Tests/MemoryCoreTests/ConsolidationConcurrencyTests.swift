import XCTest
import Foundation
@testable import MemoryCore

/// A runner that records how many consolidation runs were ever in flight at the same moment.
///
/// It deliberately keeps working for a short while after cancellation (an uninterruptible wait),
/// exactly like a real engine that is in the middle of a phase when the user starts typing. That
/// is the window in which a scheduler which only *signals* cancellation would start a second
/// engine on the same SQLite file.
final class OverlapDetectingRunner: ConsolidationRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var _maxActive = 0
    private var _starts = 0
    private var _cancelledRuns = Set<Int>()
    private let holdMilliseconds: Int

    init(holdMilliseconds: Int = 150) { self.holdMilliseconds = holdMilliseconds }

    var maxActive: Int { lock.withLock { _maxActive } }
    var starts: Int { lock.withLock { _starts } }
    /// 1-based indices of the runs that saw their own cancellation signal.
    var cancelledRuns: Set<Int> { lock.withLock { _cancelledRuns } }

    private func enter() -> Int {
        lock.withLock { active += 1; _starts += 1; _maxActive = max(_maxActive, active); return _starts }
    }
    private func leave() { lock.withLock { active -= 1 } }

    /// A wait that cancellation cannot shorten — it models work already handed to the database.
    private func hold() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(holdMilliseconds)) {
                continuation.resume()
            }
        }
    }

    private func run(_ isCancelled: @escaping () -> Bool) async {
        let index = enter()
        await hold()
        if isCancelled() { lock.withLock { _cancelledRuns.insert(index) } }
        leave()
    }

    func runLight(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async { await run(isCancelled) }
    func runCycle(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async { await run(isCancelled) }
}

/// Records the timezone each run was launched with, so a per-job timezone can be asserted.
final class TimeZoneRecordingRunner: ConsolidationRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _timeZones: [String] = []
    var timeZones: [String] { lock.withLock { _timeZones } }
    private func record(_ tz: TimeZone) { lock.withLock { _timeZones.append(tz.identifier) } }
    func runLight(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async { record(timeZone) }
    func runCycle(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async { record(timeZone) }
}

@MainActor
final class ConsolidationConcurrencyTests: XCTestCase {

    func test_cancellationFollowedByNewActivityNeverOverlapsTwoEngines() async throws {
        let runner = OverlapDetectingRunner(holdMilliseconds: 200)
        let scheduler = ConsolidationScheduler(runner: runner, isReady: { true },
                                               hasPendingCycle: { false },
                                               debounceInterval: .milliseconds(20))
        scheduler.consolidateNow()
        try await Task.sleep(for: .milliseconds(40))     // the first engine is mid-phase
        scheduler.noteUserActivity()                     // cancel it …
        scheduler.consolidateNow()                       // … and immediately ask for a replacement
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(runner.maxActive, 1,
                       "a replacement run must wait for the cancelled run to finish, never overlap it")
        XCTAssertEqual(runner.starts, 2, "the replacement run really did happen")
    }

    func test_replacementRunIsNotItselfCancelledByTheOldFlag() async throws {
        let runner = OverlapDetectingRunner(holdMilliseconds: 80)
        let scheduler = ConsolidationScheduler(runner: runner, isReady: { true },
                                               hasPendingCycle: { false },
                                               debounceInterval: .milliseconds(20))
        scheduler.consolidateNow()
        try await Task.sleep(for: .milliseconds(20))
        scheduler.noteUserActivity()
        scheduler.consolidateNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(runner.starts, 2)
        XCTAssertEqual(runner.cancelledRuns, [1],
                       "only the cancelled run sees the signal; the replacement starts with its own")
    }

    func test_eachRunKeepsTheTimeZoneItWasArmedWith() async throws {
        let runner = TimeZoneRecordingRunner()
        let scheduler = ConsolidationScheduler(runner: runner, isReady: { true },
                                               hasPendingCycle: { false },
                                               debounceInterval: .milliseconds(20))
        scheduler.armTurnEnd(threadId: "a", timeZone: TimeZone(identifier: "America/Havana")!)
        try await Task.sleep(for: .milliseconds(200))
        scheduler.armTurnEnd(threadId: "b", timeZone: TimeZone(identifier: "Europe/Madrid")!)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runner.timeZones, ["America/Havana", "Europe/Madrid"],
                       "each job runs with the timezone recorded when it was armed")
    }
}
