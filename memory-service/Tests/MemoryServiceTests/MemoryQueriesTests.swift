import XCTest
@testable import MemoryService
@testable import MemoryCore

final class MemoryQueriesTests: XCTestCase {

    func test_nodesForTopic_exact_tag() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "calls", body: "calls",
                     layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3,
                     decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                     sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(n)
        try store.setTags(nodeId: "n1", ["trading"])

        let nodes = MemoryQueries.nodesForTopic("trading", store: store, embedder: nil, limit: 100)
        XCTAssertEqual(nodes.map { $0.label }, ["calls"])

        XCTAssertTrue(MemoryQueries.nodesForTopic("astronomia", store: store, embedder: nil, limit: 100).isEmpty)
    }

    func test_why_traverses_derivesFrom() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        func mk(_ id: String, _ kind: String, _ b: String) throws {
            try store.upsert(Node(id: id, kind: kind, label: b, body: b, layer: .daily,
                                  createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3,
                                  decayRate: 0, confidence: .probable, mentionCount: 1,
                                  ttlExpiresAt: nil, sourceRef: nil, origin: .extracted,
                                  serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        try mk("ins", NodeKind.insight.rawValue, "trades options")
        try mk("s1", NodeKind.preference.rawValue, "calls")
        try mk("s2", NodeKind.preference.rawValue, "noise")
        try store.upsert(Edge(id: "e", srcId: "ins", dstId: "s1", relation: .derivesFrom,
                              weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1,
                              dirty: true, deleted: false, extra: nil))
        // A non-derivesFrom edge from the same insight — must NOT appear in sources (proves the filter).
        try store.upsert(Edge(id: "e2", srcId: "ins", dstId: "s2", relation: .relatedTo,
                              weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1,
                              dirty: true, deleted: false, extra: nil))

        let r = MemoryQueries.why("trades options", store: store, embedder: nil)
        XCTAssertEqual(r.insight?.body, "trades options")
        XCTAssertEqual(r.sources.map { $0.label }, ["calls"], "only the derivesFrom source, not relatedTo")
    }

    func test_resolveTag_returns_nil_for_unknown_topic_without_embedder() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "calls", body: "calls",
                     layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3,
                     decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                     sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(n)
        try store.setTags(nodeId: "n1", ["trading"])

        XCTAssertEqual(MemoryQueries.resolveTag("trading", store: store, embedder: nil), "trading")
        XCTAssertNil(MemoryQueries.resolveTag("astronomia", store: store, embedder: nil))
    }

    func test_why_returns_empty_when_no_insight() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        let r = MemoryQueries.why("some claim", store: store, embedder: nil)
        XCTAssertNil(r.insight)
        XCTAssertTrue(r.sources.isEmpty)
    }
}
