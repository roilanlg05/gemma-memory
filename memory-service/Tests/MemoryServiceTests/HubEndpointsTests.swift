import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class HubEndpointsTests: XCTestCase {
    @MainActor
    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        try store.ensureKindHubs()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = Services(store: store, transcript: ts,
                                embedder: FakeEmbedder(dimension: 8),
                                bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }

    func test_byHub_filters_by_status() async throws {
        // Seed nodes directly (bypassing the embedder-driven semantic-dedup path of
        // /v1/memory/save, which would collapse our 3 short test tasks into 1 under the
        // FakeEmbedder). This test is about the HUB query — endpoint correctness — not
        // about dedup behavior, so direct writes give us the deterministic 3-distinct-rows
        // setup the assertions expect.
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        try store.ensureKindHubs()
        for (id, label, extra) in [
            ("t1", "buy milk",   #"{"status":"pending","date":"2026-06-04"}"#),
            ("t2", "call mom",   #"{"status":"pending","date":"2026-06-03"}"#),
            ("t3", "file taxes", #"{"status":"done","date":"2026-06-01"}"#),
        ] {
            try store.upsert(Node(id: id, kind: NodeKind.task.rawValue, label: label, body: label,
                                  layer: .live, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                                  salience: 1, decayRate: 0.1, confidence: .probable,
                                  mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                                  origin: .extracted, serverId: nil, dirty: false, deleted: false,
                                  extra: extra))
        }
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: ts,
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token")
        let app = try await buildApp(services: services, port: 0)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/byHub?kind=task&status=pending&sort=date",
                                     method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("call mom"))
                XCTAssertTrue(s.contains("buy milk"))
                XCTAssertFalse(s.contains("file taxes"))
                if let a = s.range(of: "call mom")?.lowerBound,
                   let b = s.range(of: "buy milk")?.lowerBound {
                    XCTAssertTrue(a < b, "pending ordered by date asc (06-03 before 06-04)")
                }
            }
        }
    }

    func test_byHub_rejects_unknown_kind() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/byHub?kind=nonsense",
                                     method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .badRequest)
            }
        }
    }

    func test_byEntity_returns_neighbors() async throws {
        // Seed a person + preference + manual mentionedIn-like edge via raw save endpoints.
        // The save endpoint doesn't create edges between nodes; for this E2E we exercise
        // the underlying store API directly via Services (still through MemoryCore).
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        try store.ensureKindHubs()
        let roilan = Node(id: "ent", kind: NodeKind.person.rawValue, label: "Roilan", body: "el usuario",
                          layer: .identity, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                          salience: 5, decayRate: 0.05, confidence: .sure, mentionCount: 1,
                          ttlExpiresAt: nil, sourceRef: nil, origin: .explicit,
                          serverId: nil, dirty: false, deleted: false, extra: nil)
        let pref = Node(id: "pref", kind: NodeKind.preference.rawValue, label: "sushi", body: "le gusta el sushi",
                        layer: .live, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                        salience: 1, decayRate: 0.1, confidence: .probable, mentionCount: 1,
                        ttlExpiresAt: nil, sourceRef: nil, origin: .extracted,
                        serverId: nil, dirty: false, deleted: false, extra: nil)
        try store.upsert(roilan); try store.upsert(pref)
        try store.upsert(Edge(id: "e", srcId: roilan.id, dstId: pref.id,
                              relation: .likes, weight: 1, confidence: .sure,
                              createdAt: 1, updatedAt: 1, dirty: false, deleted: false, extra: nil))

        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: ts,
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token")
        let app = try await buildApp(services: services, port: 0)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/byEntity?label=Roilan",
                                     method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("sushi"), "entity neighborhood should include `sushi`: \(s)")
                XCTAssertFalse(s.contains("\"id\":\"ent\""), "entity itself should be excluded")
            }
        }
    }
}
