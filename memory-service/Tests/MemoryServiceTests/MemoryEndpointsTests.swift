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
        try await makeAppWithServices().0
    }

    /// Like `makeApp()` but also returns the `Services` so tests can seed `transcript`/`store`/`embedder` directly.
    private func makeAppWithServices() async throws -> (some ApplicationProtocol, Services) {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: ts, embedder: FakeEmbedder(dimension: 8),
                                       bearerToken: "test-token")
        let app = try await buildApp(services: services, port: 0)
        return (app, services)
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

    func test_recall_returns_recent_turns_from_other_threads_only() async throws {
        let (app, services) = try await makeAppWithServices()
        // Seed thread A (a relevant turn) and thread B (the current thread). Embed each turn so
        // nearestTranscript can rank them.
        let aId = try services.transcript.append(threadId: "A", turnIndex: 0, role: "user",
                                                 text: "voy a Varadero la próxima semana")
        try services.store.setTranscriptEmbedding(turnId: aId, services.embedder.embed("voy a Varadero la próxima semana"))
        let bId = try services.transcript.append(threadId: "B", turnIndex: 0, role: "user", text: "hola")
        try services.store.setTranscriptEmbedding(turnId: bId, services.embedder.embed("hola"))
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/recall", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"query":"qué planes tengo","threadId":"B"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("recentTurns"))
                XCTAssertTrue(body.contains("Varadero"), body)              // from thread A
                XCTAssertFalse(body.contains("\"text\":\"hola\""), body)     // current thread B excluded
            }
        }
    }

    func test_save_self_kind_routes_to_singleton() async throws {
        let (app, services) = try await makeAppWithServices()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/save", method: .post,
                                     headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"kind":"self","label":"Roilan","body":"el usuario"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        XCTAssertEqual(try services.store.selfNode()?.label, "Roilan")
        XCTAssertEqual(try services.store.selfNode()?.kind, NodeKind.selfUser.rawValue)
        let selves = try services.store.allNodes().filter { $0.kind == NodeKind.selfUser.rawValue }
        XCTAssertEqual(selves.count, 1)   // singleton — no generic duplicate
    }

    func test_recall_returns_summaries_tier_with_refs() async throws {
        let (app, services) = try await makeAppWithServices()
        let extra = #"{"concepts":["opciones"],"intent":"","decisions":[],"importance":0.6,"threadId":"g7y","turnRange":[21,56]}"#
        let summary = Node(id: "sum1", kind: NodeKind.summary.rawValue, label: "trading opciones",
                           body: "El usuario hace trading de opciones", layer: .daily,
                           createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                           salience: 4, decayRate: 0, confidence: .probable, mentionCount: 1,
                           ttlExpiresAt: nil, sourceRef: "g7y", origin: .extracted, serverId: nil,
                           dirty: true, deleted: false, extra: extra)
        try services.store.upsert(summary)
        try services.store.setEmbedding(nodeId: "sum1", services.embedder.embed("trading opciones"))
        struct Out: Decodable {
            struct S: Decodable { let summaryId: String; let chatId: String; let messageRange: [Int]; let text: String }
            struct N: Decodable { let kind: String }
            let recall: [N]; let summaries: [S]
        }
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/recall", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"query":"trading opciones"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let out = try JSONDecoder().decode(Out.self, from: Data(buffer: res.body))
                XCTAssertEqual(out.summaries.first?.summaryId, "sum1")
                XCTAssertEqual(out.summaries.first?.chatId, "g7y")
                XCTAssertEqual(out.summaries.first?.messageRange, [21, 56])
                XCTAssertFalse(out.recall.contains { $0.kind == "summary" }, "summaries must be split out of recall")
            }
        }
    }

    func test_recall_attaches_tags_and_filters_by_tag() async throws {
        let (app, services) = try await makeAppWithServices()
        func seed(_ id: String, _ label: String, tags: [String]) throws {
            let n = Node(id: id, kind: NodeKind.preference.rawValue, label: label, body: label, layer: .daily,
                         createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 5, decayRate: 0, confidence: .probable,
                         mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                         dirty: true, deleted: false, extra: nil)
            try services.store.upsert(n)
            try services.store.setEmbedding(nodeId: id, services.embedder.embed(label))
            try services.store.setTags(nodeId: id, tags)
        }
        try seed("n1", "opciones", tags: ["trading"])
        try seed("n2", "yoga", tags: ["salud"])
        struct Out: Decodable {
            struct N: Decodable { let label: String; let tags: [String] }
            let recall: [N]
        }
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/recall", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"query":"opciones","tag":"trading"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let out = try JSONDecoder().decode(Out.self, from: Data(buffer: res.body))
                XCTAssertTrue(out.recall.contains { $0.label == "opciones" && $0.tags == ["trading"] },
                              "recall must contain opciones with [trading]")
                XCTAssertFalse(out.recall.contains { $0.label == "yoga" },
                               "yoga must be filtered out by tag=trading")
            }
        }
    }

    func test_memory_tags_and_by_topic() async throws {
        let (app, services) = try await makeAppWithServices()
        // FakeEmbedder(dimension:8) is hash-based, not semantic. Verified with Python simulation:
        //   cosine_dist("geologia", "trading") ≈ 0.36, cosine_dist("geologia", "salud") ≈ 0.31
        // Both are > 0.2 threshold, so "geologia" correctly resolves to no tag.
        // (Using "astrofisica" would FAIL: its hash happens to land within 0.163 of "trading".)
        func seed(_ id: String, _ label: String, tags: [String]) throws {
            let n = Node(id: id, kind: NodeKind.preference.rawValue, label: label, body: "body-\(label)", layer: .daily,
                         createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable,
                         mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                         dirty: true, deleted: false, extra: nil)
            try services.store.upsert(n)
            try services.store.setTags(nodeId: id, tags)
        }
        try seed("n1", "calls", tags: ["trading"])
        try seed("n2", "puts",  tags: ["trading"])
        try seed("n3", "yoga",  tags: ["salud"])

        struct Tags: Decodable { let tags: [String] }
        struct Topic: Decodable {
            struct N: Decodable { let kind: String; let label: String; let body: String }
            let tag: String; let nodes: [N]
        }
        try await app.test(.live) { client in
            // /v1/memory/tags — distinct sorted tags
            try await client.execute(uri: "/v1/memory/tags", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let out = try JSONDecoder().decode(Tags.self, from: Data(buffer: res.body))
                XCTAssertEqual(out.tags, ["salud", "trading"])
            }
            // /v1/memory/by_topic — exact-match resolves "trading"
            try await client.execute(uri: "/v1/memory/by_topic?topic=trading", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let out = try JSONDecoder().decode(Topic.self, from: Data(buffer: res.body))
                XCTAssertEqual(out.tag, "trading")
                XCTAssertEqual(Set(out.nodes.map { $0.label }), ["calls", "puts"])
            }
            // /v1/memory/by_topic — "geologia" is > 0.2 from all tags → empty
            try await client.execute(uri: "/v1/memory/by_topic?topic=geologia", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let out = try JSONDecoder().decode(Topic.self, from: Data(buffer: res.body))
                XCTAssertEqual(out.tag, "")
                XCTAssertTrue(out.nodes.isEmpty)
            }
        }
    }

    func test_memory_why_traces_insight_to_sources() async throws {
        let (app, services) = try await makeAppWithServices()
        func mk(_ id: String, _ kind: String, _ label: String, _ body: String) throws {
            let n = Node(id: id, kind: kind, label: label, body: body, layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                         salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                         origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
            try services.store.upsert(n)
        }
        try mk("ins", NodeKind.insight.rawValue, "trades options actively", "trades options actively")
        try mk("s1", NodeKind.preference.rawValue, "calls", "calls")
        try mk("s2", NodeKind.preference.rawValue, "puts", "puts")
        for s in ["s1", "s2"] {
            try services.store.upsert(Edge(id: UUID().uuidString, srcId: "ins", dstId: s, relation: .derivesFrom,
                                           weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
        }
        struct Why: Decodable { struct N: Decodable { let label: String }; let insight: String; let sources: [N] }
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/why?claim=trades%20options", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                let out = try JSONDecoder().decode(Why.self, from: Data(buffer: res.body))
                XCTAssertEqual(out.insight, "trades options actively")
                XCTAssertEqual(Set(out.sources.map { $0.label }), ["calls", "puts"])
            }
        }
    }

    func test_memory_why_empty_when_no_insight_exists() async throws {
        let (app, services) = try await makeAppWithServices()
        // A non-insight node exists, but NO insight → why can't locate anything → empty (deterministic:
        // both the FTS and semantic paths filter to kind==insight, of which there are none).
        let n = Node(id: "p", kind: NodeKind.preference.rawValue, label: "calls", body: "calls", layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable,
                     mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                     dirty: true, deleted: false, extra: nil)
        try services.store.upsert(n)
        struct Why: Decodable { struct N: Decodable { let label: String }; let insight: String; let sources: [N] }
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/why?claim=calls", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                let out = try JSONDecoder().decode(Why.self, from: Data(buffer: res.body))
                XCTAssertTrue(out.insight.isEmpty)
                XCTAssertTrue(out.sources.isEmpty)
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
