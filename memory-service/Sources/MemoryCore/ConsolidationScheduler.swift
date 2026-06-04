import Foundation

/// Abstraction over the engine so the scheduler is testable with a spy.
public protocol ConsolidationRunning: AnyObject, Sendable {
    func runLight(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async
    func runCycle(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async
}

/// Server-side scheduler: drives the consolidation engine on a single debounce timer. Unlike the
/// app (which uses `@Observable` for SwiftUI), this version is plain `@MainActor` — the service has
/// no UI, but keeping the actor-bound mutable state model lets us reuse the same logic.
///
/// Cloud-model cost note: each cycle spends API tokens, so we no longer arm recurring pause/idle
/// timers. Instead, after the user goes quiet for `debounceInterval`, we run ONE full cycle.
/// `runCycle` already no-ops when there's no un-consolidated data.
@MainActor
public final class ConsolidationScheduler {
    public enum State: Equatable, Sendable { case idle, reflecting, sleeping(String), done(String) }
    public private(set) var state: State = .idle
    public var lastSummary: String = ""
    /// True iff a consolidation cycle (light or full) is currently in flight. Surfaced via
    /// `/v1/consolidation/state` so the macOS client can disable user input while busy.
    public var isRunning: Bool { running != nil }
    /// Tracks the most recent `armTurnEnd(threadId:)` invocation for diagnostics.
    public private(set) var lastTurnEndThread: String?
    /// Most recent timezone reported by the app (turn-end/reflect). Used for date resolution in
    /// cycles that fire from timers or resume after restart. Defaults to the server tz.
    public private(set) var lastTimeZone: TimeZone = .current

    private let runner: ConsolidationRunning
    private let isReady: () -> Bool
    private let hasPendingCycle: () -> Bool
    private let isUserBusy: () -> Bool
    private let debounceInterval: Duration
    private var debounceTask: Task<Void, Never>?
    private var running: Task<Void, Never>?
    // Thread-safe storage instead of a @MainActor-isolated Bool: the engine's
    // `isCancelled` closure is called from the cooperative thread pool (engine
    // is not @MainActor), so `MainActor.assumeIsolated { cancelFlag }` would
    // trap with a fatal error → SIGILL on Linux. See `AtomicFlag` below.
    private let cancelFlag = AtomicFlag(false)

    public init(runner: ConsolidationRunning, isReady: @escaping () -> Bool, hasPendingCycle: @escaping () -> Bool,
                isUserBusy: @escaping () -> Bool = { false },
                debounceInterval: Duration = .seconds(45)) {
        self.runner = runner; self.isReady = isReady; self.hasPendingCycle = hasPendingCycle
        self.isUserBusy = isUserBusy
        self.debounceInterval = debounceInterval
    }

    /// Called at the START of every user turn: cancel any running consolidation and any pending
    /// debounce. Does NOT arm the debounce — that happens at turn end via noteTurnEnded().
    public func noteUserActivity() {
        cancelFlag.set(true)
        running?.cancel(); running = nil
        debounceTask?.cancel()
        state = .idle
    }

    /// Called at the END of every user turn: (re)arms the single debounce timer. After the user
    /// goes quiet for `debounceInterval`, ONE full cycle runs. Re-arming resets the countdown.
    public func noteTurnEnded() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard let self, !Task.isCancelled else { return }
            // One full cycle after the user goes quiet. runCycle() no-ops if there's no new data;
            // hasPendingCycle resumes an interrupted cycle.
            self.launch(light: false)
        }
    }

    public func consolidateNow() { launch(light: false) }
    public func requestLightReflection() { launch(light: true) }

    /// HTTP-facing alias for `noteTurnEnded()`: records the thread and arms the pause/idle timers
    /// that drive light/full consolidation. Mirrors the macOS-side semantics so server callers
    /// (the new `/v1/consolidation/turn-end` endpoint) can drive the scheduler the same way.
    public func armTurnEnd(threadId: String, timeZone: TimeZone = .current) {
        lastTurnEndThread = threadId
        lastTimeZone = timeZone
        noteTurnEnded()
    }

    /// Ad-hoc manual reflection trigger (used by `POST /v1/consolidation/reflect`). Launches the
    /// awake-light pass if nothing is running and returns a synthetic cycle id (timestamp-based)
    /// so callers can correlate the request with the response. Returns nil when the scheduler is
    /// not ready or already running.
    public func runReflectAdHoc(timeZone: TimeZone = .current) -> String? {
        guard isReady(), running == nil, !isUserBusy() else { return nil }
        lastTimeZone = timeZone
        let cycleId = "reflect-\(Int(Date().timeIntervalSince1970 * 1000))"
        launch(light: true)
        return cycleId
    }

    private func launch(light: Bool) {
        guard isReady(), running == nil, !isUserBusy() else { return }
        cancelFlag.set(false)
        let isCancelled: @Sendable () -> Bool = { [cancelFlag] in
            cancelFlag.get()
        }
        let tz = lastTimeZone
        state = light ? .reflecting : .sleeping("nrem")
        running = Task { [weak self, runner] in
            if light { await runner.runLight(isCancelled: isCancelled, timeZone: tz) }
            else { await runner.runCycle(isCancelled: isCancelled, timeZone: tz) }
            await MainActor.run {
                guard let self else { return }
                self.running = nil
                if self.state != .idle { self.state = .done(light ? "reflecting" : "sleeping") }
            }
        }
    }
}

/// Lock-backed Bool that's safe to read/write from any task or thread.
/// Replaces a @MainActor-isolated flag whose closure-reads via
/// `MainActor.assumeIsolated` would trap when called off the main actor
/// (e.g. from the engine's non-isolated `runLight`/`runCycle` on Linux,
/// where the trap surfaces as SIGILL).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}
