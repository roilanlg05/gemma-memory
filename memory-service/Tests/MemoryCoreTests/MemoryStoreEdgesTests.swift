import XCTest
import GRDB
@testable import MemoryCore

final class MemoryStoreEdgesTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }

    private func node(_ id: String) -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: id, kind: NodeKind.person.rawValue, label: id, body: id, layer: .identity,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: 1,
                    decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                    sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testAllEdgesReturnsInsertedEdge() throws {
        let store = try makeStore()
        try store.upsert(node("a"))
        try store.upsert(node("b"))
        let now = Date().timeIntervalSince1970
        let edge = Edge(id: "e1", srcId: "a", dstId: "b", relation: .knows, weight: 1,
                        confidence: .sure, createdAt: now, updatedAt: now,
                        dirty: true, deleted: false, extra: nil)
        try store.upsert(edge)

        let all = try store.allEdges()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.srcId, "a")
        XCTAssertEqual(all.first?.dstId, "b")
    }

    func testAllEdgesExcludesDeleted() throws {
        let store = try makeStore()
        try store.upsert(node("a"))
        try store.upsert(node("b"))
        let now = Date().timeIntervalSince1970
        var edge = Edge(id: "e1", srcId: "a", dstId: "b", relation: .knows, weight: 1,
                        confidence: .sure, createdAt: now, updatedAt: now,
                        dirty: true, deleted: true, extra: nil)
        try store.upsert(edge)
        XCTAssertTrue(try store.allEdges().isEmpty)

        edge.deleted = false
        try store.upsert(edge)
        XCTAssertEqual(try store.allEdges().count, 1)
    }
}
