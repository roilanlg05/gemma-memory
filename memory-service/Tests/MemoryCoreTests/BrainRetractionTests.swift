import XCTest
import BrainContract
import GRDB
@testable import MemoryCore

/// Retraction closure tests. Every fixture is synthetic and lives in an in-memory database.
/// The withdrawn sentence is deliberately distinctive so an assertion that it is gone cannot
/// pass by accident, and the surviving sentence shares no tokens with it.
final class BrainRetractionTests: XCTestCase {
    let withdrawn = "I live in Miami with my brother Luis"
    /// A turn of the withdrawn thread that is not itself the withdrawn source.
    let sameThread = "Remind me to renew the parking permit"
    /// Content of another thread, held by a node that must survive every scope under test.
    let surviving = "Cold brew coffee every single morning"

    // MARK: Fixtures

    func authorization(
        mayForget: Bool = true,
        principal: String = "user",
        subjects: Set<String> = ["self:user"],
        threads: Set<String> = ["thread-1"],
        scopes: Set<BrainAccessScope> = [.user]
    ) -> BrainAuthorization {
        BrainAuthorization(
            principal: principal, owner: "user", subjects: subjects, scopes: scopes, threads: threads,
            sourceSpeakers: [.userMessage: ["self:user"], .derived: ["extractor"]],
            mayProject: true, legacyBindings: [], allowDelegated: principal != "user",
            mayCommitClaims: true, mayForget: mayForget)
    }

    func evidence(_ id: String = "e1", text: String? = nil, thread: String = "thread-1") -> BrainEvidence {
        BrainEvidence(id: id, sourceKind: .userMessage, speakerID: "self:user", threadID: thread,
                      observedAt: 10, recordedAt: 11, accessScope: .user, text: text ?? withdrawn)
    }

    func claim(_ id: String = "c1", subject: String = "self:user", predicate: String = "home",
               value: String = "Miami", source: String = "e1") -> BrainClaim {
        BrainClaim(id: id, revision: 0, subject: subject, predicate: predicate, value: .string(value),
                   modality: .asserted, status: .active, validFrom: 10, recordedAt: 11, evidenceIDs: [source])
    }

    func commitRequest(_ op: String, _ claim: BrainClaim, _ revision: Int64,
                       evidence: [BrainEvidence] = []) throws -> BrainCommitRequest {
        try BrainCommitRequest(clientOperationID: op, evidence: evidence,
                               updates: [.init(claim: claim)], expectedRevision: revision)
    }

    func node(_ id: String, kind: NodeKind, label: String, body: String,
              sourceRef: String? = nil, extra: String? = nil) -> Node {
        Node(id: id, kind: kind.rawValue, label: label, body: body, layer: .daily,
             createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 5, decayRate: 0,
             confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: sourceRef,
             origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra)
    }

    func conflictExtra(body: String) -> String {
        #"{"mergeConflicts":[{"label":"Home","body":"\#(body)","origin":"extracted","confidence":"maybe","updatedAt":1}]}"#
    }

    /// One thread of withdrawn source content with every derived artifact the brain builds on
    /// top of it: a source-bound claim and its managed projection, raw transcript turns, a
    /// summary over those turns, an insight derived from that summary, an unlinked legacy node
    /// that reproduces the withdrawn sentence verbatim, a surviving node whose merge conflict
    /// holds the withdrawn sentence, and a wholly unrelated preference.
    @discardableResult
    func seed(_ db: MemoryStore, threads: Set<String> = ["thread-1"]) throws -> BrainRetractionService {
        let brain = BrainStore(store: db, authorization: authorization(threads: threads), clock: { 100 })
        XCTAssertEqual(
            try brain.commit(commitRequest("seed", claim(), 0, evidence: [evidence()])).disposition,
            .committed)

        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        try transcript.append(threadId: "thread-1", turnIndex: 0, role: "user", text: withdrawn, now: 10)
        try transcript.append(threadId: "thread-1", turnIndex: 1, role: "assistant", text: "Noted.", now: 11)
        try transcript.append(threadId: "thread-1", turnIndex: 2, role: "user", text: sameThread, now: 12)
        try transcript.append(threadId: "thread-2", turnIndex: 0, role: "user", text: surviving, now: 13)

        try db.upsert(node("summary-1", kind: .summary, label: "Home city", body: "Where the user lives",
                           sourceRef: "thread-1",
                           extra: #"{"threadId":"thread-1","turnRange":[1,2]}"#))
        try db.setEmbedding(nodeId: "summary-1", [0, 0, 1, 0])

        try db.upsert(node("insight-1", kind: .insight, label: "Warm climates",
                           body: "The user gravitates to warm climates"))
        try db.upsert(Edge(id: "edge-1", srcId: "insight-1", dstId: "summary-1", relation: .derivesFrom,
                           weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1,
                           dirty: true, deleted: false, extra: nil))

        try db.upsert(node("legacy-1", kind: .fact, label: "Home", body: withdrawn))
        try db.setEmbedding(nodeId: "legacy-1", [1, 0, 0, 0])
        try db.setTags(nodeId: "legacy-1", ["home"])

        try db.upsert(node("legacy-2", kind: .fact, label: "Sibling", body: "Has one sibling",
                           extra: conflictExtra(body: withdrawn)))
        try db.upsert(node("unrelated-1", kind: .preference, label: "Coffee", body: surviving,
                           extra: conflictExtra(body: surviving)))
        try db.setEmbedding(nodeId: "unrelated-1", [0, 1, 0, 0])
        try db.setTags(nodeId: "unrelated-1", ["drinks"])

        return BrainRetractionService(brain: brain)
    }

    func texts(_ db: MemoryStore, table: String, column: String) throws -> [String] {
        try db.dbQueue.read { try String.fetchAll($0, sql: "SELECT \(column) FROM \(table)") }
    }

    // MARK: Closure

    func testEvidenceForgetClosesWithdrawnContentAcrossDerivedViews() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)

        let receipt = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                                         expectedRevision: 1, operationID: "forget-1")
        XCTAssertEqual(receipt.state, .committed)
        XCTAssertEqual(receipt.revision, 2)
        XCTAssertEqual(receipt.forgottenEvidenceIDs, ["e1"])
        XCTAssertEqual(receipt.forgottenClaimIDs, ["c1"])
        XCTAssertEqual(receipt.sourceEvidenceIDs, ["e1"])

        // The claim, its managed projection and every derived legacy artifact are gone.
        XCTAssertNil(try db.node(id: "brain-claim:c1"))
        XCTAssertNil(try db.node(id: "legacy-1"))
        XCTAssertNil(try db.node(id: "summary-1"))
        XCTAssertNil(try db.node(id: "insight-1"))
        XCTAssertNil(try db.dbQueue.read { try Edge.fetchOne($0, key: "edge-1") })

        // Nothing exposes the withdrawn sentence any more.
        XCTAssertTrue(try db.searchFTS(query: "Miami", limit: 20).isEmpty)
        XCTAssertFalse(try db.nearest(to: [1, 0, 0, 0], k: 20).contains { $0.id == "legacy-1" })
        XCTAssertFalse(try db.nearest(to: [0, 0, 1, 0], k: 20).contains { $0.id == "summary-1" })
        XCTAssertFalse(try db.loadGraph().nodes.contains { $0.body.contains("Miami") })
        XCTAssertFalse(try db.allNodes().contains { $0.body.contains("Miami") || $0.label.contains("Miami") })
        XCTAssertFalse(MemoryRetriever(store: db, embedder: nil)
            .injectionBlock(for: try db.allNodes()).contains("Miami"))
        XCTAssertEqual(try db.tagsFor(nodeId: "legacy-1"), [])
        XCTAssertFalse(try db.distinctTags().contains("home"))

        // The surviving node keeps its own merge conflict; the withdrawn alternative is stripped.
        let kept = try XCTUnwrap(db.node(id: "legacy-2"))
        XCTAssertTrue(MemoryStore.mergeConflicts(in: kept).isEmpty)
        let unrelated = try XCTUnwrap(db.node(id: "unrelated-1"))
        XCTAssertEqual(MemoryStore.mergeConflicts(in: unrelated).map(\.body), [surviving])

        // Raw transcript: only the withdrawn turn of that thread goes.
        let thread = try TranscriptStore(dbQueue: db.dbQueue).range(threadId: "thread-1", from: 1, to: 80)
        XCTAssertEqual(thread.map(\.text), ["Noted.", sameThread])
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue)
            .range(threadId: "thread-2", from: 1, to: 80).map(\.text), [surviving])

        // Unrelated records remain reachable through every view.
        XCTAssertTrue(try db.searchFTS(query: "coffee", limit: 20).contains { $0.id == "unrelated-1" })
        XCTAssertTrue(try db.nearest(to: [0, 1, 0, 0], k: 20).contains { $0.id == "unrelated-1" })
        XCTAssertEqual(try db.nodesWithTag("drinks"), ["unrelated-1"])
    }

    func testForgetScrubsEvidenceAndCommitJournals() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        let brain = BrainStore(store: db, authorization: authorization(), clock: { 100 })
        _ = try brain.recordEvidence(evidence("e-journal", text: withdrawn), idempotencyKey: "journal-key")

        _ = try service.forget(scope: BrainForgetScope(kind: .thread, id: "thread-1"),
                               expectedRevision: 1, operationID: "forget-journals")

        for (table, column) in [("brain_evidence", "payload"), ("brain_evidence_operations", "payload"),
                                ("brain_claim", "payload"), ("brain_commit", "payload"),
                                ("brain_commit", "result")] {
            for value in try texts(db, table: table, column: column) {
                XCTAssertFalse(value.contains("Miami"), "\(table).\(column) still holds withdrawn content")
            }
        }
        XCTAssertTrue(try texts(db, table: "brain_evidence", column: "id").isEmpty)
        XCTAssertTrue(try texts(db, table: "brain_claim", column: "id").isEmpty)
        XCTAssertFalse(try texts(db, table: "sleep_cycle", column: "focus").contains { $0.contains("Miami") })
    }

    func testThreadForgetRemovesEveryTurnAndSummaryOfThatThread() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        try db.upsert(node("quoted-1", kind: .task, label: "Permit", body: sameThread))

        _ = try service.forget(scope: BrainForgetScope(kind: .thread, id: "thread-1"),
                               expectedRevision: 1, operationID: "forget-thread")

        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        XCTAssertTrue(try transcript.range(threadId: "thread-1", from: 1, to: 80).isEmpty)
        XCTAssertEqual(try transcript.range(threadId: "thread-2", from: 1, to: 80).map(\.text), [surviving])
        XCTAssertNil(try db.node(id: "summary-1"))
        XCTAssertNil(try db.node(id: "quoted-1"),
                     "a derived node quoting a withdrawn turn verbatim goes with the thread")
        XCTAssertNotNil(try db.node(id: "unrelated-1"))
    }

    // MARK: Idempotency, conflict, authorization

    func testForgetIsIdempotentAndRejectsScopeMismatch() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        let scope = BrainForgetScope(kind: .evidence, id: "e1")

        let first = try service.forget(scope: scope, expectedRevision: 1, operationID: "op")
        let replay = try service.forget(scope: scope, expectedRevision: 1, operationID: "op")
        XCTAssertEqual(first, replay)
        let stillReplay = try service.forget(scope: scope, expectedRevision: 99, operationID: "op")
        XCTAssertEqual(first, stillReplay)
        XCTAssertEqual(try BrainStore(store: db, authorization: authorization()).revision(), 2)

        XCTAssertThrowsError(try service.forget(scope: BrainForgetScope(kind: .thread, id: "thread-1"),
                                                expectedRevision: 2, operationID: "op")) {
            XCTAssertEqual($0 as? BrainStoreError, .conflict)
        }
    }

    func testStaleRevisionConflictsAndErasesNothing() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)

        XCTAssertThrowsError(try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                                                expectedRevision: 0, operationID: "stale")) {
            XCTAssertEqual($0 as? BrainStoreError, .conflict)
        }
        XCTAssertEqual(try BrainStore(store: db, authorization: authorization()).revision(), 1)
        XCTAssertNotNil(try db.node(id: "legacy-1"))
        XCTAssertTrue(try db.searchFTS(query: "Miami", limit: 20).contains { $0.id == "brain-claim:c1" })
        XCTAssertFalse(try texts(db, table: "brain_evidence", column: "id").isEmpty)
    }

    func testForgetRequiresExplicitCapabilityAndTargetAuthorization() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        try seed(db)
        func service(_ auth: BrainAuthorization) -> BrainRetractionService {
            BrainRetractionService(brain: BrainStore(store: db, authorization: auth, clock: { 100 }))
        }
        func assertDenied(_ body: @autoclosure () throws -> BrainForgetReceipt) {
            XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
        }
        // A read grant, mayProject and mayCommitClaims never escalate into erasure.
        assertDenied(try service(authorization(mayForget: false))
            .forget(scope: BrainForgetScope(kind: .evidence, id: "e1"), expectedRevision: 1, operationID: "a"))
        // Erasure of a thread, subject or evidence the principal does not hold.
        assertDenied(try service(authorization(threads: ["thread-9"]))
            .forget(scope: BrainForgetScope(kind: .thread, id: "thread-1"), expectedRevision: 1, operationID: "b"))
        assertDenied(try service(authorization())
            .forget(scope: BrainForgetScope(kind: .subject, id: "self:agent"), expectedRevision: 1, operationID: "c"))
        assertDenied(try service(authorization(threads: ["thread-9"]))
            .forget(scope: BrainForgetScope(kind: .evidence, id: "e1"), expectedRevision: 1, operationID: "d"))
        // `all` is owner-only: a delegated principal cannot purge the whole store.
        assertDenied(try service(authorization(principal: "delegate"))
            .forget(scope: BrainForgetScope(kind: .all), expectedRevision: 1, operationID: "e"))
        // A scope without the user grant cannot erase at all.
        assertDenied(try service(authorization(scopes: [.thread]))
            .forget(scope: BrainForgetScope(kind: .evidence, id: "e1"), expectedRevision: 1, operationID: "f"))

        func assertInvalid(_ body: @autoclosure () throws -> BrainForgetReceipt) {
            XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? BrainStoreError, .invalid) }
        }
        assertInvalid(try service(authorization())
            .forget(scope: BrainForgetScope(kind: .evidence, id: "  "), expectedRevision: 1, operationID: "g"))
        assertInvalid(try service(authorization())
            .forget(scope: BrainForgetScope(kind: .all, id: "thread-1"), expectedRevision: 1, operationID: "h"))
        assertInvalid(try service(authorization())
            .forget(scope: BrainForgetScope(kind: .thread, id: "thread-1"), expectedRevision: -1, operationID: "i"))
        assertInvalid(try service(authorization())
            .forget(scope: BrainForgetScope(kind: .thread, id: "thread-1"), expectedRevision: 1, operationID: " "))
        assertInvalid(try service(authorization())
            .forget(scope: BrainForgetScope(kind: .evidence, id: "missing"), expectedRevision: 1, operationID: "j"))

        XCTAssertNotNil(try db.node(id: "legacy-1"))
        XCTAssertEqual(try BrainStore(store: db, authorization: authorization()).revision(), 1)
    }

    // MARK: Reingestion and restoration

    func testReconsolidationAndStaleUpsertCannotRecreateForgottenContent() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        _ = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                               expectedRevision: 1, operationID: "forget")

        // A stale client pushing the forgotten node back is refused, not silently accepted.
        XCTAssertThrowsError(try db.upsert(node("legacy-1", kind: .fact, label: "Home", body: withdrawn))) {
            XCTAssertEqual($0 as? BrainStoreError, .denied)
        }
        XCTAssertNil(try db.node(id: "legacy-1"))

        // Reconciliation has nothing left to publish and must not revive the projection.
        let brain = BrainStore(store: db, authorization: authorization(), clock: { 200 })
        try brain.reconcileProjections(now: 200)
        XCTAssertNil(try db.node(id: "brain-claim:c1"))
        XCTAssertTrue(try brain.claims(subject: "self:user", asOf: 200, scope: .user).isEmpty)

        // Re-recording the same evidence id cannot resurrect it either.
        XCTAssertThrowsError(try brain.recordEvidence(evidence(), idempotencyKey: "again")) {
            XCTAssertEqual($0 as? BrainStoreError, .denied)
        }
    }

    func testApplyExclusionsScrubsRestoredRowsBeforeReads() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        // Captured before the purge so the restore replays the row byte for byte, as a backup would.
        let evidencePayload = try XCTUnwrap(db.dbQueue.read {
            try String.fetchOne($0, sql: "SELECT payload FROM brain_evidence WHERE id='e1'")
        })
        let receipt = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                                         expectedRevision: 1, operationID: "forget")

        // A restore from a stale backup puts the withdrawn rows back behind the store's API.
        try db.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO node (id, kind, label, body, layer, createdAt, updatedAt, lastSeenAt, salience,
                                  decayRate, confidence, mentionCount, ttlExpiresAt, sourceRef, origin,
                                  serverId, dirty, deleted, extra)
                VALUES ('legacy-1', 'fact', 'Home', ?, 'daily', 1, 1, 1, 5, 0, 'probable', 1,
                        NULL, NULL, 'extracted', NULL, 1, 0, NULL)
                """, arguments: [withdrawn])
            try db.execute(sql: "INSERT INTO node_fts(node_id, label, body) VALUES ('legacy-1', 'Home', ?)",
                           arguments: [withdrawn])
            try db.execute(sql: "INSERT INTO brain_evidence(id, payload) VALUES ('e1', ?)",
                           arguments: [evidencePayload])
        }
        XCTAssertFalse(try db.searchFTS(query: "Miami", limit: 20).isEmpty, "precondition: the restore re-exposed it")

        try service.applyExclusions([receipt])
        XCTAssertNil(try db.node(id: "legacy-1"))
        XCTAssertTrue(try db.searchFTS(query: "Miami", limit: 20).isEmpty)
        XCTAssertTrue(try texts(db, table: "brain_evidence", column: "id").isEmpty)
        // Idempotent, and it never claims a new revision for work it did not decide.
        try service.applyExclusions([receipt])
        XCTAssertEqual(try BrainStore(store: db, authorization: authorization()).revision(), 2)
        XCTAssertNotNil(try db.node(id: "unrelated-1"))
    }

    // MARK: Scope discipline

    func testSubjectScopeKeepsEvidenceSupportingAnotherSubject() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let auth = authorization(subjects: ["self:user", "self:agent"])
        let brain = BrainStore(store: db, authorization: auth, clock: { 100 })
        XCTAssertEqual(try brain.commit(commitRequest("one", claim(), 0, evidence: [evidence()])).disposition,
                       .committed)
        XCTAssertEqual(try brain.commit(commitRequest("two", claim("c2", subject: "self:agent",
                                                                  predicate: "tone", value: "warm"), 1)).disposition,
                       .committed)
        let service = BrainRetractionService(brain: brain)

        _ = try service.forget(scope: BrainForgetScope(kind: .subject, id: "self:user"),
                               expectedRevision: 2, operationID: "forget-subject")
        XCTAssertTrue(try brain.claims(subject: "self:user", asOf: 100, scope: .user).isEmpty)
        XCTAssertEqual(try brain.claims(subject: "self:agent", asOf: 100, scope: .user).map(\.id), ["c2"])
        XCTAssertFalse(try texts(db, table: "brain_evidence", column: "id").isEmpty,
                       "shared evidence still supports another subject's claim")

        _ = try service.forget(scope: BrainForgetScope(kind: .subject, id: "self:agent"),
                               expectedRevision: 3, operationID: "forget-agent")
        XCTAssertTrue(try texts(db, table: "brain_evidence", column: "id").isEmpty,
                      "the last dependent claim is gone, so the source is orphaned and purged")
    }

    func testForgetAllPurgesPersonalMemoryButNotConnectionCredentials() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        let crypto = ConfigCrypto(bearerToken: "token")
        let connections = ConnectionServicesStore(dbQueue: db.dbQueue, crypto: crypto)
        try connections.save(id: "amazon-atoz", payloadJSON: #"{"cookie":"session-123"}"#, updatedAt: 5)
        let models = ModelConfigStore(dbQueue: db.dbQueue, crypto: crypto)
        try models.save(provider: "local", baseURL: "http://localhost", model: "gemma", apiKey: "k")

        let receipt = try service.forget(scope: BrainForgetScope(kind: .all),
                                         expectedRevision: 1, operationID: "forget-all")
        XCTAssertEqual(receipt.state, .committed)
        XCTAssertTrue(try db.allNodes(includeDeleted: true, includeHubs: true).isEmpty)
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 0)
        XCTAssertTrue(try texts(db, table: "brain_evidence", column: "id").isEmpty)
        XCTAssertTrue(try texts(db, table: "brain_claim", column: "id").isEmpty)
        XCTAssertTrue(try texts(db, table: "brain_projection", column: "node_id").isEmpty)

        // Credentials and configuration are not personal-memory artifacts.
        XCTAssertEqual(try connections.load(id: "amazon-atoz")?.payloadJSON, #"{"cookie":"session-123"}"#)
        XCTAssertEqual(try models.load()?.model, "gemma")
    }

    // MARK: The store stays usable after a retraction

    func testStoreStaysWritableAfterForgetAll() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        try db.upsertSelf(name: "Roilan", detail: "the user", now: 50)
        try db.ensureKindHubs(now: 50)

        _ = try service.forget(scope: BrainForgetScope(kind: .all),
                               expectedRevision: 1, operationID: "forget-all")
        XCTAssertNil(try db.selfNode())

        // The singleton identity and the kind hubs use deterministic ids the brain reuses by
        // design, so "forget everything" must not brick their write paths.
        XCTAssertNoThrow(try db.upsertSelf(name: "Roilan", detail: "the user", now: 60))
        XCTAssertNotNil(try db.selfNode())
        XCTAssertGreaterThan(try db.ensureKindHubs(now: 60), 0)
        XCTAssertNoThrow(try db.upsert(node("fresh", kind: .fact, label: "Fresh", body: "A new fact")))
    }

    func testCorrectedEvidenceMayReuseTheWithdrawnIdentifier() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        _ = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                               expectedRevision: 1, operationID: "forget")
        let brain = BrainStore(store: db, authorization: authorization(), clock: { 100 })

        // Replaying the withdrawn record byte for byte is reingestion.
        XCTAssertThrowsError(try brain.recordEvidence(evidence(), idempotencyKey: "replay")) {
            XCTAssertEqual($0 as? BrainStoreError, .denied)
        }
        // Correcting it under the same id is a different record, which the brief names explicitly.
        let corrected = evidence("e1", text: "Correction: I now live in Havana with Ana")
        XCTAssertEqual(try brain.recordEvidence(corrected, idempotencyKey: "corrected"), corrected)
    }

    // MARK: Unreadable source rows

    func testUndecodableClaimPayloadIsSweptByContent() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        try db.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO brain_claim(id, subject, predicate, revision, payload) VALUES ('opaque', 'self:user', 'home', 1, ?)",
                           arguments: [#"{"schemaVersion":99,"legacy":"\#(withdrawn)"}"#])
        }

        _ = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                               expectedRevision: 1, operationID: "forget")
        for payload in try texts(db, table: "brain_claim", column: "payload") {
            XCTAssertFalse(payload.contains("Miami"), "an unreadable claim payload still holds the value verbatim")
        }
        XCTAssertTrue(try texts(db, table: "brain_claim", column: "id").isEmpty)
    }

    func testUnreadableClaimPayloadStandsDownTheOrphanRule() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let auth = authorization(subjects: ["self:user", "self:agent"])
        let brain = BrainStore(store: db, authorization: auth, clock: { 100 })
        XCTAssertEqual(try brain.commit(commitRequest("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        XCTAssertEqual(try brain.commit(commitRequest("two", claim("c2", subject: "self:agent",
                                                                  predicate: "tone", value: "warm"), 1)).disposition, .committed)
        try db.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO brain_claim(id, subject, predicate, revision, payload) VALUES ('opaque', 'self:user', 'mood', 1, ?)",
                           arguments: [#"{"schemaVersion":99,"legacy":"nothing withdrawn here"}"#])
        }
        let service = BrainRetractionService(brain: brain)

        _ = try service.forget(scope: BrainForgetScope(kind: .subject, id: "self:user"),
                               expectedRevision: 2, operationID: "a")
        _ = try service.forget(scope: BrainForgetScope(kind: .subject, id: "self:agent"),
                               expectedRevision: 3, operationID: "b")
        // With a claim whose support set cannot be read, no source can be proven orphaned, so the
        // rule stands down rather than erasing evidence that claim may still need.
        XCTAssertEqual(try texts(db, table: "brain_evidence", column: "id"), ["e1"])
    }

    // MARK: Bounds of the cascade

    /// A withdrawn source body repeated verbatim in another thread is the same content, and
    /// leaving it would let `/v1/transcript/range` serve it and a later consolidation pass mint a
    /// fresh node from it.
    func testProvenanceLinkedTurnsFollowTheSourceAcrossThreads() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db, threads: ["thread-1", "thread-2"])
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        try transcript.append(threadId: "thread-2", turnIndex: 1, role: "user", text: withdrawn, now: 14)

        _ = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                               expectedRevision: 1, operationID: "forget")
        XCTAssertFalse(try transcript.allRecent(limit: 50).contains { $0.text.contains("Miami") })
        XCTAssertEqual(try transcript.range(threadId: "thread-2", from: 1, to: 80).map(\.text), [surviving])
        XCTAssertNotNil(try db.node(id: "unrelated-1"))
    }

    func testCascadeBeyondTheGrantIsDeniedRatherThanPartial() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        try transcript.append(threadId: "thread-2", turnIndex: 1, role: "user", text: withdrawn, now: 14)

        XCTAssertThrowsError(try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                                                expectedRevision: 1, operationID: "forget")) {
            XCTAssertEqual($0 as? BrainStoreError, .denied)
        }
        // Refused, not half-done: the granted thread's turn is still there too.
        XCTAssertEqual(try transcript.allRecent(limit: 50).filter { $0.text.contains("Miami") }.count, 2)
        XCTAssertEqual(try BrainStore(store: db, authorization: authorization()).revision(), 1)
        XCTAssertNotNil(try db.node(id: "legacy-1"))
    }

    func testSubjectScopeWithoutThreadGrantIsDenied() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        try seed(db)
        let threadless = BrainRetractionService(brain: BrainStore(
            store: db, authorization: authorization(threads: []), clock: { 100 }))

        XCTAssertThrowsError(try threadless.forget(scope: BrainForgetScope(kind: .subject, id: "self:user"),
                                                   expectedRevision: 1, operationID: "forget")) {
            XCTAssertEqual($0 as? BrainStoreError, .denied)
        }
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue)
            .range(threadId: "thread-1", from: 1, to: 80).count, 3)
        XCTAssertFalse(try texts(db, table: "brain_evidence", column: "id").isEmpty)
    }

    func testContentBackstopSkipsRowsAttributedOutsideTheGrant() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        try db.upsert(node("foreign", kind: .fact, label: "Home", body: withdrawn, sourceRef: "thread-2"))

        _ = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                               expectedRevision: 1, operationID: "forget")
        // Content similarity alone never reaches a row that declares a thread the principal does
        // not hold; only its own thread's retraction may remove it.
        XCTAssertNotNil(try db.node(id: "foreign"))
        XCTAssertNil(try db.node(id: "legacy-1"), "an unattributed row is still swept")
    }

    func testApplyExclusionsRejectsReceiptsItDidNotIssue() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let service = try seed(db)
        let receipt = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                                         expectedRevision: 1, operationID: "forget")
        func assertDenied(_ forged: BrainForgetReceipt) {
            XCTAssertThrowsError(try service.applyExclusions([forged])) {
                XCTAssertEqual($0 as? BrainStoreError, .denied)
            }
        }
        func rewrite(operation: String, affected: [String]?) -> BrainForgetReceipt {
            BrainForgetReceipt(clientOperationID: operation, scope: receipt.scope, state: receipt.state,
                               revision: receipt.revision, forgottenEvidenceIDs: receipt.forgottenEvidenceIDs,
                               forgottenClaimIDs: receipt.forgottenClaimIDs, affectedIDs: affected,
                               sourceEvidenceIDs: receipt.sourceEvidenceIDs)
        }
        assertDenied(rewrite(operation: "never-issued", affected: receipt.affectedIDs))
        assertDenied(rewrite(operation: "forget", affected: ["unrelated-1"]))
        XCTAssertNotNil(try db.node(id: "unrelated-1"))

        // A row that legitimately reuses a retracted id with new content is not the withdrawn row.
        try db.upsert(node("legacy-1", kind: .fact, label: "Home", body: "Somewhere else entirely"))
        try service.applyExclusions([receipt])
        XCTAssertEqual(try db.node(id: "legacy-1")?.body, "Somewhere else entirely")
    }

    func testSalienceDecayIsNotRetraction() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        var fading = node("fading", kind: .fact, label: "Fading", body: "Low salience detail")
        fading.salience = 0.01
        fading.decayRate = 1
        try db.upsert(fading)
        try db.sweep(now: 10_000)

        // Decay soft-deletes and leaves the row revivable; it records no exclusion marker.
        XCTAssertEqual(try db.node(id: "fading")?.deleted, true)
        XCTAssertTrue(try texts(db, table: "brain_exclusion", column: "id").isEmpty)
        var revived = fading
        revived.deleted = false
        XCTAssertNoThrow(try db.upsert(revived))

        // Retraction is the other mechanism: the row is gone and excluded from reingestion.
        let service = try seed(db)
        _ = try service.forget(scope: BrainForgetScope(kind: .evidence, id: "e1"),
                               expectedRevision: 1, operationID: "forget")
        XCTAssertTrue(try texts(db, table: "brain_exclusion", column: "id").contains("legacy-1"))
        XCTAssertNoThrow(try db.upsert(revived), "decay-eligible records are untouched by retraction")
    }
}
