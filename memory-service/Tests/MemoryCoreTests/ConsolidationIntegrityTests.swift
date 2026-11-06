import XCTest
import Foundation
import GRDB
@testable import MemoryCore

/// A runtime whose generation always fails. Models a dead endpoint, an auth error or a timeout.
final class FailingRuntime: ModelTextClient, @unchecked Sendable {
    struct Boom: Error {}
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        lock.withLock { _calls += 1 }
        throw Boom()
    }
}

/// A runtime that answers with prose instead of JSON — the single most common real failure of a
/// small local model. Nothing can be parsed out of it.
final class UnparsableRuntime: ModelTextClient, @unchecked Sendable {
    func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        "I'm sorry, I can't help with that."
    }
}

/// Records every prompt it is asked to generate, then replies with queued canned responses.
final class PromptRecordingRuntime: ModelTextClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    private var responses: [String]
    private var i = 0
    init(_ responses: [String] = []) { self.responses = responses }
    var prompts: [String] { lock.withLock { _prompts } }
    func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        lock.withLock {
            _prompts.append(prompt)
            let text = i < responses.count ? responses[i] : "{}"
            i += 1
            return text
        }
    }
}

/// Answers every phase with a well-formed, EMPTY result, picked from the schema the prompt asks
/// for; `overrides` supply real content for one phase. Cycle tests then do not have to predict how
/// many times each phase will be generated for — which is exactly what segment-sized generation
/// makes variable.
final class SchemaAwareRuntime: ModelTextClient, @unchecked Sendable {
    private let overrides: [String: String]
    init(_ overrides: [String: String] = [:]) { self.overrides = overrides }

    func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        let marker: String
        if prompt.contains("\"entities\"") { marker = "entities" }
        else if prompt.contains("\"topic\"") { marker = "summary" }
        else if prompt.contains("\"followUps\"") { marker = "followUps" }
        else if prompt.contains("\"edges\"") { marker = "edges" }
        else if prompt.contains("\"insights\"") { marker = "insights" }
        else if prompt.contains("\"tags\"") { marker = "tags" }
        else if prompt.contains("\"questions\"") { marker = "questions" }
        else if prompt.contains("\"map\"") { marker = "map" }
        else { marker = "unknown" }
        if let override = overrides[marker] { return override }
        switch marker {
        case "entities": return #"{"entities":[]}"#
        case "summary": return #"{"topic":"tema","concepts":[],"summary":"resumen"}"#
        case "followUps": return #"{"followUps":[],"resolvedTexts":[]}"#
        case "edges": return #"{"edges":[]}"#
        case "insights": return #"{"insights":[],"implicitTasks":[],"companions":[]}"#
        case "tags": return #"{"tags":[]}"#
        case "questions": return #"{"questions":[]}"#
        case "map": return #"{"map":{}}"#
        default: return "{}"
        }
    }
}

/// Integrity of consolidation completion: a phase that could not do its work must never let the
/// inputs it consumed be marked consolidated, and a replayed phase must converge instead of
/// duplicating. These are the honesty guarantees of Task 6.
final class ConsolidationIntegrityTests: XCTestCase {

    private func makeStore(dim: Int = 4) throws -> MemoryStore {
        try MemoryStore(inMemory: true, embeddingDim: dim)
    }

    private func node(_ id: String, _ kind: String, _ label: String, _ body: String? = nil,
                      at t: Double = 1_000) -> Node {
        Node(id: id, kind: kind, label: label, body: body ?? label, layer: .daily, createdAt: t,
             updatedAt: t, lastSeenAt: t, salience: 3, decayRate: 0.001, confidence: .sure,
             mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
             dirty: true, deleted: false, extra: nil)
    }

    // MARK: Gate 1 — generation / JSON / write failure must not mark inputs consolidated

    func test_generationFailure_doesNotMarkInputsConsolidated() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me gusta el sushi", now: 1_000)
        let runtime = FailingRuntime()
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime,
                                               transcriptStore: ts, now: { 2_000 })
        await engine.runCycle(isCancelled: { false })
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 1,
                       "a cycle whose generation failed must leave the turn un-consolidated")
        XCTAssertGreaterThan(runtime.calls, 0, "the cycle really did try to generate")
    }

    func test_unparsableOutput_doesNotMarkInputsConsolidated() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me gusta el sushi", now: 1_000)
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: UnparsableRuntime(),
                                               transcriptStore: ts, now: { 2_000 })
        await engine.runCycle(isCancelled: { false })
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 1,
                       "unparsable model output is a phase failure, not an empty success")
    }

    func test_persistFailure_doesNotMarkInputsConsolidated() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me gusta el sushi", now: 1_000)
        // Inject a real storage failure at the SQLite layer: inserting a `preference` node aborts.
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER injected_node_failure BEFORE INSERT ON node
                WHEN NEW.kind = 'preference'
                BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END;
                """)
        }
        let runtime = CannedRuntime([
            #"{"entities":[{"entity":"sushi","kind":"preference","detail":"le gusta"}]}"#,
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime,
                                               transcriptStore: ts, now: { 2_000 })
        await engine.runCycle(isCancelled: { false })
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 1,
                       "a write that failed must not count as consolidated content")
    }

    func test_emptyButWellFormedResult_isSuccessAndMarksConsolidated() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "hola", now: 1_000)
        // Every phase answers correctly that there is nothing to extract.
        let runtime = CannedRuntime([
            #"{"entities":[]}"#, #"{"topic":"saludo","concepts":[]}"#, #"{"followUps":[],"resolvedTexts":[]}"#,
            #"{"tags":[]}"#, #"{"insights":[]}"#, #"{"edges":[]}"#, #"{"questions":[]}"#, #"{"map":{}}"#,
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime,
                                               transcriptStore: ts, now: { 2_000 })
        await engine.runCycle(isCancelled: { false })
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 0,
                       "a phase that ran correctly and found nothing is empty, not failed")
    }

    // MARK: Gate 5 — newer segments of an already-summarized thread are included

    func test_summarizeRecent_includesNewerSegmentOfSummarizedThread() async throws {
        let store = try makeStore(dim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "quiero ir a Japón", now: 1_000)
        let runtime = CannedRuntime([
            #"{"topic":"viaje a Japón","concepts":["Japón"],"summary":"Quiere viajar a Japón."}"#,
            #"{"topic":"viaje a Asia","concepts":["Japón","Corea"],"summary":"Quiere viajar a Japón y Corea."}"#,
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime,
                                               transcriptStore: ts, now: { 2_000 })
        await engine.summarizeRecent()
        try ts.append(threadId: "T", turnIndex: 1, role: "user", text: "y también a Corea", now: 1_100)
        await engine.summarizeRecent()
        let summaries = try store.allNodes().filter { $0.kind == NodeKind.summary.rawValue }
        let covered = summaries.compactMap { n -> Int? in
            guard let data = n.extra?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let range = obj["turnRange"] as? [Int], range.count == 2 else { return nil }
            return range[1]
        }
        XCTAssertEqual(covered.max(), 2,
                       "a thread that already had a summary must still get its newer turns summarized")
    }

    // MARK: Gate 6 — canonical merged ids and derivesFrom direction

    func test_reflectTopics_provenanceUsesCanonicalIdAndInsightToSourceDirection() async throws {
        let store = try makeStore()
        try store.upsert(node("topic-1", NodeKind.plan.rawValue, "viaje a Cuba"))
        // An insight with the same text already exists: the new one must MERGE into it, and the
        // provenance edge must reference the surviving canonical id.
        try store.upsert(node("ins-old", NodeKind.insight.rawValue, "prefiere viajar en verano"))
        let runtime = CannedRuntime([
            #"{"insights":[{"text":"prefiere viajar en verano","sourceEntities":["viaje a Cuba"]}],"implicitTasks":[],"companions":[]}"#,
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, now: { 2_000 })
        await engine.reflectTopics()
        let insights = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
        XCTAssertEqual(insights.map { $0.id }, ["ins-old"], "the duplicate insight merged into the canonical node")
        let live = Set(try store.allNodes().map { $0.id })
        let provenance = try store.allEdges().filter { $0.relation == .derivesFrom }
        XCTAssertFalse(provenance.isEmpty, "the insight keeps a provenance edge")
        for edge in provenance {
            XCTAssertTrue(live.contains(edge.srcId) && live.contains(edge.dstId),
                          "provenance must reference live canonical ids, never a pre-merge id")
            XCTAssertEqual(edge.srcId, "ins-old", "derivesFrom points FROM the insight")
            XCTAssertEqual(edge.dstId, "topic-1", "derivesFrom points TO its source")
        }
    }

    func test_reflect_provenanceUsesCanonicalIdAfterSemanticMerge() async throws {
        // Dimension > 16 so reflect takes the semantic-merge path (its own guard).
        let store = try makeStore(dim: 32)
        let embedder = FakeEmbedder(dimension: 32)
        for (id, label) in [("a", "sushi"), ("b", "ramen"), ("c", "tempura")] {
            try store.upsert(node(id, NodeKind.preference.rawValue, label))
        }
        try store.upsert(node("cl", NodeKind.cluster.rawValue, "japanese"))
        for m in ["a", "b", "c"] {
            try store.upsert(Edge(id: UUID().uuidString, srcId: "cl", dstId: m, relation: .belongsToCluster,
                                  weight: 1, confidence: .probable, createdAt: 1_000, updatedAt: 1_000,
                                  dirty: true, deleted: false, extra: nil))
        }
        // An older insight with a DIFFERENT body but the same vector as the new one: reflect's text
        // dedup will not catch it, so the semantic merge path runs and returns the canonical id.
        try store.upsert(node("ins-old", NodeKind.insight.rawValue, "likes Japanese food"))
        try store.setEmbedding(nodeId: "ins-old", try embedder.embed("enjoys Japanese food"))
        let runtime = CannedRuntime([
            #"{"insights":[{"text":"enjoys Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"}]}"#,
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: embedder, runtime: runtime, now: { 2_000 })
        await engine.reflect()
        let live = Set(try store.allNodes().map { $0.id })
        let provenance = try store.allEdges().filter { $0.relation == .derivesFrom }
        XCTAssertFalse(provenance.isEmpty, "a grounded insight keeps provenance even when merged")
        for edge in provenance {
            XCTAssertTrue(live.contains(edge.srcId), "provenance source is the live canonical insight")
            XCTAssertTrue(live.contains(edge.dstId), "provenance target is a live member node")
        }
        XCTAssertEqual(Set(provenance.map { $0.srcId }), ["ins-old"])
        XCTAssertEqual(Set(provenance.map { $0.dstId }), ["a", "b"])
    }

    // MARK: Relative dates resolve from the source row, not the consolidation wall clock

    func test_relativeDatesResolveFromSourceRowTimestamp() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        // The turn was spoken on 2023-11-14 (UTC); the cycle only runs on 2027-01-15.
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "mañana voy al dentista",
                      now: 1_699_920_000)
        let runtime = PromptRecordingRuntime([#"{"entities":[]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime,
                                               transcriptStore: ts, now: { 1_800_000_000 })
        await engine.runCycle(isCancelled: { false }, timeZone: TimeZone(identifier: "UTC")!)
        let first = try XCTUnwrap(runtime.prompts.first)
        XCTAssertTrue(first.contains("2023-11-14"),
                      "the extraction prompt must anchor on the source turn's own date")
        XCTAssertFalse(first.contains("2027-01-15"),
                       "a cycle running months later must not date the user's 'tomorrow' from its own clock")
    }

    // MARK: kind:self is bound to the user actually asserting it

    func test_selfIdentity_requiresUserAssertionInSource() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user",
                      text: "mi esposa dice que soy terco", now: 1_000)
        let runtime = CannedRuntime([
            #"{"entities":[{"entity":"terco","kind":"self","detail":"el usuario es terco"}]}"#,
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime,
                                               transcriptStore: ts, now: { 2_000 })
        await engine.runCycle(isCancelled: { false })
        XCTAssertNil(try store.selfNode(),
                     "a third party's description of the user is not the user asserting their identity")
    }

    func test_selfIdentity_acceptedWhenUserAssertsIt() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me llamo Roilan", now: 1_000)
        let runtime = CannedRuntime([
            #"{"entities":[{"entity":"Roilan","kind":"self","detail":"el usuario"}]}"#,
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime,
                                               transcriptStore: ts, now: { 2_000 })
        await engine.runCycle(isCancelled: { false })
        XCTAssertEqual(try store.selfNode()?.label, "Roilan")
    }
}

// MARK: - Replay, receipts and evidence

extension ConsolidationIntegrityTests {

    private func store(dim: Int = 4) throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: dim) }

    private func evidenceCount(_ store: MemoryStore) throws -> Int {
        try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_evidence") ?? 0 }
    }

    // MARK: Gate 2 — a retry neither duplicates nor reinforces what already landed

    func test_retryAfterPartialFailure_doesNotDuplicateOrReinforce() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user",
                      text: "trabajo en Habana y me gusta el sushi", now: 1_000)
        let entities = #"{"entities":[{"entity":"Habana","kind":"place","detail":"trabaja ahí"},{"entity":"sushi","kind":"preference","detail":"le gusta"}]}"#
        // The `place` lands; the `preference` write aborts at the storage layer.
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER injected_node_failure BEFORE INSERT ON node
                WHEN NEW.kind = 'preference'
                BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END;
                """)
        }
        let first = MemoryConsolidationEngine(store: store, embedder: nil,
                                              runtime: SchemaAwareRuntime(["entities": entities]),
                                              transcriptStore: ts, now: { 2_000 })
        let firstReport = await first.runCycleReporting(isCancelled: { false })
        XCTAssertEqual(firstReport.result(for: .nrem)?.outcome, .failed)
        XCTAssertFalse(firstReport.inputsConsolidated)
        XCTAssertEqual(try ts.unconsolidated(limit: 10).count, 1)
        let placeAfterFirst = try XCTUnwrap(try store.allNodes().first { $0.kind == "place" })
        XCTAssertEqual(placeAfterFirst.mentionCount, 1)

        // The storage fault clears and the same job is retried.
        try await store.dbQueue.write { db in try db.execute(sql: "DROP TRIGGER injected_node_failure") }
        let second = MemoryConsolidationEngine(store: store, embedder: nil,
                                               runtime: SchemaAwareRuntime(["entities": entities]),
                                               transcriptStore: ts, now: { 3_000 })
        let secondReport = await second.runCycleReporting(isCancelled: { false })
        XCTAssertEqual(secondReport.jobID, firstReport.jobID, "the same inputs are the same job")

        let places = try store.allNodes().filter { $0.kind == "place" }
        XCTAssertEqual(places.count, 1, "the retry must not create a second copy")
        XCTAssertEqual(places.first?.mentionCount, 1,
                       "an item that already landed must not be reinforced again by the retry")
        XCTAssertEqual(try store.allNodes().filter { $0.kind == "preference" }.count, 1,
                       "the item that had failed is written on the retry")
        XCTAssertEqual(try evidenceCount(store), 1,
                       "the turn keeps exactly one evidence record across both attempts")
        XCTAssertEqual(try ts.unconsolidated(limit: 10).count, 0)
    }

    // MARK: Gate 3 — interruption after a phase committed but before its receipt landed

    func test_interruptionAfterCommitBeforeCheckpointConverges() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let rowID = try ts.append(threadId: "T", turnIndex: 0, role: "user",
                                  text: "me gusta el sushi", now: 1_000)
        let entities = #"{"entities":[{"entity":"sushi","kind":"preference","detail":"le gusta"}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                               runtime: SchemaAwareRuntime(["entities": entities]),
                                               transcriptStore: ts, now: { 2_000 })
        let report = await engine.runCycleReporting(isCancelled: { false })
        XCTAssertTrue(report.inputsConsolidated)
        let before = try store.allNodes().count

        // Reproduce the crash window: the phase's writes are on disk, its receipt is not, and the
        // cycle is back at the phase it was running.
        try store.forgetConsolidationReceipt(jobID: report.jobID,
                                             operationID: ConsolidationJob(id: report.jobID, phase: .nrem,
                                                                           transcriptIDs: [rowID], evidenceIDs: [],
                                                                           timeZoneIdentifier: "UTC", startedAt: 0)
                                                 .operationID(for: .nrem))
        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript SET consolidated = 0 WHERE id = ?", arguments: [rowID])
        }
        try store.saveSleepCycle(SleepCycleState(phase: .nrem, episodeIds: [rowID], startedAt: 1_000))

        let recorder = PromptRecordingRuntime([entities])
        let resumed = MemoryConsolidationEngine(store: store, embedder: nil, runtime: recorder,
                                                transcriptStore: ts, now: { 4_000 })
        _ = await resumed.runCycleReporting(isCancelled: { false })
        XCTAssertEqual(recorder.prompts.count, 1,
                       "only the phase whose receipt was lost is re-run; the rest are already recorded")
        XCTAssertEqual(try store.allNodes().count, before, "the replay converges instead of duplicating")
        XCTAssertEqual(try store.allNodes().filter { $0.kind == "preference" }.first?.mentionCount, 1,
                       "a replayed phase does not reinforce what it already committed")
        XCTAssertEqual(try evidenceCount(store), 1)
        XCTAssertEqual(try ts.unconsolidated(limit: 10).count, 0)
    }

    // MARK: completion is one transaction

    func test_completionMarksTurnsAndRetiresCycleTogether() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "hola", now: 1_000)
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: SchemaAwareRuntime(),
                                               transcriptStore: ts, now: { 2_000 })
        let report = await engine.runCycleReporting(isCancelled: { false })
        XCTAssertTrue(report.inputsConsolidated)
        XCTAssertEqual(try ts.unconsolidated(limit: 10).count, 0)
        XCTAssertNil(try store.loadSleepCycle(), "the resume state is retired in the same write")
        let completion = try store.consolidationReceipt(jobID: report.jobID,
                                                        operationID: report.jobID + ":complete")
        XCTAssertEqual(completion?.outcome, .committed, "the job carries a completion receipt")
    }

    func test_failedCycleKeepsBothTurnsAndResumeState() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "hola", now: 1_000)
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: FailingRuntime(),
                                               transcriptStore: ts, now: { 2_000 })
        let report = await engine.runCycleReporting(isCancelled: { false })
        XCTAssertFalse(report.inputsConsolidated)
        XCTAssertEqual(try ts.unconsolidated(limit: 10).count, 1)
        XCTAssertEqual(try store.loadSleepCycle()?.phase, .nrem, "the cycle stays where it broke")
    }

    // MARK: receipts carry the stage and the retryability

    func test_receiptRecordsStageRetryabilityAndAttempts() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "hola", now: 1_000)
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: FailingRuntime(),
                                               transcriptStore: ts, now: { 2_000 })
        let report = await engine.runCycleReporting(isCancelled: { false })
        let operation = report.jobID + ":nrem"
        let first = try XCTUnwrap(try store.consolidationReceipt(jobID: report.jobID, operationID: operation))
        XCTAssertEqual(first.outcome, .failed)
        XCTAssertEqual(first.stage, .generation)
        XCTAssertTrue(first.retryable)
        XCTAssertEqual(first.attempts, 1)
        _ = await engine.runCycleReporting(isCancelled: { false })
        let second = try XCTUnwrap(try store.consolidationReceipt(jobID: report.jobID, operationID: operation))
        XCTAssertEqual(second.attempts, 2, "a retried phase bumps its attempt count, it does not stack receipts")
    }

    func test_jobRecordsTheEvidenceItsTurnsAdaptTo() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me gusta el sushi", now: 1_000)
        try ts.append(threadId: "T", turnIndex: 0, role: "assistant", text: "anotado", now: 1_010)
        // A row the transcript cannot attribute to anyone.
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcript(id, threadId, turnIndex, seq, role, text, createdAt, consolidated)
                VALUES ('tool-1', 'T', 1, 3, 'tool', 'search results', 1020, 0)
                """)
        }
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: SchemaAwareRuntime(),
                                               transcriptStore: ts, now: { 2_000 })
        let report = await engine.runCycleReporting(isCancelled: { false })
        let job = try XCTUnwrap(try store.consolidationJob(id: report.jobID))
        XCTAssertEqual(job.evidenceIDs.count, 2,
                       "only the turns with a recorded speaker become evidence")
        XCTAssertEqual(Set(job.evidenceIDs),
                       [ConsolidationEvidenceAdapter.evidenceID(threadID: "T", seq: 1, text: "me gusta el sushi"),
                        ConsolidationEvidenceAdapter.evidenceID(threadID: "T", seq: 2, text: "anotado")],
                       "evidence ids are derived from the thread, the seq and the text")
        XCTAssertEqual(try evidenceCount(store), 2)
    }

    func test_jobKeepsTheTimeZoneItStartedWith() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        // 2023-11-14 03:00 UTC: still the 13th in Havana, already the 14th in Madrid.
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "mañana voy al dentista",
                      now: 1_699_930_800)
        let failing = MemoryConsolidationEngine(store: store, embedder: nil, runtime: FailingRuntime(),
                                                transcriptStore: ts, now: { 1_800_000_000 })
        _ = await failing.runCycleReporting(isCancelled: { false },
                                            timeZone: TimeZone(identifier: "America/Havana")!)
        let recorder = PromptRecordingRuntime([#"{"entities":[]}"#, #"{"topic":"t","concepts":[]}"#,
                                               #"{"followUps":[]}"#])
        let resumed = MemoryConsolidationEngine(store: store, embedder: nil, runtime: recorder,
                                                transcriptStore: ts, now: { 1_800_000_000 })
        _ = await resumed.runCycleReporting(isCancelled: { false },
                                            timeZone: TimeZone(identifier: "Europe/Madrid")!)
        let prompt = try XCTUnwrap(recorder.prompts.first)
        XCTAssertTrue(prompt.contains("2023-11-13"),
                      "a resumed job keeps the timezone it started in, not the resumer's")
    }

    // MARK: a lawfully refused write is reported, not retried, and does not block completion

    func test_refusedIdentityWriteIsReportedAndCycleStillCompletes() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me llamo Roilan", now: 1_000)
        // The store holds an exclusion marker covering exactly this identity content, so the write
        // is refused on principle (retracted content must not come back).
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO brain_exclusion(kind, id, fingerprint, revision, owner) VALUES (?, ?, ?, 1, 'user')
                """, arguments: [BrainExclusionKind.node.rawValue, selfUserID,
                                 BrainStore.nodeFingerprint(label: "Roilan", body: "el usuario")])
        }
        let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                               runtime: SchemaAwareRuntime(["entities": #"{"entities":[{"entity":"Roilan","kind":"self","detail":"el usuario"}]}"#]),
                                               transcriptStore: ts, now: { 2_000 })
        let report = await engine.runCycleReporting(isCancelled: { false })
        XCTAssertNil(try store.selfNode(), "the refused identity is not written")
        XCTAssertEqual(report.refusals.map { $0.code }, ["self_withheld"],
                       "the refusal is reported with its own code, not swallowed")
        XCTAssertNotEqual(report.result(for: .nrem)?.outcome, .failed,
                          "a lawful refusal is the correct outcome, not a phase failure")
        XCTAssertTrue(report.inputsConsolidated,
                      "a refusal must not keep re-consuming the turn forever")
    }

    // MARK: segment-sized generation and summary coverage

    func test_segmentsSplitPerThreadAndPerCharBudget() {
        func row(_ id: String, _ thread: String, _ seq: Int, _ text: String, _ at: Double) -> TranscriptRow {
            TranscriptRow(id: id, threadId: thread, turnIndex: seq, seq: seq, role: "user",
                          text: text, createdAt: at, consolidated: false)
        }
        let rows = [row("1", "B", 1, String(repeating: "x", count: 10), 10),
                    row("2", "A", 1, String(repeating: "y", count: 6), 1),
                    row("3", "A", 2, String(repeating: "z", count: 6), 2)]
        let segments = ConsolidationSegment.segments(rows, maxChars: 8)
        XCTAssertEqual(segments.map { $0.threadID }, ["A", "A", "B"],
                       "threads in chronological order, split when the budget is exceeded")
        XCTAssertEqual(segments[0].seqRange, 1...1)
        XCTAssertEqual(segments[1].seqRange, 2...2)
        XCTAssertEqual(segments[2].anchorAt, 10)
    }

    func test_summarizedUpToReportsTheHighestCoveredSeqPerThread() async throws {
        let store = try makeStore(dim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "uno", now: 1)
        let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                               runtime: CannedRuntime([#"{"topic":"tema","concepts":[],"summary":"s"}"#]),
                                               transcriptStore: ts, now: { 2 })
        await engine.summarizeRecent()
        XCTAssertEqual(try store.summarizedUpTo(), ["T": 1])
    }

    // MARK: a phase reports which stage broke

    func test_phaseResultCarriesStageAndRetryability() async throws {
        let rows = [TranscriptRow(id: "r1", threadId: "T", turnIndex: 0, seq: 1, role: "user",
                                  text: "hola", createdAt: 1_000, consolidated: false)]
        let segment = ConsolidationSegment(threadID: "T", rows: rows)

        let generationFailed = await MemoryConsolidationEngine(store: try makeStore(), embedder: nil,
                                                               runtime: FailingRuntime(), now: { 2_000 })
            .consolidate(segment: segment)
        XCTAssertEqual(generationFailed.outcome, .failed)
        XCTAssertEqual(generationFailed.failure?.stage, .generation)
        XCTAssertTrue(generationFailed.isRetryable)

        let parseFailed = await MemoryConsolidationEngine(store: try makeStore(), embedder: nil,
                                                          runtime: UnparsableRuntime(), now: { 2_000 })
            .consolidate(segment: segment)
        XCTAssertEqual(parseFailed.failure?.stage, .parse)

        let ranAndFoundNothing = await MemoryConsolidationEngine(store: try makeStore(), embedder: nil,
                                                                 runtime: CannedRuntime([#"{"entities":[]}"#]),
                                                                 now: { 2_000 })
            .consolidate(segment: segment)
        XCTAssertEqual(ranAndFoundNothing.outcome, .empty)
        XCTAssertNil(ranAndFoundNothing.failure, "nothing to extract is a success")
    }
}
