import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class AgentEndpointTests: XCTestCase {

    // MARK: - Canned client

    /// Scripted AgentModelClient: pops results in order (mirrors AgentLoopTests.CannedClient).
    final class CannedAgentClient: AgentModelClient, @unchecked Sendable {
        var scripted: [AgentModelResult]
        init(_ s: [AgentModelResult]) { scripted = s }
        func complete(systemPrompt: String, userPrompt: String,
                      tools: [[String: Any]]) async throws -> AgentModelResult {
            scripted.isEmpty ? AgentModelResult(text: "", toolCalls: []) : scripted.removeFirst()
        }
    }

    // MARK: - App construction

    /// Builds a live app + services with an injected canned agent client.
    private func makeAppWithServices(agentClient: any AgentModelClient)
            async throws -> (some ApplicationProtocol, Services) {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(
            store: store,
            transcript: ts,
            embedder: FakeEmbedder(dimension: 8),
            bearerToken: "test-token",
            agentClient: agentClient
        )
        let app = try await buildApp(services: services, port: 0)
        return (app, services)
    }

    // MARK: - Tests

    func test_agent_turn_returns_reply_and_appends_transcript() async throws {
        let canned = CannedAgentClient([AgentModelResult(text: "hola Roilan", toolCalls: [])])
        let (app, services) = try await makeAppWithServices(agentClient: canned)

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/v1/agent/turn",
                method: .post,
                headers: [
                    .authorization: "Bearer test-token",
                    .contentType: "application/json"
                ],
                body: ByteBuffer(string: #"{"text":"hola","threadId":"T"}"#)
            ) { res in
                XCTAssertEqual(res.status, .ok, "expected 200, got \(res.status)")
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"reply\""), "missing reply key: \(body)")
                XCTAssertTrue(body.contains("hola Roilan"), "missing canned reply: \(body)")
            }
        }

        // After the HTTP call completes the transcript must have user + assistant rows.
        let rows = try services.transcript.range(threadId: "T", from: 1, to: 99)
        let roles = rows.map { $0.role }
        XCTAssertEqual(roles, ["user", "assistant"],
                       "expected [user, assistant] in seq order, got: \(roles)")
        XCTAssertEqual(rows.first?.text, "hola")
        XCTAssertEqual(rows.last?.text, "hola Roilan")
    }

    func test_agent_turn_empty_text_is_400() async throws {
        let canned = CannedAgentClient([])
        let (app, _) = try await makeAppWithServices(agentClient: canned)

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/v1/agent/turn",
                method: .post,
                headers: [
                    .authorization: "Bearer test-token",
                    .contentType: "application/json"
                ],
                body: ByteBuffer(string: #"{"text":""}"#)
            ) { res in
                XCTAssertEqual(res.status, .badRequest, "empty text must be 400")
            }
        }
    }

    func test_agent_turn_whitespace_only_text_is_400() async throws {
        let canned = CannedAgentClient([])
        let (app, _) = try await makeAppWithServices(agentClient: canned)

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/v1/agent/turn",
                method: .post,
                headers: [
                    .authorization: "Bearer test-token",
                    .contentType: "application/json"
                ],
                body: ByteBuffer(string: #"{"text":"   "}"#)
            ) { res in
                XCTAssertEqual(res.status, .badRequest, "whitespace-only text must be 400")
            }
        }
    }

    func test_agent_turn_requires_bearer() async throws {
        let canned = CannedAgentClient([AgentModelResult(text: "hi", toolCalls: [])])
        let (app, _) = try await makeAppWithServices(agentClient: canned)

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/v1/agent/turn",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"text":"hola"}"#)
            ) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }

    func test_agent_turn_defaults_thread_to_gateway() async throws {
        let canned = CannedAgentClient([AgentModelResult(text: "ok", toolCalls: [])])
        let (app, services) = try await makeAppWithServices(agentClient: canned)

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/v1/agent/turn",
                method: .post,
                headers: [
                    .authorization: "Bearer test-token",
                    .contentType: "application/json"
                ],
                body: ByteBuffer(string: #"{"text":"hola"}"#)
            ) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }

        let rows = try services.transcript.range(threadId: "gateway", from: 1, to: 99)
        XCTAssertFalse(rows.isEmpty, "default threadId 'gateway' must be used when omitted")
    }

    func test_agent_turn_malformed_body_is_400() async throws {
        let canned = CannedAgentClient([])
        let (app, _) = try await makeAppWithServices(agentClient: canned)

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/v1/agent/turn",
                method: .post,
                headers: [
                    .authorization: "Bearer test-token",
                    .contentType: "application/json"
                ],
                body: ByteBuffer(string: "not json")
            ) { res in
                XCTAssertEqual(res.status, .badRequest, "unparseable body must be 400")
            }
        }
    }

    /// End-to-end through the HTTP layer: model asks for a tool, the loop runs it server-side,
    /// re-feeds, and the endpoint returns the final reply — proving AgentLoop is wired into the handler.
    func test_agent_turn_executes_tool_then_returns_final_reply() async throws {
        let canned = CannedAgentClient([
            AgentModelResult(text: "", toolCalls: [AgentToolCall(name: "get_current_time", args: "{}")]),
            AgentModelResult(text: "son las 3 en punto", toolCalls: []),
        ])
        let (app, services) = try await makeAppWithServices(agentClient: canned)

        try await app.test(.live) { client in
            try await client.execute(
                uri: "/v1/agent/turn",
                method: .post,
                headers: [
                    .authorization: "Bearer test-token",
                    .contentType: "application/json"
                ],
                body: ByteBuffer(string: #"{"text":"que hora es","threadId":"TZ"}"#)
            ) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("son las 3 en punto"), "expected final reply, got: \(body)")
            }
        }

        // The final (post-tool) reply is what gets persisted as the assistant turn.
        let rows = try services.transcript.range(threadId: "TZ", from: 1, to: 99)
        XCTAssertEqual(rows.map { $0.role }, ["user", "assistant"])
        XCTAssertEqual(rows.last?.text, "son las 3 en punto")
    }
}
