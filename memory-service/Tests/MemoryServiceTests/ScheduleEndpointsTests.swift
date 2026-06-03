import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class ScheduleEndpointsTests: XCTestCase {
    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = await Services(store: store,
                                      transcript: TranscriptStore(dbQueue: store.dbQueue),
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }

    func test_create_then_check_conflict_then_window() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // create a trip [1000,2000)
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Trip","start":1000,"end":2000,"allDay":true,"origin":"user"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true"))
            }
            // check a conflicting slot [1500,1600)
            try await client.execute(uri: "/v1/schedule/check", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"start":1500,"end":1600}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("Trip"))
            }
            // create conflicting without force → not created
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Meeting","start":1500,"end":1600,"origin":"user","force":false}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":false"))
            }
            // window returns the trip
            try await client.execute(uri: "/v1/schedule/window?from=0&to=5000", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("Trip"))
            }
        }
    }
}
