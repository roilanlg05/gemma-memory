import XCTest
import Hummingbird
import HummingbirdTesting
@testable import MemoryService

final class AuthMiddlewareTests: XCTestCase {
    func test_protected_route_rejects_missing_bearer() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/echo", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func test_protected_route_rejects_wrong_bearer() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/echo", method: .get,
                                     headers: [.authorization: "Bearer wrong"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func test_protected_route_accepts_correct_bearer() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/echo", method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func test_healthz_does_NOT_require_bearer() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }
}
