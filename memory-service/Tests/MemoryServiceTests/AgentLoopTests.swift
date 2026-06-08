import XCTest
@testable import MemoryService
@testable import MemoryCore

final class AgentLoopTests: XCTestCase {

    /// Build a lightweight in-memory Services — mirrors GatewayToolsTests.services().
    @MainActor
    private func services() throws -> Services {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        return Services(store: store, transcript: ts, embedder: FakeEmbedder(dimension: 8),
                        bearerToken: "test-token")
    }

    // MARK: - CannedClient

    /// A scripted AgentModelClient that pops results from a queue in order.
    final class CannedClient: AgentModelClient, @unchecked Sendable {
        var scripted: [AgentModelResult]
        init(_ s: [AgentModelResult]) { scripted = s }
        func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
            scripted.isEmpty ? AgentModelResult(text: "", toolCalls: []) : scripted.removeFirst()
        }
    }

    /// A client whose complete always throws.
    final class ThrowingClient: AgentModelClient, @unchecked Sendable {
        struct E: Error {}
        func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
            throw E()
        }
    }

    /// A client that always returns a tool call (never converges to a final answer).
    final class InfiniteToolClient: AgentModelClient, @unchecked Sendable {
        func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
            AgentModelResult(text: "thinking…", toolCalls: [AgentToolCall(name: "get_current_time", args: "{}")])
        }
    }

    /// Records the last system/user prompt it was called with, then returns a final answer.
    final class CapturingClient: AgentModelClient, @unchecked Sendable {
        var lastSystemPrompt = ""
        var lastUserPrompt = ""
        func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
            lastSystemPrompt = systemPrompt
            lastUserPrompt = userPrompt
            return AgentModelResult(text: "ok", toolCalls: [])
        }
    }

    // MARK: - Tests

    func test_final_text_returned() async throws {
        let s = try await MainActor.run { try services() }
        let loop = AgentLoop(client: CannedClient([AgentModelResult(text: "hola", toolCalls: [])]))
        let reply = await loop.run(text: "hi", threadId: "T", services: s)
        XCTAssertEqual(reply, "hola")
    }

    func test_tool_call_then_final() async throws {
        let s = try await MainActor.run { try services() }
        let loop = AgentLoop(client: CannedClient([
            AgentModelResult(text: "", toolCalls: [AgentToolCall(name: "get_current_time", args: "{}")]),
            AgentModelResult(text: "son las 3", toolCalls: []),
        ]))
        let reply = await loop.run(text: "what time", threadId: "T", services: s)
        XCTAssertEqual(reply, "son las 3")
    }

    func test_max_iterations_cap() async throws {
        let s = try await MainActor.run { try services() }
        // maxIterations:2 keeps the test fast; the loop must terminate without hanging.
        let loop = AgentLoop(client: InfiniteToolClient(), maxIterations: 2)
        let reply = await loop.run(text: "loop forever", threadId: "T", services: s)
        // Terminates at the cap (no hang) and returns the intermediate text from the capped turn
        // (InfiniteToolClient always replies "thinking…" alongside its tool call).
        XCTAssertEqual(reply, "thinking…", "Expected the capped-turn intermediate text, got: \(reply)")
    }

    func test_language_directive_rides_the_tail_when_provided() async throws {
        let s = try await MainActor.run { try services() }
        let client = CapturingClient()
        let loop = AgentLoop(client: client)
        _ = await loop.run(text: "hi", threadId: "T", services: s, language: "es")
        XCTAssertTrue(client.lastUserPrompt.contains("Reply in Spanish."),
                      "per-turn tail must carry the language directive, got: \(client.lastUserPrompt)")
        XCTAssertFalse(client.lastSystemPrompt.contains("Reply in Spanish."),
                       "language hint must NOT be in the static system prefix (would break prefix caching)")
    }

    func test_no_language_directive_when_absent() async throws {
        let s = try await MainActor.run { try services() }
        let client = CapturingClient()
        let loop = AgentLoop(client: client)
        _ = await loop.run(text: "hi", threadId: "T", services: s)
        XCTAssertFalse(client.lastUserPrompt.contains("Reply in"),
                       "no language directive expected when language is nil, got: \(client.lastUserPrompt)")
    }

    func test_model_error_returns_graceful_message() async throws {
        let s = try await MainActor.run { try services() }
        let loop = AgentLoop(client: ThrowingClient())
        let reply = await loop.run(text: "anything", threadId: "T", services: s)
        XCTAssertEqual(reply, "I can't reach my model right now.")
    }
}
