import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class ConsolidationEndpointsTests: XCTestCase {
    private func makeApp() async throws -> some ApplicationProtocol {
        let (app, _) = try await makeAppWithServices()
        return app
    }

    private func makeAppWithServices() async throws -> (some ApplicationProtocol, Services) {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = await Services(store: store,
                                      transcript: TranscriptStore(dbQueue: store.dbQueue),
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token",
                                      modelClient: NoOpModelClient())
        let app = try await buildApp(services: services, port: 0)
        return (app, services)
    }

    func test_state_endpoint_reports_counts() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/consolidation/state", method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"nodeCount\""))
                XCTAssertTrue(s.contains("\"transcriptCount\""))
                XCTAssertTrue(s.contains("\"isRunning\""))
            }
        }
    }

    func test_turn_end_endpoint_acks() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/consolidation/turn-end", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"threadId":"T"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    func testTurnEndAcceptsTimezone() async throws {
        let (app, services) = try await makeAppWithServices()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/consolidation/turn-end", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"threadId":"t1","timezone":"America/New_York"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        let tz = await services.scheduler.lastTimeZone
        XCTAssertEqual(tz.identifier, "America/New_York")
    }
}

struct NoOpModelClient: ModelTextClient {
    func generate(prompt: String, options: ModelTextOptions) async throws -> String { "{}" }
}
