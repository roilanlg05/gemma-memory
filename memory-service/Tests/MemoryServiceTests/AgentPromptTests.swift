import XCTest
@testable import MemoryService
@testable import MemoryCore

final class AgentPromptTests: XCTestCase {

    /// Build a lightweight in-memory Services (mirrors GatewayToolsTests.services()).
    @MainActor
    private func services() throws -> Services {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        return Services(store: store, transcript: ts, embedder: FakeEmbedder(dimension: 8),
                        bearerToken: "test-token")
    }

    func test_systemPrompt_has_jarvis_and_tools_guidance() {
        let p = AgentPrompt.systemPrompt()
        XCTAssertTrue(p.contains("Gemma"), p)                                     // assistant identity ported
        XCTAssertTrue(p.localizedCaseInsensitiveContains("JARVIS"), p)            // persona ported
        XCTAssertTrue(p.localizedCaseInsensitiveContains("recall_by_topic"), p)  // tool guidance ported
    }

    func test_recall_injection_includes_a_seeded_memory() async throws {
        let s = try await MainActor.run { try services() }
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "sushi", body: "le gusta", layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 5, decayRate: 0, confidence: .probable,
                     mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                     dirty: true, deleted: false, extra: nil)
        try s.store.upsert(n)
        try s.store.setEmbedding(nodeId: "n1", s.embedder.embed("sushi"))
        let tail = AgentPrompt.recallTail(query: "comida", threadId: "T", services: s)
        XCTAssertTrue(tail.localizedCaseInsensitiveContains("sushi"), tail)
    }

    func test_recall_tail_is_just_nowContext_when_no_memory() async throws {
        let s = try await MainActor.run { try services() }   // empty store → empty injection block
        let tail = AgentPrompt.recallTail(query: "anything", threadId: "T", services: s)
        // Empty-injection branch: tail is exactly the nowContext line — no "\n\n"-joined block appended.
        XCTAssertTrue(tail.hasPrefix("Current date and time:"), tail)
        XCTAssertFalse(tail.contains("\n\n"), "no injection block should be appended, got: \(tail)")
    }
}
