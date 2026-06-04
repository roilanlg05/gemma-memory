import XCTest
import GRDB
@testable import MemoryCore

final class SelfIdentityTests: XCTestCase {
    func test_upsertSelf_singleton_and_coreFirst() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        let id1 = try store.upsertSelf(name: "Roilan", detail: nil, embedder: nil)
        let id2 = try store.upsertSelf(name: "Roilan", detail: "ingeniero", embedder: nil)
        XCTAssertEqual(id1, "self:user")
        XCTAssertEqual(id2, "self:user")                  // same singleton, not a new node
        let n = try store.selfNode()
        XCTAssertEqual(n?.kind, "self")
        XCTAssertEqual(n?.label, "Roilan")
        XCTAssertEqual(n?.body, "ingeniero")
        XCTAssertEqual(n?.layer, .identity)
        // seed another identity fact; self must come FIRST in coreMemories
        let pref = Node(id: UUID().uuidString, kind: NodeKind.preference.rawValue, label: "sushi",
                        body: "le gusta", layer: .identity, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                        salience: 11, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                        sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(pref)
        XCTAssertEqual(try store.coreMemories().first?.kind, "self")
    }
}
