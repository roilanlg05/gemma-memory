import XCTest
@testable import MemoryCore

/// Fake ModelTextClient that returns queued canned responses, one per generate() call.
final class CannedRuntime: ModelTextClient, @unchecked Sendable {
    var responses: [String]
    private var i = 0
    init(_ responses: [String]) { self.responses = responses }
    func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        let text = i < responses.count ? responses[i] : "{}"; i += 1
        return text
    }
}

final class MemoryConsolidationEngineTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }

    func test_consolidate_creates_structured_nodes_including_new_kind() async throws {
        let store = try makeStore()
        let rt = CannedRuntime([#"{"entities":[{"entity":"Juan","kind":"person","detail":"friend"},{"entity":"call Juan","kind":"task","attributes":{"status":"pending"}},{"entity":"Falcon","kind":"spaceship"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.consolidate(episodeTexts: ["I should call Juan, my friend, about the Falcon"])
        let kinds = Set(try store.allNodes().map { $0.kind })
        XCTAssertTrue(kinds.isSuperset(of: ["person", "task", "spaceship"]), "structured + model-minted kind stored verbatim")
        let task = try store.allNodes().first { $0.kind == "task" }
        XCTAssertEqual(NodeAttributes.from(task?.extra).status, "pending")
    }

    func test_associate_creates_edges_between_existing_nodes() async throws {
        let store = try makeStore()
        let now = Date().timeIntervalSince1970
        for (id, label) in [("a","Roilan"),("b","sushi")] {
            try store.upsert(Node(id: id, kind: "preference", label: label, body: label, layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        let rt = CannedRuntime([#"{"edges":[{"from":"Roilan","relation":"likes","to":"sushi"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.associate()
        XCTAssertEqual(try store.allEdges().count, 1)
        let e = try store.allEdges().first
        XCTAssertEqual(e?.relation, .likes)
    }

    func test_associate_skips_unknown_relation_and_unresolved_endpoints() async throws {
        let store = try makeStore()
        let rt = CannedRuntime([#"{"edges":[{"from":"Ghost","relation":"likes","to":"Nothing"},{"from":"X","relation":"bogusRel","to":"Y"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.associate()
        XCTAssertTrue(try store.allEdges().isEmpty)
    }

    func test_reflect_creates_grounded_insight_and_drops_ungrounded() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        for (id,l) in [("a","sushi"),("b","ramen")] {
            try store.upsert(Node(id: id, kind: "preference", label: l, body: l, layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        let rt = CannedRuntime([#"{"insights":[{"text":"likes Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"},{"text":"is a pilot","sourceEntities":["sushi"],"confidence":"maybe"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.reflect()
        let insights = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
        XCTAssertEqual(insights.count, 1, "only the ≥2-source insight is kept")
        XCTAssertEqual(insights.first?.body, "likes Japanese food")
        XCTAssertGreaterThanOrEqual(try store.allEdges().count, 2, "insight linked to ≥2 sources")
    }

    func test_reflect_is_idempotent_no_duplicate_insights() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        for (id,l) in [("a","sushi"),("b","ramen")] {
            try store.upsert(Node(id: id, kind: "preference", label: l, body: l, layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        // Same insight returned twice; second reflect() must find the existing node and skip it.
        let same = #"{"insights":[{"text":"likes Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"}]}"#
        let rt = CannedRuntime([same, same])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.reflect()
        await engine.reflect()
        let insights = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
        XCTAssertEqual(insights.count, 1, "re-run reflect() must not duplicate an existing insight")
    }

    func test_curate_folds_synonym_kind() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "a", kind: "meta", label: "learn German", body: "", layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 1, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        let rt = CannedRuntime([#"{"map":{"meta":"plan"}}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.curateKinds()
        XCTAssertEqual(try store.node(id: "a")?.kind, "plan")
    }

    func test_forget_sweeps_weak_and_prunes_edges() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let old = Date().timeIntervalSince1970 - 10_000_000   // long ago → effective salience ~0
        try store.upsert(Node(id: "w", kind: "fact", label: "weak", body: "", layer: .daily, createdAt: old, updatedAt: old, lastSeenAt: old, salience: 0.1, decayRate: 1.0/(5*24*3600), confidence: .maybe, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil))
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: CannedRuntime([]))
        await engine.forget()
        XCTAssertTrue(try store.allNodes().isEmpty, "weak node forgotten")
    }

    func test_runCycle_resumes_from_persisted_phase() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me gusta el sushi", now: 1)
        let id = try ts.unconsolidated(limit: 1)[0].id
        try store.saveSleepCycle(SleepCycleState(phase: .shy, episodeIds: [id], startedAt: 1))
        var progress: [String] = []
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: CannedRuntime([]), transcriptStore: ts)
        engine.onProgress = { progress.append($0) }
        await engine.runCycle(isCancelled: { false })
        XCTAssertNil(try store.loadSleepCycle(), "cycle cleared after completing from .shy")
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 0, ".shy still marks episodes consolidated")
        XCTAssertFalse(progress.contains { $0.contains("entities") || $0.contains("summary") },
                       "resuming from .shy must SKIP nrem/summarize")
    }

    func test_runCycle_cancel_persists_phase_for_resume() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "hi", now: Date().timeIntervalSince1970)
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime(["{}","{}","{}","{}"]), transcriptStore: ts)
        await engine.runCycle(isCancelled: { true })   // cancels immediately
        // a cycle was started (phase persisted) and NOT cleared
        XCTAssertNotNil(try store.loadSleepCycle())
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 1, "not yet consolidated when cancelled")
    }

    func test_detect_creates_followup_nodes() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let rt = CannedRuntime([#"{"followUps":[{"text":"finish telling the story about the trip","sources":[]},{"text":"decide where to travel","sources":[]}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.detectFollowUps(episodeTexts: ["I was about to tell you about my trip but then..."])
        let fu = try store.allNodes().filter { $0.kind == NodeKind.followUp.rawValue }
        XCTAssertEqual(fu.count, 2)
        XCTAssertTrue(fu.allSatisfy { NodeAttributes.from($0.extra).status == "pending" })
    }
    func test_detect_dedups_repeats() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let json = #"{"followUps":[{"text":"call the dentist back","sources":[]}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([json, json]))
        await engine.detectFollowUps(episodeTexts: ["x"])
        await engine.detectFollowUps(episodeTexts: ["x"])
        XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.followUp.rawValue }.count, 1)
    }
    func test_detect_links_sources_to_entities() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "juan", kind: NodeKind.person.rawValue, label: "Juan", body: "Juan", layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        let rt = CannedRuntime([#"{"followUps":[{"text":"hear about Juan's news","sources":["Juan"]}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.detectFollowUps(episodeTexts: ["Juan was going to tell me his news"])
        let fu = try store.allNodes().first { $0.kind == NodeKind.followUp.rawValue }
        XCTAssertNotNil(fu, "follow_up node created")
        let edges = try store.allEdges()
        XCTAssertTrue(edges.contains { $0.srcId == fu?.id && $0.dstId == "juan" && $0.relation == .relatedTo },
                      "follow_up linked to its source entity Juan")
    }
    func test_runCycle_consumes_transcript_and_marks_consolidated() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "t", turnIndex: 0, role: "user", text: "me llamo Roilan y me gusta el sushi", now: 1)
        try ts.append(threadId: "t", turnIndex: 0, role: "assistant", text: "¡Genial!", now: 2)
        // phase order: nrem, summarize, detect, rem, reflect, clarify, curate (shy needs no model)
        let runtime = CannedRuntime([
            #"{"entities":[{"entity":"sushi","kind":"preference","detail":"likes it"}]}"#,
            #"{"topic":"presentación","concepts":["nombre Roilan","gusto sushi"],"intent":"","decisions":[],"importance":0.5,"summary":"El usuario se presenta."}"#,
            #"{"followUps":[]}"#, #"{"edges":[]}"#, #"{"insights":[]}"#, #"{"questions":[]}"#, #"{"map":{}}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.runCycle(isCancelled: { false })
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 0, "consumed transcript turns must be marked consolidated")
        XCTAssertNotNil(try store.allNodes().first { $0.kind == "preference" && $0.label == "sushi" })
    }

    func test_summarize_groups_by_thread_one_summary_per_session() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "A", turnIndex: 0, role: "user", text: "quiero ir a Japón", now: 1)
        try ts.append(threadId: "B", turnIndex: 0, role: "user", text: "me gusta el ajedrez", now: 2)
        let runtime = CannedRuntime([
            #"{"entities":[]}"#,
            #"{"topic":"viaje Japón","concepts":["Japón"],"summary":"viaje"}"#,
            #"{"topic":"ajedrez","concepts":["ajedrez"],"summary":"hobby"}"#,
            #"{"followUps":[]}"#, #"{"edges":[]}"#, #"{"insights":[]}"#, #"{"questions":[]}"#, #"{"map":{}}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.runCycle(isCancelled: { false })
        let summaries = try store.allNodes().filter { $0.kind == NodeKind.summary.rawValue }
        XCTAssertEqual(Set(summaries.map { $0.label }), ["viaje Japón", "ajedrez"], "one summary per thread")
    }

    func test_summarize_writes_structured_summary_node() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let runtime = CannedRuntime([
            #"{"topic":"viaje a Japón","concepts":["Tokio","sushi","abril"],"intent":"planear un viaje","decisions":["ir en abril"],"importance":0.8,"summary":"El usuario planea un viaje a Japón en abril."}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.summarize(episodeTexts: ["User: quiero ir a Japón en abril"], threadId: "t", turnRange: 0...3)
        let summary = try XCTUnwrap(try store.allNodes().first { $0.kind == NodeKind.summary.rawValue })
        XCTAssertEqual(summary.label, "viaje a Japón")
        let extra = try XCTUnwrap(summary.extra?.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: extra) as? [String: Any])
        XCTAssertEqual(obj["concepts"] as? [String], ["Tokio", "sushi", "abril"])
        XCTAssertEqual(obj["threadId"] as? String, "t")
        XCTAssertEqual((obj["turnRange"] as? [Int]), [0, 3])
    }

    func test_summarizeRecent_creates_summary_without_marking_consolidated() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "S", turnIndex: 0, role: "user", text: "tengo astigmatismo leve", now: 1)
        try ts.append(threadId: "S", turnIndex: 0, role: "assistant", text: "anotado", now: 2)
        let runtime = CannedRuntime([
            #"{"topic":"astigmatismo","concepts":["ojos","vista","astigmatismo"],"summary":"El usuario tiene astigmatismo leve."}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.summarizeRecent()
        let summary = try XCTUnwrap(try store.allNodes().first { $0.kind == NodeKind.summary.rawValue })
        XCTAssertEqual(summary.label, "astigmatismo")
        XCTAssertTrue(summary.body.localizedCaseInsensitiveContains("ojos"), "concepts folded into body for FTS recall")
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 2, "summarizeRecent must NOT mark turns consolidated")
    }

    func test_summarizeRecent_skips_threads_already_summarized() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "S", turnIndex: 0, role: "user", text: "hola", now: 1)
        let runtime = CannedRuntime([#"{"topic":"saludo","concepts":["hola"],"summary":"saludo"}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.summarizeRecent()
        await engine.summarizeRecent()   // 2nd call must NOT re-summarize thread S (only 1 canned response exists)
        XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.summary.rawValue }.count, 1)
    }

    func test_consolidate_stores_absolute_date_for_a_task() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "mañana reunión con Carlos", now: 1)
        let runtime = CannedRuntime([
            #"{"entities":[{"entity":"reunión con Carlos","kind":"task","detail":"meeting","attributes":{"status":"pending","date":"2026-06-02"}}]}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.consolidate(episodeTexts: ["User: mañana reunión con Carlos"])
        let task = try XCTUnwrap(try store.allNodes().first { $0.kind == NodeKind.task.rawValue })
        XCTAssertEqual(NodeAttributes.from(task.extra).date, "2026-06-02")
        XCTAssertTrue(task.body.contains("2026-06-02"), "absolute date folded into body")
    }

    func test_distinct_tasks_are_not_merged() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "x", now: 1)
        let runtime = CannedRuntime([
            #"{"entities":[{"entity":"reunión con Carlos","kind":"task","detail":"mañana","attributes":{"status":"pending","date":"2026-06-02"}},{"entity":"reunión con Carlos","kind":"task","detail":"miércoles","attributes":{"status":"pending","date":"2026-06-04"}}]}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.consolidate(episodeTexts: ["User: x"])
        let tasks = try store.allNodes().filter { $0.kind == NodeKind.task.rawValue }
        XCTAssertEqual(tasks.count, 2, "two distinct meetings (different dates) must NOT collapse into one")
    }

    func test_consolidate_emitsStructuredEvent_whenStartEndPresent() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        // Fake runtime returns one event-like entity with epoch start/end.
        final class EventRuntime: ModelTextClient, @unchecked Sendable {
            func generate(prompt: String, options: ModelTextOptions) async throws -> String {
                #"{"entities":[{"entity":"dentist appointment","kind":"task","detail":"dentist","attributes":{"status":"pending","date":"2026-06-04","start":1780653600,"end":1780657200}}]}"#
            }
        }
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 8),
                                               runtime: EventRuntime(), transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
        await engine.consolidate(episodeTexts: ["User: dentista jueves 10am"])
        let events = try store.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertEqual(events.count, 1)
        let a = NodeAttributes.from(events[0].extra)
        XCTAssertEqual(a.startAt, 1_780_653_600)
        XCTAssertEqual(a.endAt, 1_780_657_200)
        XCTAssertTrue(try store.allNodes().filter { $0.kind == NodeKind.task.rawValue }.isEmpty,
                      "a timed entity must become an event, not also a task")
    }

    func test_clarify_emits_clarification_node_when_unsure() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        func task(_ id: String, _ label: String, _ detail: String) -> Node {
            Node(id: id, kind: NodeKind.task.rawValue, label: label, body: detail, layer: .daily, createdAt: 1, updatedAt: 1,
                 lastSeenAt: 1, salience: 3, decayRate: 0.1, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                 sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        try store.upsert(task("t1", "reunión con Carlos", "mañana"))
        try store.upsert(task("t2", "reunión con Carlos", "miércoles"))
        let runtime = CannedRuntime([
            #"{"questions":["¿La reunión con Carlos del miércoles es la misma que la de mañana o son dos distintas?"]}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.clarify()
        let q = try XCTUnwrap(try store.allNodes().first { $0.kind == NodeKind.clarification.rawValue })
        XCTAssertTrue(q.body.contains("Carlos"))
        XCTAssertEqual(NodeAttributes.from(q.extra).status, "pending")
    }
}
