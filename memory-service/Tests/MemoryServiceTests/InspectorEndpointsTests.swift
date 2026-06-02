import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class InspectorEndpointsTests: XCTestCase {
    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: ts,
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }

    func test_nodes_paged() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/save", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"kind":"preference","label":"sushi"}"#)) { _ in }
            try await client.execute(uri: "/v1/nodes?limit=10", method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"nodes\""))
                XCTAssertTrue(s.contains("\"sushi\""))
            }
        }
    }

    func test_transcript_recent() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/transcript/append", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"threadId":"T","role":"user","text":"hi","turnIndex":0}"#)) { _ in }
            try await client.execute(uri: "/v1/transcript/recent?limit=5", method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"hi\""))
            }
        }
    }

    func test_readyz_returns_ok_with_fake_embedder() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/readyz", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"ready\""))
            }
        }
    }
}
