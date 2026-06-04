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
        let t = Date().timeIntervalSince1970
        func mkNode(_ id: String, _ kind: String, _ label: String) -> Node {
            Node(id: id, kind: kind, label: label, body: label, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        // Seed 3 preference members so the cluster meets the ≥3-member threshold.
        for (id, l) in [("a","sushi"),("b","ramen"),("c","tempura")] {
            try store.upsert(mkNode(id, NodeKind.preference.rawValue, l))
        }
        try store.upsert(mkNode("cl", NodeKind.cluster.rawValue, "japanese"))
        for m in ["a","b","c"] {
            try store.upsert(Edge(id: UUID().uuidString, srcId: "cl", dstId: m, relation: .belongsToCluster,
                                  weight: 1, confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
        }
        let rt = CannedRuntime([#"{"insights":[{"text":"likes Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"},{"text":"is a pilot","sourceEntities":["sushi"],"confidence":"maybe"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.reflect()
        let insights = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
        XCTAssertEqual(insights.count, 1, "only the ≥2-source insight is kept")
        XCTAssertEqual(insights.first?.body, "likes Japanese food")
        let ins = try XCTUnwrap(insights.first)
        let provEdges = try store.edges(from: ins.id).filter { $0.relation == .derivesFrom }
        XCTAssertGreaterThanOrEqual(provEdges.count, 2, "insight linked to ≥2 sources via derivesFrom")
    }

    func test_reflect_is_idempotent_no_duplicate_insights() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let t = Date().timeIntervalSince1970
        func mkNode(_ id: String, _ kind: String, _ label: String) -> Node {
            Node(id: id, kind: kind, label: label, body: label, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        for (id, l) in [("a","sushi"),("b","ramen"),("c","tempura")] {
            try store.upsert(mkNode(id, NodeKind.preference.rawValue, l))
        }
        try store.upsert(mkNode("cl", NodeKind.cluster.rawValue, "japanese"))
        for m in ["a","b","c"] {
            try store.upsert(Edge(id: UUID().uuidString, srcId: "cl", dstId: m, relation: .belongsToCluster,
                                  weight: 1, confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
        }
        // Same insight returned on both reflect() calls (one call per cluster per reflect() invocation).
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

    func test_summaryGroups_uses_seq_for_range() throws {
        let rows = [
            TranscriptRow(id: "1", threadId: "A", turnIndex: 0, seq: 1, role: "user", text: "hola", createdAt: 1, consolidated: false),
            TranscriptRow(id: "2", threadId: "A", turnIndex: 0, seq: 2, role: "assistant", text: "qué tal", createdAt: 2, consolidated: false),
            TranscriptRow(id: "3", threadId: "A", turnIndex: 1, seq: 3, role: "user", text: "bien", createdAt: 3, consolidated: false),
            TranscriptRow(id: "4", threadId: "B", turnIndex: 0, seq: 1, role: "user", text: "otro chat", createdAt: 4, consolidated: false),
        ]
        let groups = MemoryConsolidationEngine.summaryGroups(rows)
        let a = groups.first { $0.threadId == "A" }
        XCTAssertEqual(a?.range, 1...3)                 // seq-based, not turnIndex (which is 0..1)
        XCTAssertEqual(a?.texts.count, 3)
        XCTAssertEqual(a?.texts.first, "User: hola")
        XCTAssertEqual(a?.texts[1], "Gemma: qué tal")
        let b = groups.first { $0.threadId == "B" }
        XCTAssertEqual(b?.range, 1...1)
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

    func test_consolidate_emitsStructuredEvent_whenDateTimePresent() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        // Fake runtime returns one event-like entity with a local date + start/end time.
        let rt = CannedRuntime([#"{"entities":[{"entity":"dentist appointment","kind":"event","detail":"dentist","attributes":{"date":"2026-06-04","startTime":"10:00","endTime":"11:00"}}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 8),
                                               runtime: rt, transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
        await engine.consolidate(episodeTexts: ["User: dentista jueves 10am"])
        let events = try store.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertEqual(events.count, 1)
        let a = NodeAttributes.from(events[0].extra)
        let expectStart = ScheduleTime.epoch(date: "2026-06-04", time: "10:00", tz: .current)!
        let expectEnd = ScheduleTime.epoch(date: "2026-06-04", time: "11:00", tz: .current)!
        XCTAssertEqual(a.startAt, expectStart)
        XCTAssertEqual(a.endAt, expectEnd)
        XCTAssertTrue(try store.allNodes().filter { $0.kind == NodeKind.task.rawValue }.isEmpty,
                      "a timed entity must become an event, not also a task")
    }

    func testConsolidateCleanEventUsesExactLocalEpoch() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let json = #"{"entities":[{"entity":"Dentist","kind":"event","attributes":{"date":"2026-06-11","startTime":"09:00","endTime":"10:00","location":"Clinic"}}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: CannedRuntime([json]),
                                               transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
        await engine.consolidate(episodeTexts: ["User: dentist June 11 9am"])
        let evs = try store.scheduleWindow(from: 0, to: 1e11)
        XCTAssertEqual(evs.count, 1)
        let a = NodeAttributes.from(evs[0].extra)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: a.startAt!))
        XCTAssertEqual(c.hour, 9); XCTAssertEqual(c.minute, 0)
        XCTAssertEqual(a.location, "Clinic")
    }

    func testConsolidateConflictingEventEmitsClarificationNotEvent() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        // Seed the trip in TimeZone.current so it deterministically overlaps the consolidated
        // meeting (consolidate() resolves the new event in currentTimeZone, which defaults to .current).
        let st = ScheduleTime.epoch(date: "2026-06-09", time: "06:00", tz: .current)!
        let en = ScheduleTime.epoch(date: "2026-06-13", time: "06:00", tz: .current)!
        _ = try store.createEventChecked(title: "Varadero trip", start: st, end: en, allDay: true,
                                         location: "Varadero", origin: .explicit, force: true)
        let json = #"{"entities":[{"entity":"Miami meeting","kind":"event","attributes":{"date":"2026-06-09","startTime":"08:00","endTime":"09:00","location":"Miami"}}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: CannedRuntime([json]),
                                               transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
        await engine.consolidate(episodeTexts: ["User: meeting in Miami June 9 8am"])
        XCTAssertEqual(try store.scheduleWindow(from: 0, to: 1e11).count, 1) // no 2nd event
        let clar = try store.allNodes().filter { $0.kind == NodeKind.clarification.rawValue }
        XCTAssertEqual(clar.count, 1)
        let edges = try store.edges(from: clar[0].id).filter { $0.relation == .clarifies }
        XCTAssertEqual(edges.count, 1)
    }

    func test_consolidate_routes_self_kind_to_singleton() async throws {
        let store = try makeStore()
        let json = #"{"entities":[{"entity":"Roilan","kind":"self","detail":"el usuario"},{"entity":"María","kind":"person","detail":"esposa"}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: CannedRuntime([json]))
        await engine.consolidate(episodeTexts: ["User: me llamo Roilan, mi esposa es María"])
        XCTAssertEqual(try store.selfNode()?.label, "Roilan")
        XCTAssertEqual(try store.selfNode()?.kind, NodeKind.selfUser.rawValue)
        let people = try store.allNodes().filter { $0.kind == NodeKind.person.rawValue }
        XCTAssertTrue(people.contains { $0.label == "María" && $0.body.contains("esposa") })
    }

    func test_associate_links_self_to_people() async throws {
        let store = try makeStore()
        _ = try store.upsertSelf(name: "Roilan", detail: nil, embedder: nil)
        let now = Date().timeIntervalSince1970
        let maria = Node(id: "m1", kind: NodeKind.person.rawValue, label: "María", body: "esposa",
                         layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001,
                         confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                         origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(maria)
        let rt = CannedRuntime([#"{"edges":[{"from":"Roilan","relation":"family","to":"María"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.associate()
        let familyEdges = try store.edges(from: selfUserID).filter { $0.relation == .family }
        XCTAssertEqual(familyEdges.first?.dstId, "m1")
    }

    func test_embedMissing_embeds_only_unembedded_clusterable_nodes() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        func mk(_ id: String, _ kind: String) -> Node {
            Node(id: id, kind: kind, label: id, body: id, layer: .daily, createdAt: 1, updatedAt: 1,
                 lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1,
                 ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        try store.upsert(mk("p1", NodeKind.preference.rawValue))   // clusterable, no embedding
        try store.upsert(mk("e1", NodeKind.event.rawValue))        // NOT clusterable → skipped
        XCTAssertTrue(try store.allEmbeddings().isEmpty)
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([]))
        await engine.embedMissing()
        let embedded = Set(try store.allEmbeddings().map { $0.id })
        XCTAssertEqual(embedded, ["p1"])                            // only the clusterable, un-embedded node
        // idempotent: a second run embeds nothing new
        await engine.embedMissing()
        XCTAssertEqual(try store.allEmbeddings().count, 1)
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

    func test_cluster_builds_anchors_and_belongsTo_edges() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let seeds: [(String, [Float])] = [
            ("a", [1, 0, 0, 0]), ("b", [0.98, 0.02, 0, 0]), ("c", [0.97, 0.03, 0, 0]),
            ("x", [0, 0, 1, 0]), ("y", [0, 0, 0.98, 0.02]), ("z", [0, 0, 0.97, 0.03]),
        ]
        for (id, vec) in seeds {
            let n = Node(id: id, kind: NodeKind.preference.rawValue, label: id, body: id, layer: .daily,
                         createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0,
                         confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                         origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
            try store.upsert(n); try store.setEmbedding(nodeId: id, vec)
        }
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([]))
        await engine.cluster()
        let clusters = try store.clusterNodes()            // allNodes() excludes cluster kind — use clusterNodes()
        XCTAssertEqual(clusters.count, 2)
        for c in clusters {
            let members = (try store.edges(from: c.id)).filter { $0.relation == .belongsToCluster }
            XCTAssertEqual(members.count, 3)
        }
        // re-running rebuilds globally (still 2, no duplicate anchors)
        await engine.cluster()
        XCTAssertEqual(try store.clusterNodes().count, 2)
    }

    func test_tagClusters_writes_tags_to_members_and_collapses_synonyms() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 64)
        func mk(_ id: String, _ kind: String) -> Node {
            Node(id: id, kind: kind, label: id, body: id, layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                 salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                 origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        try store.upsert(mk("m1", NodeKind.preference.rawValue))
        try store.upsert(mk("m2", NodeKind.preference.rawValue))
        try store.setTags(nodeId: "old", ["trading"])                       // seed the vocabulary
        var anchor = mk("clusterA", NodeKind.cluster.rawValue); anchor.label = "cluster"; try store.upsert(anchor)
        for m in ["m1", "m2"] {
            try store.upsert(Edge(id: UUID().uuidString, srcId: "clusterA", dstId: m, relation: .belongsToCluster,
                                  weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
        }
        let stub = SynonymStubEmbedder(near: ["inversión": "trading"], dim: 64)   // "inversión" embeds == "trading"
        let json = #"{"tags":["inversión"]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: stub, runtime: CannedRuntime([json]))
        await engine.tagClusters()
        XCTAssertEqual(try store.tagsFor(nodeId: "m1"), ["trading"])          // synonym collapsed
        XCTAssertEqual(try store.tagsFor(nodeId: "m2"), ["trading"])
        XCTAssertEqual(try store.node(id: "clusterA")?.label, "trading")      // anchor renamed to primary tag
    }

    func test_tagClusters_clears_stale_tags_on_cluster_dropout() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 64)
        func mk(_ id: String, _ kind: String) -> Node {
            Node(id: id, kind: kind, label: id, body: id, layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                 salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                 origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        try store.upsert(mk("m1", NodeKind.preference.rawValue))
        try store.upsert(mk("dropout", NodeKind.preference.rawValue))
        try store.setTags(nodeId: "dropout", ["old"])                        // previously tagged, now in no cluster
        var anchor = mk("clusterA", NodeKind.cluster.rawValue); anchor.label = "cluster"; try store.upsert(anchor)
        try store.upsert(Edge(id: UUID().uuidString, srcId: "clusterA", dstId: "m1", relation: .belongsToCluster,
                              weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
        let engine = MemoryConsolidationEngine(store: store, embedder: SynonymStubEmbedder(near: [:], dim: 64),
                                               runtime: CannedRuntime([#"{"tags":["salud"]}"#]))
        await engine.tagClusters()
        XCTAssertEqual(try store.tagsFor(nodeId: "m1"), ["salud"])            // current member tagged
        XCTAssertEqual(try store.tagsFor(nodeId: "dropout"), [])              // stale tag cleared (no longer clustered)
    }

    // MARK: Phase order

    func test_runCycle_order_is_machine_native() {
        XCTAssertEqual(MemoryConsolidationEngine.cycleOrder,
                       [.nrem, .summarize, .detect, .embeddings, .cluster, .tag,
                        .reflect, .compress, .curate, .rem, .clarify, .shy])
    }

    func test_reflect_per_cluster_uses_derivesFrom_to_members() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        func mk(_ id: String, _ kind: String) -> Node {
            Node(id: id, kind: kind, label: id, body: id, layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                 salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                 origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        for id in ["sushi", "ramen", "tempura"] { try store.upsert(mk(id, NodeKind.preference.rawValue)) }
        var anchor = mk("cl", NodeKind.cluster.rawValue); anchor.label = "comida"; try store.upsert(anchor)
        for m in ["sushi", "ramen", "tempura"] {
            try store.upsert(Edge(id: UUID().uuidString, srcId: "cl", dstId: m, relation: .belongsToCluster,
                                  weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
        }
        let json = #"{"insights":[{"text":"enjoys Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([json]))
        await engine.reflect()
        let insights = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
        XCTAssertEqual(insights.count, 1)
        let ins = try XCTUnwrap(insights.first)
        XCTAssertEqual(ins.layer, .daily)                                  // only 3 members → not promoted (Task 2)
        let prov = try store.edges(from: ins.id).filter { $0.relation == .derivesFrom }
        XCTAssertEqual(Set(prov.map { $0.dstId }), ["sushi", "ramen"])     // derivesFrom the 2 cited sources
        XCTAssertTrue(try store.edges(from: ins.id).allSatisfy { $0.relation != .relatedTo })  // no relatedTo
    }
}

/// Test embedder: strings in `near` map to the SAME vector as their target (cosine distance 0 →
/// collapse). Other strings get a deterministic collision-free one-hot vector via a counter.
final class SynonymStubEmbedder: Embedder, @unchecked Sendable {
    let near: [String: String]
    let dim: Int
    private var registry: [String: Int] = [:]
    private var nextSlot: Int = 0
    init(near: [String: String], dim: Int) { self.near = near; self.dim = dim }
    public var dimension: Int { dim }
    func embed(_ text: String) throws -> [Float] {
        let key = near[text] ?? text
        // Assign a unique slot to each unique key (first time seen)
        let slot: Int
        if let existing = registry[key] {
            slot = existing
        } else {
            slot = nextSlot % dim
            registry[key] = slot
            nextSlot += 1
        }
        var v = [Float](repeating: 0, count: dim)
        v[slot] = 1
        return v
    }
}
