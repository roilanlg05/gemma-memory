import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class MemoryEndpointsTests: XCTestCase {
    private func makeApp() async throws -> some ApplicationProtocol {
        try await makeAppWithServices().0
    }

    /// Like `makeApp()` but also returns the `Services` so tests can seed `transcript`/`store`/`embedder` directly.
    private func makeAppWithServices() async throws -> (some ApplicationProtocol, Services) {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: ts, embedder: FakeEmbedder(dimension: 8),
                                       bearerToken: "test-token")
        let app = try await buildApp(services: services, port: 0)
        return (app, services)
    }

    func test_save_then_forget_works() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/save", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"kind":"preference","label":"sushi","body":"al user le gusta"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"id\""))
            }
            try await client.execute(uri: "/v1/memory/forget", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"label":"sushi"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"removed\""), "got: \(s)")
            }
        }
    }

    func test_recall_returns_core_and_recall_lists() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            for (k, l, b) in [("identity","Roilan","el usuario se llama Roilan"),
                              ("preference","sushi","al user le gusta el sushi")] {
                let body = #"{"kind":"\#(k)","label":"\#(l)","body":"\#(b)"}"#
                try await client.execute(uri: "/v1/memory/save", method: .post,
                                         headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                         body: ByteBuffer(string: body)) { res in
                    XCTAssertEqual(res.status, .ok)
                }
            }
            try await client.execute(uri: "/v1/memory/recall", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"query":"qué comida me gusta"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"core\""))
                XCTAssertTrue(s.contains("\"recall\""))
            }
        }
    }

    func test_recall_returns_recent_turns_from_other_threads_only() async throws {
        let (app, services) = try await makeAppWithServices()
        // Seed thread A (a relevant turn) and thread B (the current thread). Embed each turn so
        // nearestTranscript can rank them.
        let aId = try services.transcript.append(threadId: "A", turnIndex: 0, role: "user",
                                                 text: "voy a Varadero la próxima semana")
        try services.store.setTranscriptEmbedding(turnId: aId, services.embedder.embed("voy a Varadero la próxima semana"))
        let bId = try services.transcript.append(threadId: "B", turnIndex: 0, role: "user", text: "hola")
        try services.store.setTranscriptEmbedding(turnId: bId, services.embedder.embed("hola"))
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/recall", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"query":"qué planes tengo","threadId":"B"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("recentTurns"))
                XCTAssertTrue(body.contains("Varadero"), body)              // from thread A
                XCTAssertFalse(body.contains("\"text\":\"hola\""), body)     // current thread B excluded
            }
        }
    }

    func test_expand_returns_transcript_for_known_summary() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // append a transcript turn
            try await client.execute(uri: "/v1/transcript/append", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"threadId":"T","role":"user","text":"viaje a Japón","turnIndex":0}"#)) { _ in }
            // save a summary node whose extra references that transcript range
            let saveBody = #"{"kind":"summary","label":"viaje a Japón","body":"plan","extra":"{\"threadId\":\"T\",\"turnRange\":[0,0]}"}"#
            try await client.execute(uri: "/v1/memory/save", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: saveBody)) { _ in }
            try await client.execute(uri: "/v1/memory/expand?topic=viaje%20a%20Jap%C3%B3n", method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("viaje a Japón"), "got: \(s)")
            }
        }
    }
}
