import XCTest
import BrainContract
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

    /// The query helpers behind `/v1/memory/why`, `/v1/memory/by_topic` and `/v1/memory/tags`
    /// read the same tables retraction purges, so a withdrawn thread must leave them nothing to
    /// cite while an unrelated topic stays answerable.
    func test_forget_closes_why_and_topic_views() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let withdrawn = "I live in Miami with my brother Luis"
        let auth = BrainAuthorization(
            principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user],
            threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]],
            mayProject: true, mayCommitClaims: true, mayForget: true)
        let brain = BrainStore(store: store, authorization: auth, clock: { 100 })
        let evidence = BrainEvidence(id: "e1", sourceKind: .userMessage, speakerID: "self:user",
                                     threadID: "thread-1", observedAt: 10, recordedAt: 11,
                                     accessScope: .user, text: withdrawn)
        let claim = BrainClaim(id: "c1", revision: 0, subject: "self:user", predicate: "home",
                               value: .string("Miami"), modality: .asserted, status: .active,
                               validFrom: 10, recordedAt: 11, evidenceIDs: ["e1"])
        XCTAssertEqual(try brain.commit(try BrainCommitRequest(
            clientOperationID: "seed", evidence: [evidence], updates: [.init(claim: claim)],
            expectedRevision: 0)).disposition, .committed)

        func mk(_ id: String, _ kind: NodeKind, _ body: String, sourceRef: String? = nil, extra: String? = nil) throws {
            try store.upsert(Node(id: id, kind: kind.rawValue, label: body, body: body, layer: .daily,
                                  createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0,
                                  confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                                  sourceRef: sourceRef, origin: .extracted, serverId: nil,
                                  dirty: true, deleted: false, extra: extra))
        }
        try mk("src", .summary, withdrawn, sourceRef: "thread-1",
               extra: #"{"threadId":"thread-1","turnRange":[1,2]}"#)
        try mk("ins", .insight, "The user is rooted in Miami")
        try store.upsert(Edge(id: "edge-1", srcId: "ins", dstId: "src", relation: .derivesFrom,
                              weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1,
                              dirty: true, deleted: false, extra: nil))
        try store.setTags(nodeId: "ins", ["home"])
        try mk("other", .preference, "Cold brew coffee every single morning")
        try store.setTags(nodeId: "other", ["drinks"])

        let before = MemoryQueries.why("rooted in Miami", store: store, embedder: nil)
        XCTAssertEqual(before.insight?.id, "ins", "precondition: the claim is citable before retraction")
        XCTAssertEqual(before.sources.map(\.id), ["src"])

        try BrainRetractionService(brain: brain).forget(
            scope: BrainForgetScope(kind: .thread, id: "thread-1"), expectedRevision: 1, operationID: "forget")

        let after = MemoryQueries.why("rooted in Miami", store: store, embedder: nil)
        XCTAssertNil(after.insight)
        XCTAssertTrue(after.sources.isEmpty)
        XCTAssertTrue(MemoryQueries.nodesForTopic("home", store: store, embedder: nil, limit: 100).isEmpty)
        XCTAssertFalse(try store.distinctTags().contains("home"))
        XCTAssertEqual(MemoryQueries.nodesForTopic("drinks", store: store, embedder: nil, limit: 100).map(\.id),
                       ["other"])
    }
}
