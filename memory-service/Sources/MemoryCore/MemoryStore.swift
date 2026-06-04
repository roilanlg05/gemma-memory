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
        return m
    }

    // MARK: CRUD
    public func upsert(_ node: Node) throws {
        try dbQueue.write { db in
            try node.save(db)
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id = ?", arguments: [node.id])
            try db.execute(sql: "INSERT INTO node_fts(node_id, label, body) VALUES (?, ?, ?)",
                           arguments: [node.id, node.label, node.body])
        }
        // Auto-link to kind hub so the graph stays navigable from a single anchor per kind.
        // Skips hub-kind nodes themselves and free-form kinds outside the NodeKind enum.
        // Failures are swallowed: a missing hub link is not worth aborting an upsert.
        try? linkToHub(nodeId: node.id, kindRaw: node.kind)
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
        let matches = try allNodes().filter { MemoryText.dedupKey($0.label) == key }
        for n in matches { try softDelete(nodeId: n.id) }
        return matches.count
    }

    public func softDelete(nodeId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE node SET deleted=1, dirty=1, updatedAt=? WHERE id=?",
                           arguments: [Date().timeIntervalSince1970, nodeId])
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id=?", arguments: [nodeId])
        }
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
    public func pendingFollowUps(limit: Int = 5) throws -> [Node] {
        let kinds: Set<String> = [NodeKind.task.rawValue, NodeKind.plan.rawValue, NodeKind.followUp.rawValue]
        return try allNodes()
            .filter { kinds.contains($0.kind) && (NodeAttributes.from($0.extra).status ?? "pending") == "pending" }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .prefix(limit).map { $0 }
    }
    public func pendingClarifications(limit: Int = 5) throws -> [Node] {
        let rows: [Node] = try dbQueue.read { db in
            try Node.filter(Column("kind") == NodeKind.clarification.rawValue && Column("deleted") == false)
                .order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
        return rows.filter { NodeAttributes.from($0.extra).status != "done" }
    }

    /// Pending tasks/plans whose absolute date (extra.date, yyyy-MM-dd) is today or past.
    public func dueReminders(today: String) throws -> [Node] {
        let kinds: Set<String> = [NodeKind.task.rawValue, NodeKind.plan.rawValue]
        return try allNodes().filter {
            kinds.contains($0.kind)
            && NodeAttributes.from($0.extra).status != "done"
            && (NodeAttributes.from($0.extra).date.map { $0 <= today } ?? false)
        }
    }

    public func distinctKinds() throws -> [String] {
        try dbQueue.read { try String.fetchAll($0, sql: "SELECT DISTINCT kind FROM node WHERE deleted=0") }
    }
    public func reassignKind(from: String, to: String) throws {
        try dbQueue.write { try $0.execute(sql: "UPDATE node SET kind=?, dirty=1, updatedAt=? WHERE kind=? AND deleted=0",
                                           arguments: [to, Date().timeIntervalSince1970, from]) }
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
