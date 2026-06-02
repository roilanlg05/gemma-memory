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
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: ts, embedder: FakeEmbedder(dimension: 8),
                                       bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
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
