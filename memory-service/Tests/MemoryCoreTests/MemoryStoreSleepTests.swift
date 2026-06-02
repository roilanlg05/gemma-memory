import XCTest
@testable import MemoryCore

final class MemoryStoreSleepTests: XCTestCase {
    private func ep(_ id: String, _ threadId: String, _ status: String) -> Node {
        let now = Date().timeIntervalSince1970
        let extra = #"{"threadId":"\#(threadId)","role":"user","turnIndex":0,"status":"\#(status)"}"#
        return Node(id: id, kind: NodeKind.conversation.rawValue, label: "user: hi", body: "hi", layer: .episodic,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: 2, decayRate: 0.001,
                    confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: threadId,
                    origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra)
    }

    func test_sleep_cycle_round_trip_and_clear() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        XCTAssertNil(try store.loadSleepCycle())
        try store.saveSleepCycle(SleepCycleState(phase: .rem, episodeIds: ["a","b"], startedAt: 123, focus: ""))
        let s = try store.loadSleepCycle()
        XCTAssertEqual(s?.phase, .rem)
        XCTAssertEqual(s?.episodeIds, ["a","b"])
        try store.clearSleepCycle()
        XCTAssertNil(try store.loadSleepCycle())
    }

    func test_sleep_cycle_round_trips_focus() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        try store.saveSleepCycle(SleepCycleState(phase: .nrem, episodeIds: ["e1"], startedAt: 1, focus: "sushi, fútbol"))
        XCTAssertEqual(try store.loadSleepCycle()?.focus, "sushi, fútbol")
    }

    func test_pending_followups_returns_pending_tasks_and_followups() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        func n(_ id: String, _ kind: String, _ status: String?) -> Node {
            var attrs = NodeAttributes(); attrs.status = status
            return Node(id: id, kind: kind, label: id, body: id, layer: .daily, createdAt: now, updatedAt: now,
                        lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1,
                        ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
        }
        try store.upsert(n("t1", NodeKind.task.rawValue, "pending"))
        try store.upsert(n("t2", NodeKind.task.rawValue, "done"))
        try store.upsert(n("f1", NodeKind.followUp.rawValue, "pending"))
        try store.upsert(n("p1", NodeKind.preference.rawValue, nil))   // not a follow-up kind
        let ids = Set(try store.pendingFollowUps().map { $0.id })
        XCTAssertEqual(ids, ["t1", "f1"])   // pending task + pending follow_up; done task & preference excluded
    }

    func test_unconsolidated_episodes_and_mark() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        try store.upsert(ep("e1", "T", "closed"))
        try store.upsert(ep("e2", "T", "consolidated"))
        XCTAssertEqual(try store.unconsolidatedEpisodes().map { $0.id }, ["e1"])
        try store.markEpisodesConsolidated(ids: ["e1"])
        XCTAssertTrue(try store.unconsolidatedEpisodes().isEmpty)
    }

    func test_distinct_kinds_and_reassign() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        func n(_ id: String, _ kind: String) -> Node {
            Node(id: id, kind: kind, label: id, body: "", layer: .daily, createdAt: now, updatedAt: now,
                 lastSeenAt: now, salience: 1, decayRate: 0.001, confidence: .sure, mentionCount: 1,
                 ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        try store.upsert(n("a", "meta")); try store.upsert(n("b", "plan"))
        XCTAssertEqual(Set(try store.distinctKinds()), Set(["meta", "plan"]))
        try store.reassignKind(from: "meta", to: "plan")
        XCTAssertEqual(try store.node(id: "a")?.kind, "plan")
        XCTAssertFalse(try store.distinctKinds().contains("meta"))
    }

    func test_prune_dangling_edges() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        func n(_ id: String) -> Node { Node(id: id, kind: "fact", label: id, body: "", layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 1, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil) }
        try store.upsert(n("a")); try store.upsert(n("b"))
        try store.upsert(Edge(id: "e", srcId: "a", dstId: "b", relation: .relatedTo, weight: 1, confidence: .sure, createdAt: now, updatedAt: now, dirty: true, deleted: false, extra: nil))
        try store.softDelete(nodeId: "b")
        try store.pruneDanglingEdges()
        XCTAssertTrue(try store.allEdges().isEmpty, "edge to a deleted node is pruned")
    }
}
