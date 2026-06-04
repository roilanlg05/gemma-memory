import Foundation

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
        let summaries = nodes.filter { $0.kind == NodeKind.summary.rawValue }
        let rest = nodes.filter { $0.kind != NodeKind.summary.rawValue }
        let lines = (summaries + rest).map { "- [\($0.kind)] \($0.label): \($0.body.isEmpty ? $0.label : $0.body)" }
        return "What you remember about the user (use if relevant):\n" + lines.joined(separator: "\n")
    }
}
