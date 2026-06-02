import Foundation

/// Abstraction over the engine so the scheduler is testable with a spy.
public protocol ConsolidationRunning: AnyObject, Sendable {
    func runLight(isCancelled: @escaping () -> Bool) async
    func runCycle(isCancelled: @escaping () -> Bool) async
}

/// Server-side scheduler: drives the consolidation engine on pause/idle timers. Unlike the app
/// (which uses `@Observable` for SwiftUI), this version is plain `@MainActor` — the service has
/// no UI, but keeping the actor-bound mutable state model lets us reuse the same logic.
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

    private let runner: ConsolidationRunning
    private let isReady: () -> Bool
    private let hasPendingCycle: () -> Bool
    private let isUserBusy: () -> Bool
    private let pauseInterval: Duration
    private let idleInterval: Duration
    private var pauseTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var cancelFlag = false

    public init(runner: ConsolidationRunning, isReady: @escaping () -> Bool, hasPendingCycle: @escaping () -> Bool,
                isUserBusy: @escaping () -> Bool = { false },
                pauseInterval: Duration = .seconds(15), idleInterval: Duration = .seconds(180)) {
        self.runner = runner; self.isReady = isReady; self.hasPendingCycle = hasPendingCycle
        self.isUserBusy = isUserBusy
        self.pauseInterval = pauseInterval; self.idleInterval = idleInterval
    }

    /// Called at the START of every user turn: cancel any running consolidation. Does NOT arm
    /// timers — timers are armed at turn end via noteTurnEnded().
    public func noteUserActivity() {
        cancelFlag = true
        running?.cancel(); running = nil
        pauseTask?.cancel(); idleTask?.cancel()
        state = .idle
    }

    /// Called at the END of every user turn: arms the pause/idle countdown timers.
    public func noteTurnEnded() {
        pauseTask?.cancel(); idleTask?.cancel()
        scheduleTimers()
    }

    public func consolidateNow() { launch(light: false) }
    public func requestLightReflection() { launch(light: true) }

    /// HTTP-facing alias for `noteTurnEnded()`: records the thread and arms the pause/idle timers
    /// that drive light/full consolidation. Mirrors the macOS-side semantics so server callers
    /// (the new `/v1/consolidation/turn-end` endpoint) can drive the scheduler the same way.
    public func armTurnEnd(threadId: String) {
        lastTurnEndThread = threadId
        noteTurnEnded()
    }

    /// Ad-hoc manual reflection trigger (used by `POST /v1/consolidation/reflect`). Launches the
    /// awake-light pass if nothing is running and returns a synthetic cycle id (timestamp-based)
    /// so callers can correlate the request with the response. Returns nil when the scheduler is
    /// not ready or already running.
    public func runReflectAdHoc() -> String? {
        guard isReady(), running == nil, !isUserBusy() else { return nil }
        let cycleId = "reflect-\(Int(Date().timeIntervalSince1970 * 1000))"
        launch(light: true)
        return cycleId
    }

    private func scheduleTimers() {
        pauseTask = Task { [weak self, pauseInterval] in
            try? await Task.sleep(for: pauseInterval)
            guard let self, !Task.isCancelled else { return }
            if self.hasPendingCycle() { self.launch(light: false) }  // resume the interrupted cycle promptly
            else { self.launch(light: true) }                        // otherwise a light awake reflection
        }
        idleTask = Task { [weak self, idleInterval] in
            try? await Task.sleep(for: idleInterval)
            guard let self, !Task.isCancelled else { return }
            self.launch(light: false)
        }
    }

    private func launch(light: Bool) {
        guard isReady(), running == nil, !isUserBusy() else { return }
        cancelFlag = false
        let isCancelled: @Sendable () -> Bool = { [weak self] in
            MainActor.assumeIsolated { self?.cancelFlag ?? true }
        }
        state = light ? .reflecting : .sleeping("nrem")
        running = Task { [weak self, runner] in
            if light { await runner.runLight(isCancelled: isCancelled) }
            else { await runner.runCycle(isCancelled: isCancelled) }
            await MainActor.run {
                guard let self else { return }
                self.running = nil
                if self.state != .idle { self.state = .done(light ? "reflecting" : "sleeping") }
            }
        }
    }
}
