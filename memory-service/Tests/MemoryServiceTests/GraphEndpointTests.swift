import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class GraphEndpointTests: XCTestCase {
    @MainActor
    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = Services(store: store, transcript: ts,
                                embedder: FakeEmbedder(dimension: 8),
                                bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }

    func test_graph_endpoint_returns_nodes_and_edges() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // seed two nodes via /v1/memory/save (any kind triggers a save)
            for label in ["Roilan", "sushi"] {
                let body = #"{"kind":"preference","label":"\#(label)"}"#
                try await client.execute(uri: "/v1/memory/save", method: .post,
                                         headers: [.authorization: "Bearer test-token",
                                                   .contentType: "application/json"],
                                         body: ByteBuffer(string: body)) { res in
                    XCTAssertEqual(res.status, .ok)
                }
            }
            try await client.execute(uri: "/v1/graph", method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"nodes\""), "missing nodes key: \(s)")
                XCTAssertTrue(s.contains("\"edges\""), "missing edges key: \(s)")
                XCTAssertTrue(s.contains("Roilan"))
                XCTAssertTrue(s.contains("sushi"))
            }
        }
    }

    func test_graph_endpoint_empty_when_no_nodes() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/graph", method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"nodes\":[]"))
                XCTAssertTrue(s.contains("\"edges\":[]"))
            }
        }
    }
}
