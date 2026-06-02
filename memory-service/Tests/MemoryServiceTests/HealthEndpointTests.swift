import XCTest
import Hummingbird
import HummingbirdTesting
@testable import MemoryService

final class HealthEndpointTests: XCTestCase {
    func test_healthz_returns_ok() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"status\":\"ok\""))
            }
        }
    }
}
