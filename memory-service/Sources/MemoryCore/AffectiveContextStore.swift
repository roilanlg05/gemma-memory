import Foundation
import GRDB
import BrainContract

/// Process-local state. All access is serialized by the brain's database queue so it can be
/// ordered with source liveness, correction and erasure. No model work runs on that queue.
final class AffectiveContextStore {
    enum Preparation {
        case cached(BrainAffectiveContext)
        case extract(Observation)
    }

    struct Observation {
        let turn: BrainTurnRecord
        let recent: [BrainTurnRecord]
    }

    private struct Support {
        let turnID: String
        let fingerprint: String
    }

    private struct Entry {
        let turnID: String
        let sequence: Int
        var context: BrainAffectiveContext?
        var supports: [Support] = []
    }

    private struct Correction {
        let hypothesisID: String
        let threadID: String
        let turnID: String
    }

    private let brain: BrainStore
    private let turns: BrainTurnStore
    private let ttl: Double
    private var sessionFloors: [String: Int]
    private var latest = [String: Entry]()
    private var corrections = [String: Correction]()

    init(brain: BrainStore, ttl: Double) throws {
        guard ttl.isFinite, ttl > 0, ttl <= 3600 else { throw BrainStoreError.invalid }
        self.brain = brain
        self.turns = BrainTurnStore(brain: brain)
        self.ttl = ttl
        // Server-side transcript order excludes historical turns even if their timestamps are wrong.
        sessionFloors = try brain.store.dbQueue.read { db in
            try brain.checkOwner(db, bind: false)
            return try Dictionary(uniqueKeysWithValues: brain.authorization.threads.map { thread in
                (thread, try Self.sequence(threadID: thread, db: db))
            })
        }
    }

    private static func sequence(threadID: String, db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT lastSeq FROM transcript_sequence WHERE threadId=?", arguments: [threadID]) ?? 0
    }

    private func liveTurn(_ id: String, db: Database) throws -> BrainTurnRecord {
        let turn = try turns.load(id, db: db)
        guard turn.state == "committed", turn.receipt?.state == .committed else { throw BrainStoreError.denied }
        return turn
    }

    func expiry(for source: BrainEvidence) -> Double { source.observedAt + ttl }

    private func isLive(_ turn: BrainTurnRecord, now: Double) -> Bool {
        turn.sequence > (sessionFloors[turn.source.threadID] ?? 0)
            && turn.source.observedAt <= now && now < expiry(for: turn.source)
    }

    private func isCurrent(_ turn: BrainTurnRecord, db: Database) throws -> Bool {
        // A newer admitted user turn supersedes guidance even while its claims are pending.
        try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS (
                SELECT 1 FROM brain_turn b JOIN transcript t ON t.id = b.transcript_id
                WHERE b.principal=? AND b.thread_id=? AND t.seq>?
            )
            """, arguments: [brain.authorization.principal, turn.source.threadID, turn.sequence]) == true
    }

    private func recent(before turn: BrainTurnRecord, now: Double, db: Database) throws -> [BrainTurnRecord] {
        let thread = turn.source.threadID
        let ids = try String.fetchAll(db, sql: """
            SELECT b.id FROM brain_turn b JOIN transcript t ON t.id = b.transcript_id
            WHERE b.principal=? AND b.thread_id=? AND b.state='committed' AND t.seq>? AND t.seq<?
            ORDER BY t.seq DESC LIMIT 4
            """, arguments: [brain.authorization.principal, thread, sessionFloors[thread] ?? 0, turn.sequence])
        return try ids.reversed().compactMap { id in
            do {
                let previous = try liveTurn(id, db: db)
                guard isLive(previous, now: now), let text = previous.source.text, text.utf8.count <= 2048 else { return nil }
                return previous
            } catch BrainStoreError.denied { return nil }
        }
    }

    private func supportsAreLive(_ supports: [Support], now: Double, db: Database) throws -> Bool {
        for support in supports {
            do {
                let turn = try liveTurn(support.turnID, db: db)
                guard isLive(turn, now: now), try BrainStore.digest(BrainStore.encode(turn.source)) == support.fingerprint else {
                    return false
                }
            } catch BrainStoreError.denied { return false }
        }
        return true
    }

    private func clear(_ entry: Entry, thread: String) {
        latest[thread] = Entry(turnID: entry.turnID, sequence: entry.sequence, context: .init())
    }

    func prepare(turnID: String, now: Double) throws -> Preparation {
        try brain.store.dbQueue.read { db in
            let turn = try liveTurn(turnID, db: db)
            let thread = turn.source.threadID
            guard isLive(turn, now: now), try isCurrent(turn, db: db) else { return .cached(.init()) }
            if let entry = latest[thread] {
                if entry.sequence > turn.sequence { return .cached(.init()) }
                if entry.turnID == turn.id, let context = entry.context {
                    if try supportsAreLive(entry.supports, now: now, db: db) { return .cached(context) }
                    clear(entry, thread: thread)
                    return .cached(.init())
                }
            }
            let recent = try recent(before: turn, now: now, db: db)
            latest[thread] = Entry(turnID: turn.id, sequence: turn.sequence, context: nil)
            return .extract(.init(turn: turn, recent: recent))
        }
    }

    /// A nil result revalidates after a provider failure but leaves the latest turn retryable.
    func finish(_ original: Observation, context: BrainAffectiveContext?, now: Double) throws -> BrainAffectiveContext {
        try brain.store.dbQueue.read { db in
            let turn = try liveTurn(original.turn.id, db: db)
            let thread = turn.source.threadID
            guard turn.source == original.turn.source, turn.sequence == original.turn.sequence else { throw BrainStoreError.conflict }
            guard isLive(turn, now: now), var entry = latest[thread], entry.turnID == turn.id else { return .init() }
            guard try isCurrent(turn, db: db) else {
                clear(entry, thread: thread)
                return .init()
            }
            let supports = try original.recent.map {
                try Support(turnID: $0.id, fingerprint: BrainStore.digest(BrainStore.encode($0.source)))
            }
            guard try supportsAreLive(entry.context == nil ? supports : entry.supports, now: now, db: db) else {
                clear(entry, thread: thread)
                return .init()
            }
            if let current = entry.context { return current }
            entry.context = context
            entry.supports = supports
            latest[thread] = entry
            return context ?? .init()
        }
    }

    func context(threadID: String, now: Double, db: Database) throws -> BrainAffectiveContext {
        try brain.checkOwner(db, bind: false)
        try turns.requireUser(thread: threadID)
        guard let entry = latest[threadID], let context = entry.context,
              !context.hypotheses.isEmpty || context.interaction != nil else { return .init() }
        do {
            let turn = try liveTurn(entry.turnID, db: db)
            if isLive(turn, now: now), try isCurrent(turn, db: db),
               try supportsAreLive(entry.supports, now: now, db: db) { return context }
        } catch BrainStoreError.denied {
            corrections = corrections.filter { $0.value.turnID != entry.turnID }
        }
        // Keep only the ordering watermark. A stale retry cannot rebuild an expired observation.
        clear(entry, thread: threadID)
        return .init()
    }

    func correct(hypothesisID: String, operationID: String, correction: BrainAffectCorrection) throws {
        let operation = try BrainTurnStore.key(operationID)
        try brain.store.dbQueue.read { db in
            if let old = corrections[operation] {
                guard old.hypothesisID == hypothesisID else { throw BrainStoreError.conflict }
                _ = try liveTurn(old.turnID, db: db)
                return
            }
            guard let (thread, entry) = latest.first(where: {
                $0.value.context?.hypotheses.contains(where: { $0.id == hypothesisID }) == true
            }) else { throw BrainStoreError.denied }
            _ = try liveTurn(entry.turnID, db: db)
            switch correction {
            case .dismiss:
                // Suppress the whole interpretation, including cues based on the same reading.
                latest[thread] = Entry(turnID: entry.turnID, sequence: entry.sequence, context: .init())
            }
            corrections[operation] = Correction(hypothesisID: hypothesisID, threadID: thread, turnID: entry.turnID)
        }
    }

    func endSession(threadID: String) throws {
        try brain.store.dbQueue.read { db in
            try brain.checkOwner(db, bind: false)
            try turns.requireUser(thread: threadID)
            sessionFloors[threadID] = try Self.sequence(threadID: threadID, db: db)
            latest.removeValue(forKey: threadID)
            corrections = corrections.filter { $0.value.threadID != threadID }
        }
    }
}
