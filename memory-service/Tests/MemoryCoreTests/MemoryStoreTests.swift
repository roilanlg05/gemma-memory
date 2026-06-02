import XCTest
import GRDB
@testable import MemoryCore

final class MemoryStoreTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }

    private func sampleNode(id: String = UUID().uuidString, kind: NodeKind = .preference, label: String = "sushi") -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: id, kind: kind.rawValue, label: label, body: label, layer: .daily,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3,
                    decayRate: 0.001, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                    sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testUpsertAndFetch() throws {
        let store = try makeStore()
        let n = sampleNode()
        try store.upsert(n)
        XCTAssertEqual(try store.node(id: n.id)?.label, "sushi")
    }

    func testAllNodesExcludesDeleted() throws {
        let store = try makeStore()
        let n = sampleNode(); try store.upsert(n)
        try store.softDelete(nodeId: n.id)
        XCTAssertTrue(try store.allNodes().isEmpty)
        XCTAssertEqual(try store.allNodes(includeDeleted: true).count, 1)
    }

    func testFTSFindsByKeyword() throws {
        let store = try makeStore()
        try store.upsert(sampleNode(label: "sushi restaurant downtown"))
        XCTAssertEqual(try store.searchFTS(query: "sushi", limit: 5).count, 1)
    }

    func testInitWithMemoryPath() throws {
        // ":memory:" path uses the in-memory init under the hood.
        let store = try MemoryStore(path: ":memory:", embeddingDim: 4)
        let n = sampleNode()
        try store.upsert(n)
        XCTAssertEqual(try store.node(id: n.id)?.label, "sushi")
        XCTAssertEqual(try store.nodeCount(), 1)
    }

    func testInitWithFilePath() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("memcore-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("memory.sqlite").path
        let store = try MemoryStore(path: dbPath, embeddingDim: 4)
        try store.upsert(sampleNode(label: "filebacked"))
        XCTAssertEqual(try store.nodeCount(), 1)
        // Parent directory was created.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.path))
    }
}
