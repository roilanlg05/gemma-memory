import XCTest
@testable import MemoryCore

/// Phase 3 Task 3.2 — BLOB embedding storage + cosine KNN.
final class MemoryStoreVectorTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }
    private func node(_ label: String) -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: UUID().uuidString, kind: NodeKind.preference.rawValue, label: label, body: label, layer: .daily,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001,
                    confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                    origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testEmbeddingNearest() throws {
        let store = try makeStore()
        let a = node("a"); let b = node("b")
        try store.upsert(a); try store.upsert(b)
        try store.setEmbedding(nodeId: a.id, [1, 0, 0, 0])
        try store.setEmbedding(nodeId: b.id, [0, 1, 0, 0])
        let near = try store.nearest(to: [0.9, 0.1, 0, 0], k: 1)
        XCTAssertEqual(near.first?.id, a.id)
    }

    func testBlobRoundTrip() throws {
        let v: [Float] = [1.5, -2.0, 0.25, 3.0]
        XCTAssertEqual(MemoryStore.blobToFloats(MemoryStore.floatsToBlob(v)), v)
    }
}
