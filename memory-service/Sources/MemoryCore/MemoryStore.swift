import Foundation
import GRDB

public enum SleepPhase: String, Codable, CaseIterable, Sendable { case nrem, summarize, detect, embeddings, cluster, tag, rem, reflect, compress, clarify, curate, shy }
public struct SleepCycleState: Equatable, Sendable {
    public var phase: SleepPhase
    public var episodeIds: [String]
    public var startedAt: Double
    public var focus: String = ""
    public init(phase: SleepPhase, episodeIds: [String], startedAt: Double, focus: String = "") {
        self.phase = phase; self.episodeIds = episodeIds; self.startedAt = startedAt; self.focus = focus
    }
}

public final class MemoryStore: @unchecked Sendable {
    public let dbQueue: DatabaseQueue
    public let embeddingDim: Int

    public init(url: URL? = nil, inMemory: Bool = false, embeddingDim: Int) throws {
        // (sqlite-vec deferred — see Phase 0 decision. Embeddings live in a regular
        //  `node_embedding(node_id, embedding BLOB)` table; nearest() does cosine in Swift.)
        self.embeddingDim = embeddingDim
        if inMemory {
            self.dbQueue = try DatabaseQueue()
        } else {
            self.dbQueue = try DatabaseQueue(path: (url ?? Self.defaultURL()).path)
        }
        try migrator.migrate(dbQueue)
    }

    /// Convenience initializer for the HTTP service: takes a file path string (or ":memory:")
    /// and creates the parent directory if needed. Used by handlers in Task 7+.
    public convenience init(path: String, embeddingDim: Int = 1024) throws {
        if path == ":memory:" {
            try self.init(inMemory: true, embeddingDim: embeddingDim)
        } else {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try self.init(url: url, inMemory: false, embeddingDim: embeddingDim)
        }
    }

    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.sqlite")
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1-core") { db in
            try db.create(table: "node") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("label", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("layer", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("lastSeenAt", .double).notNull()
                t.column("salience", .double).notNull()
                t.column("decayRate", .double).notNull()
                t.column("confidence", .text).notNull()
                t.column("mentionCount", .integer).notNull().defaults(to: 1)
                t.column("ttlExpiresAt", .double)
                t.column("sourceRef", .text)
                t.column("origin", .text).notNull()
                t.column("serverId", .text)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("extra", .text)
            }
            try db.create(indexOn: "node", columns: ["kind"])
            try db.create(indexOn: "node", columns: ["layer"])
            try db.create(indexOn: "node", columns: ["ttlExpiresAt"])
            try db.create(indexOn: "node", columns: ["lastSeenAt"])

            try db.create(table: "edge") { t in
                t.primaryKey("id", .text)
                t.column("srcId", .text).notNull().indexed()
                t.column("dstId", .text).notNull().indexed()
                t.column("relation", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 1)
                t.column("confidence", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("extra", .text)
            }

            try db.create(virtualTable: "node_fts", using: FTS5()) { t in
                t.column("node_id")  // unindexed key
                t.column("label")
                t.column("body")
            }

            // Embeddings: regular table (BLOB float32 LE). KNN = cosine in Swift (Task 3.2).
            // (If sqlite-vec is integrated later, swap this for a vec0 virtual table; callers unchanged.)
            try db.create(table: "node_embedding") { t in
                t.primaryKey("node_id", .text)
                t.column("embedding", .blob).notNull()
            }
        }
        m.registerMigration("v2-sleep") { db in
            try db.create(table: "sleep_cycle") { t in
                t.primaryKey("id", .integer)         // always 1
                t.column("phase", .text).notNull()
                t.column("episodeIds", .text).notNull()  // JSON array
                t.column("startedAt", .double).notNull()
            }
        }
        m.registerMigration("v3-sleep-focus") { db in
            try db.alter(table: "sleep_cycle") { t in
                t.add(column: "focus", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v4-transcript") { db in
            try db.create(table: "transcript") { t in
                t.primaryKey("id", .text)
                t.column("threadId", .text).notNull()
                t.column("turnIndex", .integer).notNull()
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("consolidated", .boolean).notNull().defaults(to: false)
            }
            try db.create(indexOn: "transcript", columns: ["threadId", "createdAt"])
            try db.create(indexOn: "transcript", columns: ["consolidated"])
        }
        m.registerMigration("v5-purge-conversation-nodes") { db in
            try MemoryStore.deleteConversationNodes(db)
        }
        m.registerMigration("v6-service-config") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS service_config (
                    id TEXT PRIMARY KEY NOT NULL,
                    provider TEXT NOT NULL,
                    baseURL TEXT NOT NULL,
                    model TEXT NOT NULL,
                    apiKeyCipher BLOB
                )
                """)
        }
        m.registerMigration("v7-transcript-embedding") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS transcript_embedding (
                    turn_id TEXT PRIMARY KEY NOT NULL,
                    embedding BLOB NOT NULL
                )
                """)
        }
        m.registerMigration("v8-transcript-seq") { db in
            try db.alter(table: "transcript") { t in
                t.add(column: "seq", .integer).notNull().defaults(to: 0)
            }
            // Backfill per-thread 1..N (prod transcript is empty post-reset; this handles dev DBs).
            try db.execute(sql: """
                WITH ordered AS (
                    SELECT id, ROW_NUMBER() OVER (PARTITION BY threadId ORDER BY createdAt ASC, turnIndex ASC, id ASC) AS rn
                    FROM transcript
                )
                UPDATE transcript SET seq = (SELECT rn FROM ordered WHERE ordered.id = transcript.id)
                """)
            try db.create(indexOn: "transcript", columns: ["threadId", "seq"])
        }
        m.registerMigration("v9-node-tags") { db in
            try db.create(table: "node_tags") { t in
                t.column("node_id", .text).notNull()
                t.column("tag", .text).notNull()
                t.primaryKey(["node_id", "tag"])
            }
            try db.create(indexOn: "node_tags", columns: ["tag"])
        }
        m.registerMigration("v10-connection-services") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS connection_services (
                    id TEXT PRIMARY KEY NOT NULL,
                    payloadCipher BLOB NOT NULL,
                    updatedAt REAL NOT NULL
                )
                """)
        }
        m.registerMigration("v11-brain-store") { db in
            try db.execute(sql: """
                CREATE TABLE brain_meta (id INTEGER PRIMARY KEY CHECK (id=1), revision INTEGER NOT NULL, owner TEXT);
                INSERT INTO brain_meta VALUES (1, 0, NULL);
                CREATE TABLE brain_evidence (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL);
                CREATE TABLE brain_evidence_operations (principal TEXT NOT NULL, operation TEXT NOT NULL, payload TEXT NOT NULL, evidence_id TEXT NOT NULL, PRIMARY KEY(principal, operation));
                CREATE TABLE brain_claim (id TEXT PRIMARY KEY NOT NULL, subject TEXT NOT NULL, predicate TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL);
                CREATE INDEX brain_claim_subject ON brain_claim(subject, revision);
                CREATE TABLE brain_commit (principal TEXT NOT NULL, operation TEXT NOT NULL, payload TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(principal, operation));
                CREATE TABLE brain_projection (node_id TEXT PRIMARY KEY NOT NULL, claim_id TEXT NOT NULL UNIQUE, suppressed INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE brain_legacy_binding (node_id TEXT PRIMARY KEY NOT NULL, claim_id TEXT NOT NULL, subject TEXT NOT NULL, predicate TEXT NOT NULL, owner TEXT NOT NULL, retired INTEGER NOT NULL DEFAULT 0);
                """)
        }
        m.registerMigration("v12-brain-retraction") { db in
            // `brain_exclusion` holds identifiers only — never withdrawn content — so a restored
            // backup can be scrubbed without the store retaining what it erased.
            // `brain_forget_operations` is the idempotency journal, same shape as brain_commit.
            try db.execute(sql: """
                CREATE TABLE brain_exclusion (kind TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL, owner TEXT NOT NULL, PRIMARY KEY(kind, id));
                CREATE TABLE brain_forget_operations (principal TEXT NOT NULL, operation TEXT NOT NULL, scope TEXT NOT NULL, receipt TEXT NOT NULL, PRIMARY KEY(principal, operation));
                """)
        }
        m.registerMigration("v13-brain-exclusion-content") { db in
            // An exclusion keyed on the row id alone refuses every later write to that id, which
            // permanently bricks the deterministic ones (`self:user`, `hub:*`) and makes an
            // evidence correction under the original id impossible. Markers are re-keyed on
            // (kind, id, fingerprint) so only the withdrawn *content* is barred from returning.
            // A fingerprint is a one-way digest, so the table still holds no content. The old
            // table is replaced rather than altered because SQLite cannot widen a primary key;
            // v12 shipped in this same unreleased branch and no deployment ever held a row.
            try db.execute(sql: """
                DROP TABLE brain_exclusion;
                CREATE TABLE brain_exclusion (kind TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL, revision INTEGER NOT NULL, owner TEXT NOT NULL, PRIMARY KEY(kind, id, fingerprint));
                """)
        }
        m.registerMigration("v14-consolidation-receipts") { db in
            // A consolidation job owns a set of transcript turns, the evidence they were adapted
            // into, and the timezone its relative dates resolve in. A receipt records what one
            // phase of that job actually did. Both are keyed on ids the engine can recompute
            // deterministically, so a process that resumes after a crash finds its own work
            // instead of redoing it. Neither table holds conversation text: `code`/`stage` come
            // from a fixed vocabulary the engine writes itself.
            try db.execute(sql: """
                CREATE TABLE consolidation_job (
                    id TEXT PRIMARY KEY NOT NULL,
                    phase TEXT NOT NULL,
                    transcriptIds TEXT NOT NULL,
                    evidenceIds TEXT NOT NULL,
                    timeZoneId TEXT NOT NULL,
                    startedAt REAL NOT NULL,
                    completedAt REAL
                );
                CREATE TABLE consolidation_receipt (
                    job_id TEXT NOT NULL,
                    operation TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    committed INTEGER NOT NULL DEFAULT 0,
                    refused INTEGER NOT NULL DEFAULT 0,
                    stage TEXT,
                    retryable INTEGER NOT NULL DEFAULT 0,
                    attempts INTEGER NOT NULL DEFAULT 1,
                    at REAL NOT NULL,
                    PRIMARY KEY(job_id, operation)
                );
                """)
        }
        m.registerMigration("v15-consolidation-unresolved") { db in
            // How many input turns a receipt left un-absorbed. Without it a receipts-only reader
            // sees "job committed" for a cycle that kept turns back, which is the same
            // in-memory-only blind spot that let a resumed cycle mark failed units consolidated.
            try db.execute(sql: """
                ALTER TABLE consolidation_receipt ADD COLUMN unresolved INTEGER NOT NULL DEFAULT 0
                """)
        }
        m.registerMigration("v16-transcript-sequence-counter") { db in
            try db.execute(sql: """
                CREATE TABLE transcript_sequence (threadId TEXT PRIMARY KEY NOT NULL, lastSeq INTEGER NOT NULL);
                INSERT INTO transcript_sequence(threadId, lastSeq)
                    SELECT threadId, MAX(seq) FROM transcript GROUP BY threadId;
                """)
        }
        m.registerMigration("v17-brain-turn-journal") { db in
            try db.execute(sql: """
                CREATE TABLE brain_turn (
                    id TEXT PRIMARY KEY NOT NULL, principal TEXT NOT NULL,
                    thread_id TEXT NOT NULL, subject TEXT NOT NULL,
                    source_id TEXT NOT NULL, transcript_id TEXT NOT NULL,
                    state TEXT NOT NULL, updates TEXT, has_pending BOOLEAN NOT NULL,
                    receipt TEXT, assistant_id TEXT
                );
                CREATE TABLE brain_turn_operation (
                    principal TEXT NOT NULL, namespace TEXT NOT NULL,
                    operation_hash TEXT NOT NULL, request_hash TEXT,
                    turn_id TEXT, result_id TEXT, withdrawn BOOLEAN NOT NULL,
                    PRIMARY KEY(principal, namespace, operation_hash)
                );
                CREATE TABLE brain_turn_ref (
                    turn_id TEXT NOT NULL, evidence_id TEXT NOT NULL, transcript_id TEXT NOT NULL,
                    PRIMARY KEY(turn_id, evidence_id)
                );
                CREATE TABLE brain_turn_claim (
                    turn_id TEXT NOT NULL, claim_id TEXT NOT NULL, PRIMARY KEY(turn_id, claim_id)
                );
                CREATE TABLE brain_turn_outcome (
                    principal TEXT NOT NULL, operation_hash TEXT NOT NULL,
                    payload TEXT NOT NULL, redacted BOOLEAN NOT NULL,
                    PRIMARY KEY(principal, operation_hash)
                );
                CREATE TABLE brain_turn_outcome_ref (
                    principal TEXT NOT NULL, operation_hash TEXT NOT NULL, evidence_id TEXT NOT NULL,
                    PRIMARY KEY(principal, operation_hash, evidence_id)
                );
                """)
        }
        m.registerMigration("v18-conversation-state") { db in
            try db.execute(sql: """
                CREATE TABLE brain_conversation_segment (
                    id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL,
                    revision INTEGER NOT NULL, payload TEXT NOT NULL
                );
                CREATE INDEX brain_conversation_thread ON brain_conversation_segment(thread_id);
                CREATE TABLE brain_conversation_source (
                    segment_id TEXT NOT NULL REFERENCES brain_conversation_segment(id) ON DELETE CASCADE,
                    evidence_id TEXT NOT NULL, transcript_id TEXT, fingerprint TEXT NOT NULL,
                    PRIMARY KEY(segment_id, evidence_id)
                );
                """)
        }
        m.registerMigration("v19-agent-identity") { db in
            // The agent's identity core is an operation store of its own, separate from claims.
            //
            // `brain_identity_revision` holds the personal part — a custom display name, a typed
            // character — as an append-only series of deltas stamped with the brain revision that
            // minted them, the revision they descend from and the identity generation they belong
            // to. `brain_identity_source` is the complete support set of each revision, so a
            // withdrawn source takes its revision and that revision's descendants with it.
            //
            // `brain_identity_operation` is the idempotency journal, same shape as the turn
            // journal: a hashed operation key, the request fingerprint and the stored result. On
            // erasure the fingerprint and the result are nulled and `withdrawn` is set, leaving a
            // row that holds no payload but still refuses a replay of the withdrawn operation ID.
            //
            // `brain_identity_meta.generation` is bumped whenever a retraction clears custom
            // history, so a revision row restored from a stale backup belongs to a dead generation
            // and can neither be read as current nor be the target of a revert.
            try db.execute(sql: """
                CREATE TABLE brain_identity_meta (id INTEGER PRIMARY KEY CHECK (id=1), generation INTEGER NOT NULL);
                INSERT INTO brain_identity_meta VALUES (1, 0);
                CREATE TABLE brain_identity_revision (
                    agent_id TEXT NOT NULL, revision INTEGER NOT NULL,
                    generation INTEGER NOT NULL, parent_revision INTEGER,
                    payload TEXT NOT NULL,
                    PRIMARY KEY(agent_id, revision)
                );
                CREATE TABLE brain_identity_source (
                    agent_id TEXT NOT NULL, revision INTEGER NOT NULL, evidence_id TEXT NOT NULL,
                    PRIMARY KEY(agent_id, revision, evidence_id)
                );
                CREATE TABLE brain_identity_operation (
                    principal TEXT NOT NULL, operation_hash TEXT NOT NULL,
                    request_hash TEXT, result TEXT, withdrawn BOOLEAN NOT NULL DEFAULT 0,
                    agent_id TEXT, revision INTEGER,
                    PRIMARY KEY(principal, operation_hash)
                );
                """)
        }
        m.registerMigration("v20-agent-identity-generation") { db in
            // The generation counter became per-agent. One global counter meant a forget that
            // touched one agent's identity chain had to re-stamp every agent's surviving rows to
            // keep them readable — and re-stamping rows a forget never named is indistinguishable,
            // from the outside, from moving them. Keying the counter by agent lets a forget raise
            // the floor for exactly the chain it reached and leave every other chain where it is.
            //
            // `brain_identity_meta.generation` stays, as the floor for an agent that has no row of
            // its own yet, so an identity minted after a whole-store erasure cannot land in a dead
            // generation. Existing agents are seeded from that same floor, which is the value their
            // rows were already stamped with, so this migration changes no reachable state.
            try db.execute(sql: """
                CREATE TABLE brain_identity_generation (
                    agent_id TEXT PRIMARY KEY, generation INTEGER NOT NULL
                );
                INSERT INTO brain_identity_generation(agent_id, generation)
                    SELECT DISTINCT r.agent_id, (SELECT generation FROM brain_identity_meta WHERE id=1)
                    FROM brain_identity_revision r;
                """)
        }
        m.registerMigration("v21-erased-correction-disposition") { db in
            // Live chains keep their existing source-visibility rules. At erasure, retain
            // only the predecessor assertion's disposition, never the correction's content.
            // Chains erased before this migration cannot be reconstructed without their data.
            try db.execute(sql: """
                CREATE TABLE brain_supersession_disposition (
                    predecessor_id TEXT NOT NULL,
                    assertion_fingerprint TEXT NOT NULL,
                    effective_at DOUBLE NOT NULL,
                    recorded_at DOUBLE NOT NULL,
                    revision INTEGER NOT NULL,
                    PRIMARY KEY(predecessor_id, assertion_fingerprint, revision)
                );
                """)
        }
        m.registerMigration("v22-procedure-versions") { db in
            try db.execute(sql: """
                CREATE TABLE brain_procedure_version (
                    principal TEXT NOT NULL, id TEXT NOT NULL, version INTEGER NOT NULL,
                    payload TEXT NOT NULL,
                    PRIMARY KEY(principal, id, version)
                );
                CREATE TABLE brain_procedure_attestation (
                    principal TEXT NOT NULL, id TEXT NOT NULL, version INTEGER NOT NULL,
                    environment TEXT NOT NULL, validated_at DOUBLE NOT NULL,
                    PRIMARY KEY(principal, id, version, environment)
                );
                CREATE TABLE brain_procedure_attestation_ref (
                    principal TEXT NOT NULL, id TEXT NOT NULL, version INTEGER NOT NULL,
                    environment TEXT NOT NULL, evidence_id TEXT NOT NULL,
                    PRIMARY KEY(principal, id, version, environment, evidence_id)
                );
                CREATE TABLE brain_procedure_sequence (
                    principal TEXT NOT NULL, id TEXT NOT NULL, last_version INTEGER NOT NULL,
                    PRIMARY KEY(principal, id)
                );
                CREATE TABLE brain_procedure_ref (
                    principal TEXT NOT NULL, id TEXT NOT NULL, version INTEGER NOT NULL,
                    evidence_id TEXT NOT NULL,
                    PRIMARY KEY(principal, id, version, evidence_id)
                );
                """)
        }
        m.registerMigration("v23-prospective") { db in
            try db.execute(sql: """
                CREATE TABLE task_observation (principal TEXT NOT NULL, operation TEXT NOT NULL, task_id TEXT NOT NULL, source_id TEXT NOT NULL, source_version INTEGER NOT NULL, observed_at DOUBLE NOT NULL, status TEXT NOT NULL, evidence_id TEXT NOT NULL, attribution TEXT NOT NULL, disposition TEXT NOT NULL, PRIMARY KEY(principal, operation));
                CREATE TABLE prospective_state (principal TEXT NOT NULL, candidate_id TEXT NOT NULL, deferred_until DOUBLE, resolution_evidence TEXT, PRIMARY KEY(principal, candidate_id));
                CREATE TABLE prospective_delivery (principal TEXT NOT NULL, candidate_id TEXT NOT NULL, delivery_id TEXT NOT NULL, state TEXT NOT NULL, PRIMARY KEY(principal, candidate_id, delivery_id));
                """)
        }
        m.registerMigration("v24-embedding-index") { db in
            try Self.createEmbeddingIndexSchema(db)
        }
        return m
    }

    // Only fields that can change a prospective proposal contribute to its revision.
    struct ProspectiveSourceFingerprint: Encodable {
        let id: String, kind: String, label: String, body: String, origin: Origin
        let status: String?, date: String?, sourceRef: String?, expiresAt: Double?
        let deleted: Bool
    }
    static func prospectiveFingerprint(_ node: Node?) -> String? {
        guard let node, [NodeKind.task.rawValue, NodeKind.followUp.rawValue, NodeKind.clarification.rawValue].contains(node.kind) else { return nil }
        let attrs = NodeAttributes.from(node.extra)
        let value = ProspectiveSourceFingerprint(id: node.id, kind: node.kind, label: node.label, body: node.body, origin: node.origin, status: attrs.status, date: attrs.date, sourceRef: node.sourceRef, expiresAt: node.ttlExpiresAt, deleted: node.deleted)
        return (try? BrainStore.encode(value)).map(BrainStore.digest)
    }

    // MARK: CRUD

    /// Write a node, optionally together with the consolidation checkpoint that accounts for it.
    ///
    /// `checkpoint` is persisted inside this same transaction, so a crash cannot leave the content
    /// stored without the receipt that says so — which is what makes a replay a no-op instead of a
    /// second reinforcement.
    public func upsert(_ node: Node, checkpoint: ConsolidationCheckpoint? = nil) throws {
        try upsert(node, checkpoint: checkpoint, embeddingRevision: nil)
    }

    func upsert(_ node: Node, checkpoint: ConsolidationCheckpoint?, embeddingRevision: Int64?) throws {
        let savedNode = try dbQueue.write { db in
            try Self.requireEmbeddingRevision(embeddingRevision, db: db)
            return try Self.writeNode(node, checkpoint: checkpoint, db: db)
        }
        // Auto-link to kind hub so the graph stays navigable from a single anchor per kind.
        // Skips hub-kind nodes themselves and free-form kinds outside the NodeKind enum.
        // Failures are swallowed: a missing hub link is not worth aborting an upsert.
        if !savedNode.deleted { try? linkToHub(nodeId: savedNode.id, kindRaw: savedNode.kind) }
    }
    static func requireEmbeddingRevision(_ embeddingRevision: Int64?, db: Database) throws {
        if let embeddingRevision,
           try Int64.fetchOne(db, sql: "SELECT revision FROM embedding_index_pointer WHERE id = 1") != embeddingRevision {
            throw EmbeddingIndexError.staleRevision
        }
    }

    @discardableResult
    static func writeNode(_ node: Node, checkpoint: ConsolidationCheckpoint? = nil, db: Database) throws -> Node {
        var node = node
        let previousNode = try Node.fetchOne(db, key: node.id)
        if let previousNode, previousNode.kind == NodeKind.task.rawValue {
            node.kind = previousNode.kind
            if previousNode.deleted { node.deleted = true }
        }
        // Merge event attributes under the write lock: ordinary writers may omit bridge keys.
        if node.kind == NodeKind.event.rawValue, let previous = try Node.fetchOne(db, key: node.id), previous.kind == node.kind {
            func object(_ value: String?) -> [String: Any] {
                guard let value, let data = value.data(using: .utf8) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            let old = object(previous.extra); let incoming = object(node.extra)
            var merged = old
            for key in ["status", "horizon", "date", "startAt", "endAt", "allDay", "location", "canonicalKey"] { merged.removeValue(forKey: key) }
            for (key, value) in incoming { merged[key] = value }
            // Existing bridge identity cannot be rolled back by a stale ordinary node copy.
            for key in ["appleEventId", "appleOccurrenceAt", "source", "calendarSourceType"] {
                if let value = old[key] { merged[key] = value }
            }
            // A content stamp belongs to this transaction, not a caller's stale node copy.
            let before = NodeAttributes.from(previous.extra); let after = NodeAttributes.from(node.extra)
            let changed = previous.label != node.label || before.startAt != after.startAt || before.endAt != after.endAt || before.allDay != after.allDay || before.location != after.location
            if changed { merged["contentUpdatedAt"] = Date().timeIntervalSince1970 }
            else if let stamp = old["contentUpdatedAt"] { merged["contentUpdatedAt"] = stamp }
            else { merged.removeValue(forKey: "contentUpdatedAt") }
            node.extra = (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        }
        if node.kind == NodeKind.task.rawValue, let previous = try Node.fetchOne(db, key: node.id), previous.kind == node.kind {
            func taskObject(_ value: String?) -> [String: Any] {
                guard let value, let data = value.data(using: .utf8) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            let old = taskObject(previous.extra)
            var merged = old
            for (key, value) in taskObject(node.extra) where key != "status" { merged[key] = value }
            if let status = old["status"] { merged["status"] = status } else { merged.removeValue(forKey: "status") }
            node.extra = merged.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        }
        if node.kind == NodeKind.event.rawValue, try Node.fetchOne(db, key: node.id) == nil {
            var object = node.extra.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if object["contentUpdatedAt"] == nil {
                object["contentUpdatedAt"] = Date().timeIntervalSince1970
                node.extra = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
        let managed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM brain_projection WHERE node_id=? UNION ALL SELECT 1 FROM brain_legacy_binding WHERE node_id=?)", arguments: [node.id, node.id]) ?? false
        guard !managed else { throw BrainStoreError.denied }
        // Retracted content stays retracted: a stale client or backup cannot write the same
        // body back under the same id. A different body under that id is a new record, so the
        // deterministic ids (self:user, hub:*) stay writable after a retraction.
        guard !(try BrainStore.isExcluded(db, kind: .node, id: node.id,
                                          fingerprint: BrainStore.nodeFingerprint(node))) else {
            throw BrainStoreError.denied
        }
        if Self.prospectiveFingerprint(previousNode) != Self.prospectiveFingerprint(node) { try BrainStore.advanceRevision(db) }
        try node.save(db)
        try db.execute(sql: "DELETE FROM node_fts WHERE node_id = ?", arguments: [node.id])
        if node.deleted {
            try db.execute(sql: "DELETE FROM node_embedding WHERE node_id = ?", arguments: [node.id])
        } else {
            try db.execute(sql: "INSERT INTO node_fts(node_id, label, body) VALUES (?, ?, ?)",
                           arguments: [node.id, node.label, node.body])
        }
        if let checkpoint {
            try Self.writeReceipt(db, jobID: checkpoint.jobID, operationID: checkpoint.operationID,
                                  phase: checkpoint.phase, outcome: .committed, committed: 1,
                                  refused: 0, unresolved: 0, stage: nil, retryable: false,
                                  at: checkpoint.at)
        }
        return node
    }

    public func upsert(_ edge: Edge) throws { try dbQueue.write { try edge.save($0) } }
    public func node(id: String) throws -> Node? { try dbQueue.read { try Node.fetchOne($0, key: id) } }
    /// Returns live, non-structural nodes by default. Pass `includeHubs: true` for the graph view
    /// (where structural anchors — hubs AND cluster anchors — should be visible). Pass
    /// `includeDeleted: true` for sweep inspection. Most callers (recall, coreMemories, dedup,
    /// reflect, associate) want semantic memory nodes only, so cluster anchors are excluded too.
    public func allNodes(includeDeleted: Bool = false, includeHubs: Bool = false) throws -> [Node] {
        try dbQueue.read { db in
            var q = Node.all()
            if !includeDeleted { q = q.filter(Column("deleted") == false) }
            if !includeHubs {
                q = q.filter(Column("kind") != HubKind.hub.rawValue && Column("kind") != NodeKind.cluster.rawValue)
            }
            return try q.fetchAll(db)
        }
    }

    /// Live cluster anchor nodes (ephemeral, rebuilt each cycle). Excluded from `allNodes()`
    /// (structural, not memories), so the tagging stage + graph view fetch them here.
    public func clusterNodes() throws -> [Node] {
        try dbQueue.read { db in
            try Node.filter(Column("kind") == NodeKind.cluster.rawValue && Column("deleted") == false).fetchAll(db)
        }
    }

    /// Total live non-hub node count — used by `/v1/consolidation/state` and tests.
    /// Excludes structural hub anchors so the count reflects actual memory items.
    public func nodeCount(includeHubs: Bool = false) throws -> Int {
        try dbQueue.read { db in
            let sql = includeHubs
                ? "SELECT COUNT(*) FROM node WHERE deleted = 0"
                : "SELECT COUNT(*) FROM node WHERE deleted = 0 AND kind != '\(HubKind.hub.rawValue)'"
            return try Int.fetchOne(db, sql: sql) ?? 0
        }
    }

    /// Most recent persisted sleep_cycle start (epoch seconds), or nil if no cycle has run yet.
    public func latestSleepCycle() throws -> Double? {
        try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT startedAt FROM sleep_cycle WHERE id=1")
        }
    }

    /// Always-relevant "identity core": who the user is and their permanent identity-layer
    /// facts, regardless of the current query. Identity-ONLY (no top-salience union) so the
    /// injected core stays small — query-relevant nodes (from MemoryRetriever) carry the rest.
    /// The singleton self:user node (kind == "self") is always returned first when present.
    public func coreMemories(limit: Int = 6) throws -> [Node] {
        try dbQueue.read { db in
            let selfN = try Node.fetchOne(db, key: selfUserID).flatMap { $0.deleted ? nil : $0 }
            let cap = selfN != nil ? max(0, limit - 1) : limit
            let others = try Node
                .filter(Column("layer") == MemoryLayer.identity.rawValue
                        && Column("deleted") == false
                        && Column("kind") != HubKind.hub.rawValue
                        && Column("id") != selfUserID)
                .order(Column("salience").desc).limit(cap).fetchAll(db)
            return selfN.map { [$0] + others } ?? others
        }
    }
    public func edges(from id: String) throws -> [Edge] {
        try dbQueue.read { try Edge.filter(Column("srcId") == id && Column("deleted") == false).fetchAll($0) }
    }
    public func allEdges() throws -> [Edge] {
        try dbQueue.read { try Edge.filter(Column("deleted") == false).fetchAll($0) }
    }

    /// Soft-delete every node whose id matches (handler `/memory/forget` by-id).
    public func forgetById(_ id: String) throws {
        try softDelete(nodeId: id)
    }

    /// Soft-delete every non-deleted node with the given label (case/whitespace canonicalized).
    /// Returns the number of nodes affected.
    @discardableResult
    public func forgetByLabel(_ label: String) throws -> Int {
        let key = MemoryText.dedupKey(label)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = try allNodes().filter {
            MemoryText.dedupKey($0.label) == key ||
            $0.label.lowercased().contains(trimmed) ||
            trimmed.contains($0.label.lowercased()) ||
            (!trimmed.isEmpty && $0.body.lowercased().contains(trimmed))
        }
        for n in matches { try softDelete(nodeId: n.id) }
        return matches.count
    }

    public func softDelete(nodeId: String) throws {
        try dbQueue.write { db in try Self.softDelete(nodeId: nodeId, db: db) }
    }

    static func softDelete(nodeId: String, db: Database) throws {
        if var node = try Node.fetchOne(db, key: nodeId), !node.deleted {
            let before = Self.prospectiveFingerprint(node); node.deleted = true
            if before != Self.prospectiveFingerprint(node) { try BrainStore.advanceRevision(db) }
        }
        try db.execute(sql: "UPDATE brain_projection SET suppressed=1 WHERE node_id=?", arguments: [nodeId])
        try db.execute(sql: "UPDATE node SET deleted=1, dirty=1, updatedAt=? WHERE id=?",
                       arguments: [Date().timeIntervalSince1970, nodeId])
        try db.execute(sql: "DELETE FROM node_fts WHERE node_id=?", arguments: [nodeId])
        try db.execute(sql: "DELETE FROM node_embedding WHERE node_id=?", arguments: [nodeId])
    }

    public func searchFTS(query: String, limit: Int) throws -> [Node] {
        try dbQueue.read { db in
            let pattern = FTS5Pattern(matchingAnyTokenIn: query)
            guard let p = pattern else { return [] }
            let ids = try String.fetchAll(db, sql: "SELECT node_id FROM node_fts WHERE node_fts MATCH ? LIMIT ?",
                                          arguments: [p.rawPattern, limit])
            return try ids.compactMap { try Node.fetchOne(db, key: $0) }.filter { !$0.deleted }
        }
    }

    public static func floatsToBlob(_ v: [Float]) -> Data { v.withUnsafeBytes { Data($0) } }

    // MARK: Sleep / consolidation
    public func loadSleepCycle() throws -> SleepCycleState? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT phase, episodeIds, startedAt, focus FROM sleep_cycle WHERE id=1") else { return nil }
            guard let phase = SleepPhase(rawValue: row["phase"]) else { return nil }
            let ids = (try? JSONDecoder().decode([String].self, from: Data((row["episodeIds"] as String).utf8))) ?? []
            return SleepCycleState(phase: phase, episodeIds: ids, startedAt: row["startedAt"], focus: row["focus"] ?? "")
        }
    }
    public func saveSleepCycle(_ s: SleepCycleState) throws {
        let ids = String(data: (try? JSONEncoder().encode(s.episodeIds)) ?? Data(), encoding: .utf8) ?? "[]"
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sleep_cycle(id, phase, episodeIds, startedAt, focus) VALUES (1, ?, ?, ?, ?)",
                           arguments: [s.phase.rawValue, ids, s.startedAt, s.focus])
        }
    }
    public func clearSleepCycle() throws { try dbQueue.write { try $0.execute(sql: "DELETE FROM sleep_cycle WHERE id=1") } }

    /// Episodic conversation nodes not yet consolidated (status field in extra JSON != "consolidated").
    public func unconsolidatedEpisodes() throws -> [Node] {
        try allNodes().filter { $0.kind == NodeKind.conversation.rawValue
            && (episodeStatus(from: $0) ?? "closed") != "consolidated" }
    }
    public func markEpisodesConsolidated(ids: [String]) throws {
        for id in ids {
            guard var n = try node(id: id) else { continue }
            // Patch or add the status field in the extra JSON blob.
            var dict = (n.extra.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            dict["status"] = "consolidated"
            n.extra = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
            n.updatedAt = Date().timeIntervalSince1970; n.dirty = true
            try upsert(n)
        }
    }
    /// Reads the `status` string from a conversation node's extra JSON (replaces EpisodeRecorder.meta).
    private func episodeStatus(from node: Node) -> String? {
        guard let s = node.extra, let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["status"] as? String
    }
    /// Pending actionable + conversational follow-ups (task/plan/follow_up nodes whose
    /// NodeAttributes.status is "pending" or unset), most recent first, capped.
    private func followUpVisible(_ node: Node, owner: String?, now: Double, db: Database) throws -> Bool {
        guard let owner else { return true }
        let row = try Row.fetchOne(db, sql: "SELECT deferred_until, resolution_evidence FROM prospective_state WHERE principal=? AND candidate_id=?", arguments: [owner, node.id])
        if let until: Double = row?["deferred_until"], until > now { return false }
        if let evidence: String = row?["resolution_evidence"], try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM brain_evidence WHERE id=?)", arguments: [evidence]) == true { return false }
        return true
    }
    public func pendingFollowUps(limit: Int = 5) throws -> [Node] {
        try dbQueue.read { db in
            let owner = try String.fetchOne(db, sql: "SELECT owner FROM brain_meta WHERE id=1")
            let kinds: Set<String> = [NodeKind.task.rawValue, NodeKind.plan.rawValue, NodeKind.followUp.rawValue]
            let nodes = try Node.filter(Column("deleted") == false).fetchAll(db)
            let now = Date().timeIntervalSince1970
            return try nodes.filter { node in
                guard kinds.contains(node.kind), (NodeAttributes.from(node.extra).status ?? "pending") == "pending" else { return false }
                return try followUpVisible(node, owner: owner, now: now, db: db)
            }.sorted { $0.lastSeenAt > $1.lastSeenAt }.prefix(limit).map { $0 }
        }
    }
    public func pendingClarifications(limit: Int = 5) throws -> [Node] {
        try dbQueue.read { db in
            let owner = try String.fetchOne(db, sql: "SELECT owner FROM brain_meta WHERE id=1")
            let rows = try Node.filter(Column("kind") == NodeKind.clarification.rawValue && Column("deleted") == false)
                .order(Column("createdAt").desc).fetchAll(db)
            let now = Date().timeIntervalSince1970
            return try rows.filter { node in
                guard NodeAttributes.from(node.extra).status != "done" else { return false }
                return try followUpVisible(node, owner: owner, now: now, db: db)
            }.prefix(limit).map { $0 }
        }
    }

    /// Pending tasks/plans whose absolute date (extra.date, yyyy-MM-dd) is today or past.
    public func dueReminders(today: String) throws -> [Node] {
        let kinds: Set<String> = [NodeKind.task.rawValue, NodeKind.plan.rawValue]
        return try allNodes().filter {
            kinds.contains($0.kind)
            && ["pending", "in-progress", "blocked"].contains(NodeAttributes.from($0.extra).status ?? "pending")
            && (NodeAttributes.from($0.extra).date.map { $0 <= today } ?? false)
        }
    }

    public func distinctKinds() throws -> [String] {
        try dbQueue.read { try String.fetchAll($0, sql: "SELECT DISTINCT kind FROM node WHERE deleted=0") }
    }
    public func reassignKind(from: String, to: String) throws {
        guard from != NodeKind.task.rawValue, from != to else { return }
        try dbQueue.write { db in
            let rows = try Node.filter(Column("kind") == from && Column("deleted") == false).fetchAll(db)
            let affectsProspective = rows.contains { node in
                var changed = node; changed.kind = to
                return Self.prospectiveFingerprint(node) != Self.prospectiveFingerprint(changed)
            }
            if affectsProspective { try BrainStore.advanceRevision(db) }
            try db.execute(sql: "UPDATE node SET kind=?, dirty=1, updatedAt=? WHERE kind=? AND deleted=0", arguments: [to, Date().timeIntervalSince1970, from])
        }
    }
    /// Delete `conversation`/`episode` nodes and their FTS rows, embeddings, and dangling edges.
    /// Shared by `purgeConversationNodes()` and the `v5-purge-conversation-nodes` migration.
    private static func deleteConversationNodes(_ db: Database) throws {
        let ids = try String.fetchAll(db, sql: "SELECT id FROM node WHERE kind IN ('conversation','episode')")
        guard !ids.isEmpty else { return }
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let a = StatementArguments(ids)
        try db.execute(sql: "DELETE FROM node WHERE id IN (\(ph))", arguments: a)
        try db.execute(sql: "DELETE FROM node_fts WHERE node_id IN (\(ph))", arguments: a)
        try db.execute(sql: "DELETE FROM node_embedding WHERE node_id IN (\(ph))", arguments: a)
        try db.execute(sql: "DELETE FROM edge WHERE srcId IN (\(ph)) OR dstId IN (\(ph))",
                       arguments: StatementArguments(ids + ids))
    }

    /// One-time cleanup (M2d-1): raw turns are no longer graph nodes. Delete legacy
    /// `conversation`/`episode` nodes and their satellites. (Also run as migration v5.)
    public func purgeConversationNodes() throws {
        try dbQueue.write { try Self.deleteConversationNodes($0) }
    }

    /// Soft-delete edges whose endpoints are deleted/missing.
    public func pruneDanglingEdges() throws {
        let live = Set(try allNodes().map { $0.id })
        for e in try allEdges() where !(live.contains(e.srcId) && live.contains(e.dstId)) {
            try dbQueue.write { try $0.execute(sql: "UPDATE edge SET deleted=1, dirty=1, updatedAt=? WHERE id=?",
                                               arguments: [Date().timeIntervalSince1970, e.id]) }
        }
    }
}
