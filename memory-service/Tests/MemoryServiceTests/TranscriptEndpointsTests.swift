import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class TranscriptEndpointsTests: XCTestCase {
    func test_append_then_window_returns_inserted_turns() async throws {
        let app = try await buildTestApp()
        try await app.test(.live) { client in
            // append two turns
            let turns: [(Int, String, String)] = [
                (0, "user", "hola"),
                (0, "assistant", "hola, ¿cómo estás?"),
            ]
            for (i, role, text) in turns {
                let body = #"{"threadId":"T","role":"\#(role)","text":"\#(text)","turnIndex":\#(i)}"#
                try await client.execute(uri: "/v1/transcript/append", method: .post,
                                         headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                         body: ByteBuffer(string: body)) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            try await client.execute(uri: "/v1/conversation/window?threadId=T&maxTurns=12&maxChars=2000",
                                     method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { response in
                XCTAssertEqual(response.status, .ok)
                let json = String(buffer: response.body)
                XCTAssertTrue(json.contains("hola"), "got: \(json)")
                XCTAssertTrue(json.contains("¿cómo estás?"))
            }
        }
    }

    func test_append_rejects_invalid_body() async throws {
        let app = try await buildTestApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/transcript/append", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: "{}")) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func test_append_embeds_turn_for_recall() async throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let embedder = FakeEmbedder(dimension: 8)
        let services = await Services(store: store, transcript: ts, embedder: embedder,
                                      bearerToken: "test-token")
        let app = try await buildApp(services: services, port: 0)
        try await app.test(.live) { client in
            let body = #"{"threadId":"t","role":"user","text":"voy a Varadero","turnIndex":0}"#
            try await client.execute(uri: "/v1/transcript/append", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        let qv = try embedder.embed("voy a Varadero")
        let hits = try store.nearestTranscript(to: qv, k: 1)
        XCTAssertEqual(hits.count, 1)
    }
}

/// Builds an in-memory test app sharing Services across the suite.
private func buildTestApp() async throws -> some ApplicationProtocol {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
    let ts = TranscriptStore(dbQueue: store.dbQueue)
    let services = await Services(store: store, transcript: ts, embedder: FakeEmbedder(dimension: 8),
                                   bearerToken: "test-token")
    return try await buildApp(services: services, port: 0)
}
