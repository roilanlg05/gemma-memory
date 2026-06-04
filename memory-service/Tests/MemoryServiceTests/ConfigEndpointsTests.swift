import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class ConfigEndpointsTests: XCTestCase {
    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = await Services(store: store,
                                      transcript: TranscriptStore(dbQueue: store.dbQueue),
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }

    func test_post_then_get_never_returns_key() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // POST a cloud provider config with a key
            try await client.execute(uri: "/v1/config/model", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"provider":"gemini","baseURL":"https://x","model":"m","apiKey":"K"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
            // GET returns the config WITHOUT the key
            try await client.execute(uri: "/v1/config/model", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"provider\":\"gemini\""), "got: \(body)")
                XCTAssertTrue(body.contains("\"model\":\"m\""), "got: \(body)")
                XCTAssertTrue(body.contains("\"hasKey\":true"), "got: \(body)")
                XCTAssertFalse(body.contains("apiKey"), "response leaked apiKey field: \(body)")
                XCTAssertFalse(body.contains("\"K\""), "response leaked key value: \(body)")
                XCTAssertFalse(body.contains(":\"K\""), "response leaked key value: \(body)")
            }
        }
    }

    func test_cloud_provider_requires_key_returns_400() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/config/model", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"provider":"gemini","baseURL":"https://x","model":"m"}"#)) { res in
                XCTAssertEqual(res.status, .badRequest)
            }
        }
    }

    func test_post_without_auth_returns_401() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/config/model", method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"provider":"gemini","baseURL":"https://x","model":"m","apiKey":"K"}"#)) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }
}
