import Foundation
import GRDB
import BrainContract

struct BrainTurnRecord {
    let id: String
    let source: BrainEvidence
    let transcriptID: String
    let state: String
    let updates: [BrainClaimUpdate]?
    let hasPending: Bool
    let receipt: BrainCommitResult?
}

/// Transactional journal. No extractor, sanitizer or model is called under a database lock.
final class BrainTurnStore {
    let brain: BrainStore
    init(brain: BrainStore) { self.brain = brain }
    static func key(_ operation: String) throws -> String {
        guard !operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrainStoreError.invalid }
        return BrainStore.digest(operation)
    }
    func operation(_ namespace: String, key: String, db: Database) throws -> Row? {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM brain_turn_operation WHERE principal=? AND namespace=? AND operation_hash=?",
                                  arguments: [brain.authorization.principal, namespace, key])
        if let row, (row["withdrawn"] as Bool) { throw BrainStoreError.denied }
        return row
    }
    func insertOperation(_ namespace: String, key: String, digest: String, turnID: String?, resultID: String?, db: Database) throws {
        try db.execute(sql: "INSERT INTO brain_turn_operation(principal, namespace, operation_hash, request_hash, turn_id, result_id, withdrawn) VALUES (?, ?, ?, ?, ?, ?, 0)",
                       arguments: [brain.authorization.principal, namespace, key, digest, turnID, resultID])
    }
    func requireUser(thread: String) throws {
        try brain.requireAccess(subject: "self:user", scope: .user)
        guard brain.authorization.owner == ConsolidationEvidenceAdapter.ownerID,
              brain.authorization.threads.contains(thread),
              brain.authorization.sourceSpeakers[.userMessage]?.contains("self:user") == true else { throw BrainStoreError.denied }
    }
    func load(_ id: String, db: Database) throws -> BrainTurnRecord {
        try brain.checkOwner(db, bind: false)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM brain_turn WHERE id=? AND principal=?", arguments: [id, brain.authorization.principal]) else { throw BrainStoreError.denied }
        let thread: String = row["thread_id"]
        try requireUser(thread: thread)
        let sourceID: String = row["source_id"], transcriptID: String = row["transcript_id"]
        guard let sourcePayload = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [sourceID]),
              try TranscriptRow.fetchOne(db, key: transcriptID) != nil else { throw BrainStoreError.denied }
        let source = try BrainStore.decode(BrainEvidence.self, sourcePayload)
        try brain.validateEvidence(source, db: db)
        guard source.threadID == thread, source.sourceKind == .userMessage, source.speakerID == "self:user" else { throw BrainStoreError.denied }
        let updatesPayload: String? = row["updates"], receiptPayload: String? = row["receipt"]
        return BrainTurnRecord(id: id, source: source, transcriptID: transcriptID, state: row["state"],
            updates: try updatesPayload.map { try BrainStore.decode([BrainClaimUpdate].self, $0) },
            hasPending: row["has_pending"], receipt: try receiptPayload.map { try BrainStore.decode(BrainCommitResult.self, $0) })
    }
    func read(_ id: String) throws -> BrainTurnRecord {
        try brain.store.dbQueue.read { try load(id, db: $0) }
    }
    static func append(thread: String, role: String, text: String, timestamp: Double, turnIndex: Int? = nil, db: Database) throws -> TranscriptRow {
        try db.execute(sql: "INSERT INTO transcript_sequence(threadId, lastSeq) VALUES (?, 1) ON CONFLICT(threadId) DO UPDATE SET lastSeq=lastSeq+1", arguments: [thread])
        guard let seq = try Int.fetchOne(db, sql: "SELECT lastSeq FROM transcript_sequence WHERE threadId=?", arguments: [thread]), seq > 0 else { throw BrainStoreError.invalid }
        let row = TranscriptRow(id: UUID().uuidString, threadId: thread, turnIndex: turnIndex ?? seq, seq: seq,
                                role: role, text: text, createdAt: timestamp, consolidated: false)
        try row.insert(db)
        return row
    }
    func capture(_ request: BrainTurnRequest) throws -> String {
        try requireUser(thread: request.threadID)
        guard request.message.speakerID == "self:user" else { throw BrainStoreError.denied }
        guard request.schemaVersion == 1, !request.message.id.isEmpty, request.message.observedAt.isFinite,
              !request.message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrainStoreError.invalid }
        let key = try Self.key(request.clientOperationID)
        // Wire evidence IDs never grant access, but are included in the conflict fingerprint.
        let digest = BrainStore.digest(try BrainStore.encode(request))
        return try brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: true)
            if let old = try operation("begin", key: key, db: db) {
                guard (old["request_hash"] as String?) == digest, let id: String = old["turn_id"] else { throw BrainStoreError.conflict }
                _ = try load(id, db: db)
                return id
            }
            let row = try Self.append(thread: request.threadID, role: "user", text: request.message.text, timestamp: request.message.observedAt, db: db)
            guard let evidence = ConsolidationEvidenceAdapter.evidence(for: row) else { throw BrainStoreError.invalid }
            try brain.insertEvidence(evidence, db: db)
            let id = UUID().uuidString
            try db.execute(sql: "INSERT INTO brain_turn(id, principal, thread_id, subject, source_id, transcript_id, state, has_pending) VALUES (?, ?, ?, 'self:user', ?, ?, 'captured', 0)",
                           arguments: [id, brain.authorization.principal, request.threadID, evidence.id, row.id])
            try db.execute(sql: "INSERT INTO brain_turn_ref VALUES (?, ?, ?)", arguments: [id, evidence.id, row.id])
            try insertOperation("begin", key: key, digest: digest, turnID: id, resultID: nil, db: db)
            return id
        }
    }
    func stage(_ batch: BrainTurnExtractionBatch, turnID: String) throws -> [BrainClaimUpdate] {
        try brain.store.dbQueue.write { db in
            let turn = try load(turnID, db: db)
            if let updates = turn.updates { return updates }
            let payload = try BrainStore.encode(batch.updates)
            try db.execute(sql: "UPDATE brain_turn SET state='staged', updates=?, has_pending=? WHERE id=?",
                           arguments: [payload, batch.hasPending, turnID])
            for update in batch.updates {
                let ids = Set([update.claim.id] + update.claim.contradictsIDs + [update.claim.supersedesID].compactMap { $0 })
                for id in ids {
                    try db.execute(sql: "INSERT OR IGNORE INTO brain_turn_claim VALUES (?, ?)", arguments: [turnID, id])
                }
            }
            return batch.updates
        }
    }
    func commit(_ updates: [BrainClaimUpdate], turnID: String) throws -> BrainCommitResult {
        for _ in 0..<3 {
            let turn = try read(turnID)
            guard turn.updates == updates else { throw BrainStoreError.denied }
            if let receipt = turn.receipt { return receipt }
            let request = try BrainCommitRequest(clientOperationID: "turn:" + turnID, evidence: [], updates: updates, expectedRevision: brain.revision())
            let result = try brain.commit(request, transactionGuard: { db in
                let current = try self.load(turnID, db: db)
                guard current.updates == updates else { throw BrainStoreError.denied }
                guard current.receipt == nil else { throw BrainStoreError.conflict }
            }, didCommit: { db, result in
                // Guard and receipt are in the exact transaction that changes claims/revision.
                let current = try self.load(turnID, db: db)
                try db.execute(sql: "UPDATE brain_turn SET state=?, receipt=? WHERE id=?",
                               arguments: [current.hasPending ? "pending" : "committed", try BrainStore.encode(result), turnID])
            })
            if result.state == .committed { return result }
        }
        let current = try read(turnID)
        if let receipt = current.receipt { return receipt }
        return BrainCommitResult(clientOperationID: "turn:" + turnID, state: .pending, revision: try brain.revision(), claimIDs: [], disposition: .conflict)
    }
    func reply(_ turnID: String) throws -> String {
        try brain.store.dbQueue.read { db in
            _ = try load(turnID, db: db)
            guard let id = try String.fetchOne(db, sql: "SELECT assistant_id FROM brain_turn WHERE id=?", arguments: [turnID]) else { return "" }
            return try brain.loadEvidence(id, db: db).text ?? ""
        }
    }
    func assistant(turnID: String, operationID: String, text: String, timestamp: Double) throws -> BrainEvidence {
        let key = try Self.key(operationID)
        guard timestamp.isFinite, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrainStoreError.invalid }
        let digest = BrainStore.digest(try BrainStore.encode([turnID, text]))
        return try brain.store.dbQueue.write { db in
            let turn = try load(turnID, db: db)
            guard brain.authorization.sourceSpeakers[.assistantMessage]?.contains("self:agent") == true else { throw BrainStoreError.denied }
            if let old = try operation("assistant", key: key, db: db) {
                guard (old["request_hash"] as String?) == digest, let evidenceID: String = old["result_id"] else { throw BrainStoreError.conflict }
                return try brain.loadEvidence(evidenceID, db: db)
            }
            guard try String.fetchOne(db, sql: "SELECT assistant_id FROM brain_turn WHERE id=?", arguments: [turnID]) == nil else { throw BrainStoreError.conflict }
            let original = try TranscriptRow.fetchOne(db, key: turn.transcriptID)
            let row = try Self.append(thread: turn.source.threadID, role: "assistant", text: text, timestamp: timestamp, turnIndex: original?.turnIndex, db: db)
            guard let evidence = ConsolidationEvidenceAdapter.evidence(for: row) else { throw BrainStoreError.invalid }
            try brain.insertEvidence(evidence, db: db)
            try db.execute(sql: "INSERT INTO brain_turn_ref VALUES (?, ?, ?)", arguments: [turnID, evidence.id, row.id])
            try db.execute(sql: "UPDATE brain_turn SET assistant_id=? WHERE id=?", arguments: [evidence.id, turnID])
            try insertOperation("assistant", key: key, digest: digest, turnID: turnID, resultID: evidence.id, db: db)
            return evidence
        }
    }
    func outcome(_ outcome: BrainOutcome, sanitizedDescription: String) throws -> BrainOutcome {
        let key = try Self.key(outcome.id)
        guard outcome.recordedAt.isFinite else { throw BrainStoreError.invalid }
        let digest = BrainStore.digest(try BrainStore.encode(outcome))
        let saved = BrainOutcome(id: outcome.id, description: sanitizedDescription, status: outcome.status,
                                 recordedAt: outcome.recordedAt, evidenceIDs: outcome.evidenceIDs)
        return try brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: true)
            // Withdrawn operations remain denied even after their sources have been purged.
            let previous = try operation("outcome", key: key, db: db)
            _ = try brain.availableEvidence(outcome.evidenceIDs, db: db)
            if let old = previous {
                guard (old["request_hash"] as String?) == digest else { throw BrainStoreError.conflict }
                guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_turn_outcome WHERE principal=? AND operation_hash=?", arguments: [brain.authorization.principal, key]) else { throw BrainStoreError.denied }
                return try BrainStore.decode(BrainOutcome.self, payload)
            }
            try db.execute(sql: "INSERT INTO brain_turn_outcome(principal, operation_hash, payload, redacted) VALUES (?, ?, ?, ?)",
                           arguments: [brain.authorization.principal, key, try BrainStore.encode(saved), sanitizedDescription != outcome.description || sanitizedDescription.isEmpty])
            for id in outcome.evidenceIDs {
                try db.execute(sql: "INSERT INTO brain_turn_outcome_ref VALUES (?, ?, ?)", arguments: [brain.authorization.principal, key, id])
            }
            try insertOperation("outcome", key: key, digest: digest, turnID: nil, resultID: nil, db: db)
            return saved
        }
    }
}

extension BrainStore {
    /// Direct journal provenance participates in the existing erasure fixpoint, including short
    /// source texts. Assistant output depends on its input turn even though it is its own root.
    func expandTurnClosure(_ closure: inout BrainRetractionClosure, db: Database) throws -> Bool {
        let before = closure.evidenceIDs.count + closure.transcriptIDs.count + closure.turnIDs.count
        for turn in try Row.fetchAll(db, sql: "SELECT id, thread_id, subject FROM brain_turn") {
            let id: String = turn["id"]
            let refs = try Row.fetchAll(db, sql: "SELECT evidence_id, transcript_id FROM brain_turn_ref WHERE turn_id=?", arguments: [id])
            let claims = Set(try String.fetchAll(db, sql: "SELECT claim_id FROM brain_turn_claim WHERE turn_id=?", arguments: [id]))
            let evidence = Set(refs.map { $0["evidence_id"] as String })
            let transcripts = Set(refs.map { $0["transcript_id"] as String })
            guard closure.purgeEverything || closure.turnIDs.contains(id)
                || closure.threadIDs.contains(turn["thread_id"] as String)
                || closure.subjectIDs.contains(turn["subject"] as String)
                || !closure.evidenceIDs.isDisjoint(with: evidence)
                || !closure.transcriptIDs.isDisjoint(with: transcripts)
                || !closure.claimIDs.isDisjoint(with: claims) else { continue }
            closure.turnIDs.insert(id)
            closure.evidenceIDs.formUnion(evidence)
            closure.transcriptIDs.formUnion(transcripts)
        }
        return before != closure.evidenceIDs.count + closure.transcriptIDs.count + closure.turnIDs.count
    }
    func purgeTurnJournals(_ closure: BrainRetractionClosure, db: Database) throws {
        for id in closure.turnIDs {
            // Empty extraction commits have no claim/evidence IDs for the generic journal sweep.
            try db.execute(sql: "DELETE FROM brain_commit WHERE operation=? AND principal=(SELECT principal FROM brain_turn WHERE id=?)",
                           arguments: ["turn:" + id, id])
            try db.execute(sql: "UPDATE brain_turn_operation SET withdrawn=1, request_hash=NULL, turn_id=NULL, result_id=NULL WHERE turn_id=?", arguments: [id])
            for table in ["brain_turn_ref", "brain_turn_claim"] { try db.execute(sql: "DELETE FROM \(table) WHERE turn_id=?", arguments: [id]) }
            try db.execute(sql: "DELETE FROM brain_turn WHERE id=?", arguments: [id])
        }
        for row in try Row.fetchAll(db, sql: "SELECT principal, operation_hash FROM brain_turn_outcome") {
            let principal: String = row["principal"], key: String = row["operation_hash"]
            let refs = Set(try String.fetchAll(db, sql: "SELECT evidence_id FROM brain_turn_outcome_ref WHERE principal=? AND operation_hash=?", arguments: [principal, key]))
            guard closure.purgeEverything || !refs.isDisjoint(with: closure.evidenceIDs) else { continue }
            try db.execute(sql: "UPDATE brain_turn_operation SET withdrawn=1, request_hash=NULL, result_id=NULL WHERE principal=? AND namespace='outcome' AND operation_hash=?", arguments: [principal, key])
            try db.execute(sql: "DELETE FROM brain_turn_outcome_ref WHERE principal=? AND operation_hash=?", arguments: [principal, key])
            try db.execute(sql: "DELETE FROM brain_turn_outcome WHERE principal=? AND operation_hash=?", arguments: [principal, key])
        }
    }
}
