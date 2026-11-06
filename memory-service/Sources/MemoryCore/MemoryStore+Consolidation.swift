import Foundation
import GRDB

/// Persistence for consolidation jobs and phase receipts — the record of what a cycle actually
/// did, as opposed to what it was asked to do.
extension MemoryStore {

    // MARK: jobs

    /// Record a job, or return the one already stored under this id. A resumed job keeps the
    /// timezone it started with: a cycle that began on Tuesday in Havana still resolves the
    /// user's "tomorrow" in Havana when it finishes on Wednesday.
    public func openConsolidationJob(_ job: ConsolidationJob) throws -> ConsolidationJob {
        try dbQueue.write { db in
            if let existing = try Self.readJob(db, id: job.id) { return existing }
            try Self.writeJob(db, job)
            return job
        }
    }

    public func consolidationJob(id: String) throws -> ConsolidationJob? {
        try dbQueue.read { db in try Self.readJob(db, id: id) }
    }

    /// Store the evidence ids the job's turns were adapted into, and advance its phase.
    public func updateConsolidationJob(_ job: ConsolidationJob) throws {
        try dbQueue.write { db in try Self.writeJob(db, job) }
    }

    private static func readJob(_ db: Database, id: String) throws -> ConsolidationJob? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, phase, transcriptIds, evidenceIds, timeZoneId, startedAt
            FROM consolidation_job WHERE id = ?
            """, arguments: [id]) else { return nil }
        guard let phase = SleepPhase(rawValue: row["phase"]) else { return nil }
        return ConsolidationJob(id: row["id"], phase: phase,
                                transcriptIDs: decodeIDs(row["transcriptIds"]),
                                evidenceIDs: decodeIDs(row["evidenceIds"]),
                                timeZoneIdentifier: row["timeZoneId"],
                                startedAt: row["startedAt"])
    }

    private static func writeJob(_ db: Database, _ job: ConsolidationJob) throws {
        try db.execute(sql: """
            INSERT INTO consolidation_job(id, phase, transcriptIds, evidenceIds, timeZoneId, startedAt, completedAt)
            VALUES (?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET phase = excluded.phase, evidenceIds = excluded.evidenceIds
            """, arguments: [job.id, job.phase.rawValue, encodeIDs(job.transcriptIDs),
                             encodeIDs(job.evidenceIDs), job.timeZoneIdentifier, job.startedAt])
    }

    static func encodeIDs(_ ids: [String]) -> String {
        String(data: (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }
    static func decodeIDs(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    // MARK: receipts

    /// Record what a phase did, under the job's stable operation id for that phase.
    ///
    /// Idempotent by primary key: replaying a phase overwrites its receipt and bumps the attempt
    /// count rather than appending a second record, so a crash loop is visible as attempts and
    /// never as duplicated work.
    public func recordConsolidationReceipt(jobID: String, _ result: ConsolidationPhaseResult,
                                           operationID: String, at: Double) throws {
        try dbQueue.write { db in
            let attempts = try Int.fetchOne(db,
                sql: "SELECT attempts FROM consolidation_receipt WHERE job_id = ? AND operation = ?",
                arguments: [jobID, operationID]) ?? 0
            try db.execute(sql: """
                INSERT INTO consolidation_receipt
                    (job_id, operation, phase, outcome, committed, refused, stage, retryable, attempts, at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id, operation) DO UPDATE SET
                    outcome = excluded.outcome, committed = excluded.committed,
                    refused = excluded.refused, stage = excluded.stage,
                    retryable = excluded.retryable, attempts = excluded.attempts, at = excluded.at
                """, arguments: [jobID, operationID, result.phase.rawValue, result.outcome.rawValue,
                                 result.committed, result.refusals.count,
                                 result.failure?.stage.rawValue, result.failure?.retryable ?? false,
                                 attempts + 1, at])
        }
    }

    public func consolidationReceipt(jobID: String, operationID: String) throws -> ConsolidationReceipt? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT job_id, operation, phase, outcome, committed, refused, stage, retryable, attempts, at
                FROM consolidation_receipt WHERE job_id = ? AND operation = ?
                """, arguments: [jobID, operationID]) else { return nil }
            guard let phase = SleepPhase(rawValue: row["phase"]),
                  let outcome = ConsolidationPhaseResult.Outcome(rawValue: row["outcome"]) else { return nil }
            return ConsolidationReceipt(jobID: row["job_id"], operationID: row["operation"], phase: phase,
                                        outcome: outcome, committed: row["committed"], refused: row["refused"],
                                        stage: (row["stage"] as String?).flatMap { ConsolidationStage(rawValue: $0) },
                                        retryable: row["retryable"], attempts: row["attempts"], at: row["at"])
        }
    }

    /// Delete a phase receipt. Used only to reproduce the crash window between a phase's writes
    /// committing and its receipt being recorded.
    func forgetConsolidationReceipt(jobID: String, operationID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM consolidation_receipt WHERE job_id = ? AND operation = ?",
                           arguments: [jobID, operationID])
        }
    }

    // MARK: summary coverage

    /// Highest transcript `seq` already covered by a summary, per thread.
    ///
    /// Summaries record the `seq` range they were distilled from, so a thread that was summarized
    /// yesterday can still have today's turns summarized: only the turns beyond this watermark
    /// need a new pass.
    public func summarizedUpTo() throws -> [String: Int] {
        var watermark: [String: Int] = [:]
        for node in try allNodes() where node.kind == NodeKind.summary.rawValue {
            guard let data = node.extra?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let thread = (object["threadId"] as? String) ?? node.sourceRef
            guard let thread, !thread.isEmpty,
                  let range = object["turnRange"] as? [Int], range.count == 2 else { continue }
            watermark[thread] = max(watermark[thread] ?? 0, range[1])
        }
        return watermark
    }
}
