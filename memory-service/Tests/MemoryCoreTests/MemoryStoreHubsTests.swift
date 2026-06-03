import XCTest
@testable import MemoryCore

final class MemoryStoreHubsTests: XCTestCase {
    private func makeStore() throws -> MemoryStore {
        try MemoryStore(path: ":memory:", embeddingDim: 8)
    }

    // Helper: build a minimal Node with sensible defaults.
    private func node(id: String, kind: NodeKind, label: String, extra: String? = nil) -> Node {
        Node(id: id, kind: kind.rawValue, label: label, body: label,
             layer: .live, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
             salience: 1, decayRate: 0.1, confidence: .probable,
             mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
             origin: .extracted, serverId: nil, dirty: false, deleted: false, extra: extra)
    }

    func test_ensureKindHubs_creates_one_hub_per_kind() throws {
        let store = try makeStore()
        let created = try store.ensureKindHubs()
        XCTAssertEqual(created, NodeKind.allCases.count, "expected one hub per NodeKind on first run")
        // idempotent
        XCTAssertEqual(try store.ensureKindHubs(), 0, "second call must be a no-op")
    }

    func test_upsert_auto_links_to_kind_hub() throws {
        let store = try makeStore()
        try store.ensureKindHubs()
        let t = node(id: "t1", kind: .task, label: "buy milk")
        try store.upsert(t)
        let tasks = try store.nodesByHub(kind: .task)
        XCTAssertEqual(tasks.map(\.id), ["t1"], "upserted task must appear under its hub")
    }

    func test_nodesByHub_filter_by_status_and_sort_by_date() throws {
        let store = try makeStore()
        try store.ensureKindHubs()
        // Three tasks; one done, two pending with different dates.
        try store.upsert(node(id: "a", kind: .task, label: "old",
                              extra: #"{"status":"pending","date":"2026-06-04"}"#))
        try store.upsert(node(id: "b", kind: .task, label: "next",
                              extra: #"{"status":"pending","date":"2026-06-03"}"#))
        try store.upsert(node(id: "c", kind: .task, label: "done",
                              extra: #"{"status":"done","date":"2026-06-02"}"#))
        let pending = try store.nodesByHub(
            kind: .task,
            extraFilter: "json_extract(n.extra,'$.status') = 'pending'",
            orderSQL: "json_extract(n.extra,'$.date') ASC")
        XCTAssertEqual(pending.map(\.id), ["b", "a"], "pending tasks ordered by date asc")
    }

    func test_nodesByEntity_returns_everything_linked_either_direction() throws {
        let store = try makeStore()
        try store.ensureKindHubs()
        let roilan = node(id: "ent-roilan", kind: .person, label: "Roilan")
        let sushi  = node(id: "p-sushi",    kind: .preference, label: "sushi")
        let task   = node(id: "t-cita",     kind: .task, label: "cita dentista")
        try store.upsert(roilan); try store.upsert(sushi); try store.upsert(task)

        // Roilan likes sushi (entity → preference), and is mentioned in task (entity → task).
        try store.upsert(Edge(id: "e1", srcId: roilan.id, dstId: sushi.id,
                              relation: .likes, weight: 1, confidence: .sure,
                              createdAt: 1, updatedAt: 1, dirty: false, deleted: false, extra: nil))
        try store.upsert(Edge(id: "e2", srcId: roilan.id, dstId: task.id,
                              relation: .mentionedIn, weight: 1, confidence: .sure,
                              createdAt: 1, updatedAt: 1, dirty: false, deleted: false, extra: nil))
        let around = try store.nodesByEntity(label: "Roilan")
        let ids = Set(around.map(\.id))
        XCTAssertTrue(ids.contains("p-sushi"))
        XCTAssertTrue(ids.contains("t-cita"))
        XCTAssertFalse(ids.contains("ent-roilan"), "entity itself excluded from its own neighborhood")
    }
}
