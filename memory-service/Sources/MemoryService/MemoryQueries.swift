import Foundation
import MemoryCore

/// Shared memory query logic, reused by the HTTP handlers AND the agent-gateway tools (DRY).
public enum MemoryQueries {

    // MARK: - Topic → Tag resolution

    /// Resolve a natural-language topic to the nearest canonical tag.
    /// Strategy: exact case-insensitive match first; if that fails AND an embedder is available,
    /// nearest-neighbour cosine ≤ 0.2 (strong semantic overlap); else nil.
    /// Exposed separately so callers that need the resolved tag string (e.g. the byTopic
    /// handler which must return `{tag, nodes}`) can obtain it without re-running resolution.
    public static func resolveTag(_ topic: String, store: MemoryStore, embedder: (any Embedder)?) -> String? {
        let vocab = (try? store.distinctTags()) ?? []

        // 1. Exact case-insensitive match.
        if let exact = vocab.first(where: { $0.caseInsensitiveCompare(topic) == .orderedSame }) {
            return exact
        }

        // 2. Embedding nearest-neighbour with cosine distance ≤ 0.2 (strong semantic overlap).
        // O(|vocab|) embed calls — fine at personal-memory scale (tens of tags).
        guard let tv = try? embedder?.embed(topic) else { return nil }
        var best: (tag: String, dist: Double)?
        for t in vocab {
            guard let v = try? embedder?.embed(t) else { continue }
            let d = MemoryStore.cosineDistance(tv, v)
            if best == nil || d < best!.dist { best = (t, d) }
        }
        if let b = best, b.dist <= 0.2 { return b.tag }
        return nil
    }

    /// All nodes carrying a resolved tag, capped at `limit`. The shared fetch used by BOTH the
    /// byTopic handler (which needs the resolved tag string for its `{tag, nodes}` response) and
    /// `nodesForTopic` — so neither path duplicates the fetch.
    public static func nodesForTag(_ tag: String, store: MemoryStore, limit: Int) -> [Node] {
        let ids = (try? store.nodesWithTag(tag)) ?? []
        return ids.prefix(limit).compactMap { try? store.node(id: $0) }
    }

    /// Resolve a natural-language topic to a canonical tag (exact case-insensitive, else
    /// embedding cosine ≤ 0.2), then return ALL nodes carrying it, capped at `limit`.
    /// Empty if no tag resolves. Best-effort (store/embedder failures collapse to []).
    public static func nodesForTopic(_ topic: String, store: MemoryStore, embedder: (any Embedder)?, limit: Int) -> [Node] {
        guard let tag = resolveTag(topic, store: store, embedder: embedder) else { return [] }
        return nodesForTag(tag, store: store, limit: limit)
    }

    // MARK: - Why (insight provenance)

    public struct WhyResult { public let insight: Node?; public let sources: [Node] }

    /// Locate the best insight matching a claim (FTS first, then semantic ≤ 0.35), and return
    /// its `derivesFrom` source memories.
    /// - FTS path: `searchFTS(claim, limit:10)` filtered to `kind == insight`.
    /// - Semantic fallback (only when embedder is available): `nearest(to:, k:20)` filtered to
    ///   `kind == insight && !deleted && distance ≤ 0.35`.
    public static func why(
        _ claim: String,
        store: MemoryStore,
        embedder: (any Embedder)?
    ) -> WhyResult {
        let insightKind = NodeKind.insight.rawValue

        // FTS path — keyword match, fast.
        var insight = ((try? store.searchFTS(query: claim, limit: 10)) ?? [])
            .first { $0.kind == insightKind }

        // Semantic fallback (wider net: k:20 ranks ALL kinds, most won't be insights).
        if insight == nil, let cv = try? embedder?.embed(claim) {
            let hits = (try? store.nearest(to: cv, k: 20)) ?? []
            for h in hits where h.distance <= 0.35 {
                if let n = try? store.node(id: h.id), n.kind == insightKind, !n.deleted {
                    insight = n; break
                }
            }
        }

        guard let ins = insight else { return WhyResult(insight: nil, sources: []) }

        let sourceIds = ((try? store.edges(from: ins.id)) ?? [])
            .filter { $0.relation == .derivesFrom }
            .map { $0.dstId }
        let sources = sourceIds.compactMap { try? store.node(id: $0) }
        return WhyResult(insight: ins, sources: sources)
    }
}
