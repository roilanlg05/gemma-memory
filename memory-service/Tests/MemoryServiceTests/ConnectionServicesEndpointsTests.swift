import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class ConnectionServicesEndpointsTests: XCTestCase {
    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = await Services(store: store,
                                      transcript: TranscriptStore(dbQueue: store.dbQueue),
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }

    func test_crud_connection_services() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // 1. Initially empty
            try await client.execute(uri: "/v1/connection-services", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"services\":[]"), "got: \(body)")
            }

            // 2. GET non-existent returns 404
            try await client.execute(uri: "/v1/connection-services/amazon-atoz", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .notFound)
            }

            // 3. POST save amazon-atoz credentials
            let payload = #"{"credentials":{"cookie":"test-cookie-val","employeeId":"99999"}}"#
            try await client.execute(uri: "/v1/connection-services/amazon-atoz", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: payload)) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"ok\":true"))
                XCTAssertTrue(body.contains("\"id\":\"amazon-atoz\""))
            }

            // 4. GET amazon-atoz returns decrypted credentials
            try await client.execute(uri: "/v1/connection-services/amazon-atoz", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"test-cookie-val\""), "got: \(body)")
                XCTAssertTrue(body.contains("\"employeeId\":\"99999\""), "got: \(body)")
            }

            // 5. GET /v1/connection-services lists amazon-atoz
            try await client.execute(uri: "/v1/connection-services", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"amazon-atoz\""), "got: \(body)")
            }

            // 6. DELETE amazon-atoz
            try await client.execute(uri: "/v1/connection-services/amazon-atoz", method: .delete,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"deleted\":true"), "got: \(body)")
            }

            // 7. GET after delete returns 404
            try await client.execute(uri: "/v1/connection-services/amazon-atoz", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .notFound)
            }
        }
    }

    func testIncompleteVerifiedSessionDoesNotReplaceSavedCredentials() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            let headers: HTTPFields = [.authorization: "Bearer test-token", .contentType: "application/json"]
            try await client.execute(uri: "/v1/connection-services/amazon-atoz", method: .post,
                headers: headers, body: ByteBuffer(string: #"{"credentials":{"cookie":"original","employeeId":"12345"}}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
            try await client.execute(uri: "/v1/connection-services/amazon-atoz", method: .post,
                headers: headers, body: ByteBuffer(string: #"{"verify":true,"credentials":{"cookie":"session-id=generic","employeeId":"12345"}}"#)) { res in
                XCTAssertEqual(res.status, .badRequest)
                XCTAssertTrue(String(buffer: res.body).contains("invalid_credentials"))
            }
            try await client.execute(uri: "/v1/connection-services/amazon-atoz", method: .get,
                headers: headers) { res in
                XCTAssertTrue(String(buffer: res.body).contains("original"))
            }
        }
    }

    func test_unauthorized_returns_401() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/connection-services", method: .get) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }
}
