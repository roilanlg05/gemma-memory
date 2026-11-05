import Foundation
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
        var pool: [String: Node] = [:]
        var sim: [String: Double] = [:]

        // 1. Vector (semantic) — reuse a precomputed query vector when provided (avoids a second
        // embedder round-trip when the caller already embedded the query).
        let qv = queryVector ?? (embedder.flatMap { try? $0.embed(query) })
        if let qv {
            for hit in (try? store.nearest(to: qv, k: k * 2)) ?? [] {
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
