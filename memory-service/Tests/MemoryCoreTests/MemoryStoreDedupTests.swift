import XCTest
@testable import MemoryCore

/// Returns identical vectors for any string containing the keyword, distinct otherwise →
/// deterministic semantic-dedup tests without NL assets.
private final class KeywordEmbedder: Embedder {
    let dimension = 4
    func embed(_ text: String) throws -> [Float] {
        let t = text.lowercased()
        if t.contains("messi") { return [1, 0, 0, 0] }
        if t.contains("sushi") { return [0, 1, 0, 0] }
        return [0, 0, 1, 0]
    }
}

/// Phase 2 Task 2.2 — dedup/merge + sweep. Self-contained (own helpers) to keep the
/// Phase 1 MemoryStoreTests file untouched.
final class MemoryStoreDedupTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }

    private func node(id: String = UUID().uuidString, kind: String = NodeKind.preference.rawValue, label: String = "sushi",
                      layer: MemoryLayer = .daily, ttl: Double? = nil, lastSeen: Double? = nil) -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: id, kind: kind, label: label, body: label, layer: layer,
                    createdAt: now, updatedAt: now, lastSeenAt: lastSeen ?? now, salience: 3,
                    decayRate: 0.001, confidence: .probable, mentionCount: 1, ttlExpiresAt: ttl,
                    sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testUpsertMergingReinforces() throws {
        let store = try makeStore()
        _ = try store.upsertMerging(node(label: "sushi"))
        _ = try store.upsertMerging(node(label: "sushi"))
        let nodes = try store.allNodes()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].mentionCount, 2)
    }

    func testDedupCanonicalAcrossPhrasings() throws {
        let store = try makeStore()
        _ = try store.upsertMerging(node(label: "me gusta el sushi"))
        _ = try store.upsertMerging(node(label: "Sushi"))
        let nodes = try store.allNodes()
        XCTAssertEqual(nodes.count, 1, "different phrasings of the same entity must merge; got: \(nodes.map { $0.label })")
    }

    func testPromotesToIdentityAtThreshold() throws {
        let store = try makeStore()
        for _ in 0..<3 { _ = try store.upsertMerging(node(kind: NodeKind.person.rawValue, label: "Juan")) }
        XCTAssertEqual(try store.allNodes().first?.layer, .identity)
    }

    func test_semantic_dedup_merges_phrasing_variants() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let emb = KeywordEmbedder()
        let now = Date().timeIntervalSince1970
        func cand(_ id: String, _ label: String) -> Node {
            Node(id: id, kind: NodeKind.preference.rawValue, label: label, body: label, layer: .daily, createdAt: now,
                 updatedAt: now, lastSeenAt: now, salience: 3, decayRate: Decay.defaultDecayRate(for: .daily),
                 confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit,
                 serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        let id1 = try store.upsertMergingSemantic(cand("a", "Messi"), embedding: try emb.embed("Messi"), embedder: emb)
        _ = try store.upsertMergingSemantic(cand("b", "likes Messi"), embedding: try emb.embed("likes Messi"), embedder: emb)
        _ = try store.upsertMergingSemantic(cand("c", "Messi fan"), embedding: try emb.embed("Messi fan"), embedder: emb)
        let prefs = try store.allNodes().filter { $0.kind == NodeKind.preference.rawValue }
        XCTAssertEqual(prefs.count, 1, "3 Messi phrasings must collapse to 1 node")
        XCTAssertEqual(prefs.first?.id, id1)
        XCTAssertEqual(prefs.first?.mentionCount, 3)
        XCTAssertGreaterThan(prefs.first!.salience, 3, "reinforced via EMA")
    }

    func test_semantic_dedup_keeps_distinct_entities_separate() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let emb = KeywordEmbedder()
        let now = Date().timeIntervalSince1970
        func cand(_ id: String, _ label: String) -> Node {
            Node(id: id, kind: NodeKind.preference.rawValue, label: label, body: label, layer: .daily, createdAt: now,
                 updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure,
                 mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                 dirty: true, deleted: false, extra: nil)
        }
        _ = try store.upsertMergingSemantic(cand("a", "Messi"), embedding: try emb.embed("Messi"), embedder: emb)
        _ = try store.upsertMergingSemantic(cand("b", "sushi"), embedding: try emb.embed("sushi"), embedder: emb)
        XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.preference.rawValue }.count, 2)
    }

    /// Fix 1: a same-kind near-duplicate ranked beyond the global top-8 (crowded out by closer
    /// other-kind vectors) must still merge. We insert 10 DISTINCT other-kind nodes whose vectors
    /// are nearer the query than the one same-kind node, then upsert a same-kind candidate at the
    /// identical query vector — it must merge into the same-kind node (preference count stays 1).
    func test_semantic_dedup_finds_same_kind_beyond_top_k() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        func node(_ id: String, _ kind: String, _ label: String) -> Node {
            Node(id: id, kind: kind, label: label, body: label, layer: .daily, createdAt: now,
                 updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure,
                 mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                 dirty: true, deleted: false, extra: nil)
        }
        let query: [Float] = [1, 0, 0, 0]
        // 10 DISTINCT other-kind (.fact) nodes at distance 0 (exact match) deterministically fill
        // the global top-10, pushing the one same-kind (.preference) node — placed at a small but
        // strictly larger distance (still well under threshold 0.2) — past k=8 yet inside k=64.
        for i in 0..<10 {
            let n = node("other-\(i)", NodeKind.fact.rawValue, "fact-\(i)")
            try store.upsert(n)
            try store.setEmbedding(nodeId: n.id, [1, 0, 0, 0])
        }
        let pref = node("pref", NodeKind.preference.rawValue, "Messi")
        try store.upsert(pref)
        // cosine distance ≈ 1 - 0.9938 ≈ 0.0062 < 0.2, but strictly > 0 so it sorts after the 10.
        try store.setEmbedding(nodeId: pref.id, [10, 0, 0, 1])

        let cand = node("cand", NodeKind.preference.rawValue, "likes Messi")
        _ = try store.upsertMergingSemantic(cand, embedding: query, embedder: nil)

        XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.preference.rawValue }.count, 1,
                       "same-kind near-duplicate beyond top-8 must still merge (kind filter not defeated by closer other-kind vectors)")
        XCTAssertEqual(try store.allNodes().first { $0.kind == NodeKind.preference.rawValue }?.mentionCount, 2)
    }

    /// Fix 2: passing `embedding: nil` with an `embedder` must compute the embedding from the
    /// candidate label and still dedup via semantics — two same-keyword saves collapse to 1.
    func test_upsertMergingSemantic_embeds_via_embedder_when_no_precomputed_embedding() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let emb = KeywordEmbedder()
        let now = Date().timeIntervalSince1970
        func cand(_ id: String, _ label: String) -> Node {
            Node(id: id, kind: NodeKind.preference.rawValue, label: label, body: label, layer: .daily, createdAt: now,
                 updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure,
                 mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                 dirty: true, deleted: false, extra: nil)
        }
        _ = try store.upsertMergingSemantic(cand("a", "Messi"), embedding: nil, embedder: emb)
        _ = try store.upsertMergingSemantic(cand("b", "likes Messi"), embedding: nil, embedder: emb)
        XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.preference.rawValue }.count, 1,
                       "embedder fallback must drive semantic dedup when no precomputed embedding is passed")
    }

    func testSweepForgetsExpiredDailyKeepsIdentity() throws {
        let store = try makeStore()
        let daily = node(label: "tmp", ttl: 1, lastSeen: 1)
        let ident = node(label: "name", layer: .identity)
        try store.upsert(daily)
        try store.upsert(ident)
        try store.sweep(now: Date().timeIntervalSince1970)
        let labels = Set(try store.allNodes().map { $0.label })
        XCTAssertFalse(labels.contains("tmp"))
        XCTAssertTrue(labels.contains("name"))
    }
}
