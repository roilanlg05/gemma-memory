import Foundation
import BrainContract
import GRDB

/// Hybrid associative recall: vector (semantic) + FTS (keyword) + recency + 1-hop graph
/// spreading-activation, ranked by similarity × salience × recency. Produces a compact
/// memory block to inject into the agent's system prompt (#18). Degrades to FTS+graph when
/// no embedder is available.
public final class MemoryRetriever: @unchecked Sendable {
    private let store: MemoryStore
    private let embedder: Embedder?

    public init(store: MemoryStore, embedder: Embedder?) {
        self.store = store
        self.embedder = embedder
    }

    /// Retrieve up to `k` relevant nodes for a query.
    public func retrieve(query: String, k: Int = 8, now: Double = Date().timeIntervalSince1970,
                         queryVector: [Float]? = nil) throws -> [Node] {
        let embedding = queryVector.map { IndexEmbedding(values: $0, version: nil) } ?? queryEmbedding(for: query)
        return try retrieve(query: query, k: k, now: now, queryEmbedding: embedding)
    }

    public func queryEmbedding(for query: String) -> IndexEmbedding? {
        guard let embedder, (try? store.canUseEmbeddingIndex(embedder.indexVersion)) == true else { return nil }
        return try? embedder.embedForIndex(query)
    }

    public func retrieve(query: String, k: Int = 8, now: Double = Date().timeIntervalSince1970,
                         queryEmbedding: IndexEmbedding?) throws -> [Node] {
        guard k > 0 else { return [] }
        var pool: [String: Node] = [:]
        var sim: [String: Double] = [:]

        // 1. Semantic lane shares the query embedding with transcript recall.
        if let queryEmbedding {
            for hit in (try? store.nearest(to: queryEmbedding, k: k * 2)) ?? [] {
                if let n = try store.node(id: hit.id), !n.deleted {
                    pool[n.id] = n
                    sim[n.id] = 1.0 / (1.0 + hit.distance)
                }
            }
        }
        // 2. FTS (keyword)
        for n in (try? store.searchFTS(query: query, limit: k * 2)) ?? [] {
            pool[n.id] = n
            sim[n.id] = max(sim[n.id] ?? 0, 0.6)
        }
        // 3. Graph spreading-activation: 1 hop from current matches.
        for id in Array(pool.keys) {
            for e in (try? store.edges(from: id)) ?? [] {
                if pool[e.dstId] == nil, let n = try store.node(id: e.dstId), !n.deleted {
                    pool[n.id] = n
                    sim[n.id] = 0.3 * (sim[id] ?? 0.5)
                }
            }
        }
        // 4. Rank: similarity × salience(eff) × recency.
        let scored = pool.values.map { n -> (Node, Double) in
            let eff = Decay.effectiveSalience(base: n.salience, decayRate: n.decayRate, elapsedSeconds: now - n.lastSeenAt)
            let recency = 1.0 / (1.0 + (now - n.lastSeenAt) / 86400.0)
            let s = (sim[n.id] ?? 0.1) * 0.6 + (eff / 10.0) * 0.25 + recency * 0.15
            return (n, s)
        }.sorted { $0.1 > $1.1 }
        var result = Array(scored.prefix(k).map { $0.0 })

        // 5. RC6: always union the identity core (name, top preferences, key people) so
        // meta-questions like "what do I like?" — which match no single entity by keyword or
        // vector — still recall the user's strong facts. Query-relevant nodes come first.
        var ids = Set(result.map { $0.id })
        for n in (try? store.coreMemories()) ?? [] where ids.insert(n.id).inserted {
            result.append(n)
        }
        return result
    }

    /// Compatibility for the existing owner-only save API. Legacy facts carry neither exact
    /// citation nor identity authority, and explicit scope/provenance cannot be widened here.
    public func gatewayLegacyContext(query: String, threadID: String, maximumBytes: Int = 768) throws -> String {
        let nodes = try store.searchFTS(query: String(query.prefix(512)), limit: 12) + store.coreMemories(limit: 6)
        let heading = "Relevant unverified legacy memories (context only, no identity or exact citation):"
        guard maximumBytes > heading.utf8.count else { return "" }
        var lines = [String]()
        var bytes = heading.utf8.count
        for node in try gatewayLegacyNodes(ids: nodes.map(\.id), threadID: threadID) {
            let line = "- [\(node.kind)] \(node.label): \(node.body)"
            guard line.utf8.count < maximumBytes - bytes else { continue }
            lines.append(line)
            bytes += 1 + line.utf8.count
        }
        return lines.isEmpty ? "" : ([heading] + lines).joined(separator: "\n")
    }

    public func gatewayLegacyNodes(ids: [String], threadID: String) throws -> [Node] {
        try store.dbQueue.read { db in
            var included = Set<String>()
            return try ids.compactMap { id in
                guard included.insert(id).inserted else { return nil }
                return try Self.eligibleLegacyNode(id: id, threadID: threadID, db: db)
            }
        }
    }

    public func gatewayLegacyTopics(threadID: String) throws -> [String] {
        try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT node_id, tag FROM node_tags ORDER BY tag, node_id LIMIT 2000")
            var eligible: [String: Bool] = [:]
            var tags = Set<String>()
            for row in rows {
                let id: String = row["node_id"]
                let isEligible = try eligible[id] ?? (Self.eligibleLegacyNode(id: id, threadID: threadID, db: db) != nil)
                eligible[id] = isEligible
                if isEligible { tags.insert(row["tag"] as String) }
            }
            return tags.sorted()
        }
    }

    private static func eligibleLegacyNode(id: String, threadID: String, db: Database) throws -> Node? {
        let eligibleKinds = [NodeKind.preference, .fact, .person, .place].map(\.rawValue)
        guard let node = try Node.fetchOne(db, key: id), !node.deleted,
              node.origin == .explicit, node.sourceRef == nil, eligibleKinds.contains(node.kind),
              !BrainIdentity.reservedSubjects.contains(node.id),
              try String.fetchOne(db, sql: "SELECT node_id FROM brain_projection WHERE node_id=?", arguments: [id]) == nil,
              try String.fetchOne(db, sql: "SELECT node_id FROM brain_legacy_binding WHERE node_id=? AND retired=1", arguments: [id]) == nil,
              Self.legacyScopeAdmits(node.extra, threadID: threadID),
              MemoryStore.mergeConflicts(in: node).allSatisfy({ $0.sourceRef == nil && Self.legacyScopeAdmits($0.extra, threadID: threadID) }) else { return nil }
        return node
    }

    private static func legacyScopeAdmits(_ extra: String?, threadID: String) -> Bool {
        guard let extra, !extra.isEmpty else { return true }
        guard let attrs = (try? JSONSerialization.jsonObject(with: Data(extra.utf8))) as? [String: Any] else { return false }
        func values(_ keys: [String]) -> Set<String>? {
            var result = Set<String>()
            for key in keys where attrs[key] != nil {
                guard let value = attrs[key] as? String, !value.isEmpty else { return nil }
                result.insert(value)
            }
            return result
        }
        guard let scopes = values(["scope", "accessScope", "access_scope"]),
              let threads = values(["threadID", "threadId", "thread_id", "chatId", "chat_id"]),
              let owners = values(["ownerID", "ownerId", "owner"]),
              let subjects = values(["subjectID", "subjectId", "subject"]) else { return false }
        return scopes.allSatisfy { $0 == "user" || ($0 == "thread" && threads == [threadID]) }
            && threads.allSatisfy { $0 == threadID } && owners.allSatisfy { $0 == ConsolidationEvidenceAdapter.ownerID }
            && subjects.allSatisfy { $0 == BrainIdentity.userID }
    }

    /// Vector lane for the brain's scoped recall. The caller supplies claims with live,
    /// authorized roots from the same transaction, so a legacy vector never grants access.
    static func sourceBoundVectorScores(_ query: IndexEmbedding, supported: Set<String>, db: Database) throws -> [String: Double] {
        let vector = query.values
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return [:] }
        let table: String
        let indexFilter: String
        let arguments: StatementArguments
        if let version = query.version {
            guard vector.count == version.dimension,
                  let indexID = try MemoryStore.activeEmbeddingIndexID(version, db: db) else { return [:] }
            table = "indexed_node_embedding"
            indexFilter = " AND e.index_id = ?"
            arguments = [indexID]
        } else {
            table = "node_embedding"
            indexFilter = ""
            arguments = []
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT p.claim_id, e.embedding FROM brain_projection p
            JOIN node n ON n.id=p.node_id AND n.deleted=0
            JOIN \(table) e ON e.node_id=p.node_id WHERE p.suppressed=0\(indexFilter)
            """, arguments: arguments)
        var scores = [String: Double]()
        while let row = try rows.next() {
            let id: String = row["claim_id"]
            guard supported.contains(id) else { continue }
            let distance = MemoryStore.cosineDistance(vector, MemoryStore.blobToFloats(row["embedding"]))
            if distance.isFinite, distance < 0.65 { scores[id] = min(1, 1 - distance) }
        }
        return scores
    }

    /// Render retrieved nodes as a compact injection block (empty string if none).
    /// Summaries (the "ruta") come first so the model gets the gist before individual facts.
    public func injectionBlock(for nodes: [Node]) -> String {
        guard !nodes.isEmpty else { return "" }
        // Only store-owned mapping rows can establish source-bound classification.
        guard let mapping = try? store.dbQueue.read({ db -> (Set<String>, Set<String>, [String: Node]) in
            let retired = Set(try String.fetchAll(db, sql: "SELECT node_id FROM brain_legacy_binding WHERE retired=1"))
            let projected = Set(try String.fetchAll(db, sql: "SELECT node_id FROM brain_projection"))
            let active = try Node.fetchAll(db, sql: "SELECT n.* FROM brain_projection p JOIN node n ON n.id=p.node_id WHERE n.deleted=0")
            return (retired, projected, Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) }))
        }) else { return "" }
        let allowed: [Node] = nodes.compactMap { node in
            guard !mapping.0.contains(node.id) else { return nil }
            if mapping.1.contains(node.id) { return mapping.2[node.id] }
            return node.deleted ? nil : node
        }
        let summaries = allowed.filter { $0.kind == NodeKind.summary.rawValue }
        let rest = allowed.filter { $0.kind != NodeKind.summary.rawValue }
        let formatter = ISO8601DateFormatter()
        func evidence(origin: Origin, confidence: Confidence, date: Double, source: String?) -> String {
            var label = "origin=\(origin.rawValue) confidence=\(confidence.rawValue) date=\(formatter.string(from: Date(timeIntervalSince1970: date)))"
            if let source { label += " source=\(source)" }
            return label
        }
        func scope(extra: String?, id: String? = nil) -> String {
            let object = extra.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var labels: [String] = []
            for (name, keys) in [("subject", ["subjectId", "subjectID", "subject"]),
                                  ("owner", ["ownerId", "ownerID", "owner"])] {
                let values = Set(keys.compactMap { object[$0] as? String }.filter { !$0.isEmpty }).sorted()
                if !values.isEmpty {
                    labels.append("\(name)=\(values.joined(separator: "|"))")
                } else if name == "subject" {
                    let reserved: Set<String> = [selfUserID, "self:agent", "relationship:user:agent"]
                    labels.append("subject=\(id.flatMap { reserved.contains($0) ? $0 : nil } ?? "unknown")")
                }
            }
            return labels.joined(separator: " ")
        }
        let lines = (summaries + rest).map { node in
            let conflicts = MemoryStore.mergeConflicts(in: node)
            let classification = mapping.1.contains(node.id) ? "source-bound classification, unverified; " : "unverified legacy, historical; do not assert as current; "
            let status = classification + (conflicts.isEmpty ? "" : "unresolved conflict; resolve before asserting; ")
            let provenance = evidence(origin: node.origin, confidence: node.confidence,
                                      date: MemoryStore.evidenceDate(for: node), source: node.sourceRef)
                + " " + scope(extra: node.extra, id: node.id)
            var line = "- [\(node.kind); \(status)\(provenance)] \(node.label): \(node.body.isEmpty ? node.label : node.body)"
            for alternative in conflicts {
                let provenance = evidence(origin: alternative.origin, confidence: alternative.confidence,
                                          date: alternative.updatedAt, source: alternative.sourceRef)
                    + " " + scope(extra: alternative.extra)
                line += "\n  alternative [\(provenance)]: \(alternative.body)"
            }
            return line
        }
        return "Relevant memories (use if relevant):\n" + lines.joined(separator: "\n")
    }
}
