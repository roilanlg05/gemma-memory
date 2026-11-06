import Foundation
import GRDB

/// One raw conversation turn. Lives in the `transcript` table, SEPARATE from the knowledge
/// graph (`node`). This is Layer 1 (short-term window source) + Layer 4 (drill-down log).
public struct TranscriptRow: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "transcript"
    public var id: String
    public var threadId: String
    public var turnIndex: Int
    public var seq: Int
    public var role: String
    public var text: String
    public var createdAt: Double
    public var consolidated: Bool

    public init(id: String, threadId: String, turnIndex: Int, seq: Int, role: String, text: String,
                createdAt: Double, consolidated: Bool) {
        self.id = id; self.threadId = threadId; self.turnIndex = turnIndex; self.seq = seq
        self.role = role; self.text = text; self.createdAt = createdAt; self.consolidated = consolidated
    }
}

/// Persists raw chat turns. Reuses the MemoryStore `DatabaseQueue` (one DB file) but never
/// touches `node`. Replaces `EpisodeRecorder` (which wrote graph nodes per turn).
public final class TranscriptStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    @discardableResult
    public func append(threadId: String, turnIndex: Int, role: String, text: String,
                       now: Double = Date().timeIntervalSince1970) throws -> String {
        let id = UUID().uuidString
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_sequence(threadId, lastSeq) VALUES (?, 1)
                ON CONFLICT(threadId) DO UPDATE SET lastSeq = lastSeq + 1
                """, arguments: [threadId])
            guard let seq = try Int.fetchOne(db, sql: "SELECT lastSeq FROM transcript_sequence WHERE threadId = ?",
                                             arguments: [threadId]) else { throw BrainStoreError.invalid }
            let row = TranscriptRow(id: id, threadId: threadId, turnIndex: turnIndex, seq: seq,
                                    role: role, text: text, createdAt: now, consolidated: false)
            try row.insert(db)
        }
        return id
    }

    /// Recent turns for the short-term window, oldest-first, capped by BOTH turn count and a
    /// char budget (newest kept when capping).
    public func recent(threadId: String, maxTurns: Int, maxChars: Int) throws -> [TranscriptRow] {
        let newestFirst: [TranscriptRow] = try dbQueue.read { db in
            var req = TranscriptRow.all()
            if threadId != "main" && threadId != "global" && !threadId.isEmpty {
                req = req.filter(Column("threadId") == threadId)
            }
            return try req
                // role.asc as the final tiebreaker: in this newest-first fetch (later reversed to
                // oldest-first) "assistant" (a<u) sorts before "user" within an equal-timestamp turn,
                // so after reversed() the user precedes the assistant.
                .order(Column("createdAt").desc, Column("turnIndex").desc, Column("role").asc)
                .limit(maxTurns)
                .fetchAll(db)
        }
        var kept: [TranscriptRow] = []
        var chars = 0
        for r in newestFirst {
            chars += r.text.count
            if chars > maxChars, !kept.isEmpty { break }
            kept.append(r)
        }
        return kept.reversed()
    }

    /// Inclusive slice of a thread by seq — for N4 drill-down (M2d-3) and summary expansion.
    public func range(threadId: String, from: Int, to: Int) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try TranscriptRow
                .filter(Column("threadId") == threadId)
                .filter(Column("seq") >= from && Column("seq") <= to)
                .order(Column("seq").asc)
                .fetchAll(db)
        }
    }

    /// Fetch specific rows by id, oldest-first. Used by consolidation to rebuild episode texts.
    public func rows(ids: [String]) throws -> [TranscriptRow] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            try TranscriptRow.filter(ids.contains(Column("id")))
                .order(Column("createdAt").asc, Column("role").asc)
                .fetchAll(db)
        }
    }

    /// Turns not yet consolidated, oldest-first — consolidation input source (used in M2d-2).
    public func unconsolidated(limit: Int) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try TranscriptRow
                .filter(Column("consolidated") == false)
                .order(Column("createdAt").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Newest-first turns across all threads — for the read-only Transcript inspector.
    public func allRecent(limit: Int) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try TranscriptRow.order(Column("createdAt").desc, Column("turnIndex").desc).limit(limit).fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript") ?? 0
        }
    }

    public func markConsolidated(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in try Self.mark(db, ids: ids) }
    }

    /// Close a consolidation job: mark its turns consolidated, retire its resume state and stamp
    /// its completion receipt — all in ONE transaction.
    ///
    /// This is the point where consolidation claims the content is safely absorbed, so it must not
    /// be possible to observe "turns consolidated" without "cycle finished", or the other way
    /// round. If the process dies before this write, nothing moved and the next cycle re-reads the
    /// same turns; if it dies after, there is nothing left to redo.
    ///
    /// `unresolved` is how many of the job's turns could NOT be absorbed. A completion that left
    /// turns behind is recorded as a failed outcome, not a committed one: the job is retired either
    /// way — a parked job would starve every later cycle — but the receipt has to say that the
    /// cycle did not finish its work, or the record would assert a completeness that never
    /// happened. `committed` still carries what did land, and the outcome is retryable because
    /// those turns stay available for the next cycle.
    public func completeConsolidation(ids: [String], jobID: String, operationID: String,
                                      phase: SleepPhase, committed: Int, unresolved: Int = 0,
                                      at: Double) throws {
        try dbQueue.write { db in
            if !ids.isEmpty { try Self.mark(db, ids: ids) }
            try db.execute(sql: "DELETE FROM sleep_cycle WHERE id=1")
            try db.execute(sql: "UPDATE consolidation_job SET completedAt = ? WHERE id = ?",
                           arguments: [at, jobID])
            // One writer for every receipt, so the completion record cannot drift from the schema
            // the rest of the cycle's receipts are written against.
            try MemoryStore.writeReceipt(db, jobID: jobID, operationID: operationID, phase: phase,
                                         outcome: unresolved == 0 ? .committed : .failed,
                                         committed: committed, refused: 0, unresolved: unresolved,
                                         stage: nil, retryable: unresolved > 0, at: at)
        }
    }

    private static func mark(_ db: Database, ids: [String]) throws {
        try TranscriptRow.filter(ids.contains(Column("id")))
            .updateAll(db, Column("consolidated").set(to: true))
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(sql: "DELETE FROM transcript_embedding WHERE turn_id IN (\(ph))",
                       arguments: StatementArguments(ids))
    }
}
