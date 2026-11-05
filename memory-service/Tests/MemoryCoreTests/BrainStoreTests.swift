import XCTest
import BrainContract
import GRDB
@testable import MemoryCore

final class BrainStoreTests: XCTestCase {
    let auth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"], .derived: ["extractor"]], mayProject: true, mayCommitClaims: true)
    func evidence(_ id: String = "e1", scope: BrainAccessScope = .user, speaker: String = "self:user", thread: String = "thread-1", text: String? = "I like blue") -> BrainEvidence {
        BrainEvidence(id: id, sourceKind: .userMessage, speakerID: speaker, threadID: thread, observedAt: 10, recordedAt: 11, span: nil, accessScope: scope, text: text)
    }
    func claim(_ id: String = "c1", value: String = "blue", time: Double = 10, source: String = "e1", previous: String? = nil) -> BrainClaim {
        BrainClaim(id: id, revision: 0, subject: "self:user", predicate: "color", value: .string(value), modality: .asserted, status: .active, validFrom: time, recordedAt: time + 1, evidenceIDs: [source], supersedesID: previous)
    }
    func request(_ op: String, _ claim: BrainClaim, _ revision: Int64?, evidence: [BrainEvidence] = []) throws -> BrainCommitRequest {
        try BrainCommitRequest(clientOperationID: op, evidence: evidence, updates: [.init(claim: claim)], expectedRevision: revision)
    }
    func testEvidenceReplayAndConflict() throws {
        let store = BrainStore(store: try MemoryStore(inMemory: true, embeddingDim: 4), authorization: auth)
        let e = evidence()
        XCTAssertEqual(try store.recordEvidence(e, idempotencyKey: "key"), e)
        XCTAssertEqual(try store.recordEvidence(e, idempotencyKey: "key"), e)
        XCTAssertThrowsError(try store.recordEvidence(evidence("e2"), idempotencyKey: "key"))
    }
    func testDefaultDenyAndSpoofedSources() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        XCTAssertThrowsError(try BrainStore(store: db).recordEvidence(evidence(), idempotencyKey: "a"))
        let store = BrainStore(store: db, authorization: auth)
        XCTAssertThrowsError(try store.recordEvidence(evidence(speaker: "self:agent"), idempotencyKey: "b"))
        XCTAssertThrowsError(try store.recordEvidence(evidence(scope: .shared), idempotencyKey: "c"))
        XCTAssertThrowsError(try store.recordEvidence(evidence(thread: "other"), idempotencyKey: "d"))
        XCTAssertThrowsError(try store.recordEvidence(evidence(text: nil), idempotencyKey: "e"))
    }
    func testCommitReplayConflictAndMissingRevision() throws {
        let store = BrainStore(store: try MemoryStore(inMemory: true, embeddingDim: 4), authorization: auth)
        let c = claim()
        XCTAssertThrowsError(try store.commit(request("missing", c, nil, evidence: [evidence()])))
        let r = try request("operation", c, 0, evidence: [evidence()])
        XCTAssertEqual(try store.commit(r).disposition, .committed)
        XCTAssertEqual(try store.commit(r).disposition, .idempotent)
        XCTAssertEqual(try store.commit(request("operation", claim(value: "red"), 0)).disposition, .conflict)
        XCTAssertEqual(try store.commit(request("stale", claim("c2"), 0)).disposition, .conflict)
        XCTAssertEqual(try store.revision(), 1)
    }
    func testCorrectionHistoryAndReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = BrainStore(store: try MemoryStore(url: url, embeddingDim: 4), authorization: auth)
            XCTAssertEqual(try store.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
            XCTAssertEqual(try store.commit(request("two", claim("c2", value: "red", time: 20, source: "e2", previous: "c1"), 1, evidence: [evidence("e2", text: "Correction: I like red")])).disposition, .committed)
        }
        let reopened = BrainStore(store: try MemoryStore(url: url, embeddingDim: 4), authorization: auth)
        XCTAssertEqual(try reopened.revision(), 2)
        XCTAssertEqual(try reopened.claims(subject: "self:user", asOf: 15, scope: .user).map(\.id), ["c1"])
        XCTAssertEqual(try reopened.claims(subject: "self:user", asOf: 25, scope: .user).map(\.id), ["c2"])
        XCTAssertEqual(try reopened.claims(subject: "self:user", asOf: 25, scope: .user, knownAtRevision: 1).map(\.id), ["c1"])
        XCTAssertThrowsError(try reopened.claims(subject: "self:agent", asOf: 25, scope: .user))
    }

    func testAtomicRollbackWhenEvidenceDoesNotResolve() throws {
        let store = BrainStore(store: try MemoryStore(inMemory: true, embeddingDim: 4), authorization: auth)
        let bad = try request("rollback", claim(source: "missing"), 0, evidence: [evidence()])
        XCTAssertThrowsError(try store.commit(bad))
        XCTAssertEqual(try store.revision(), 0)
        // If the evidence insertion had escaped the failed transaction, this ID would conflict.
        XCTAssertEqual(try store.recordEvidence(evidence(text: "Changed source"), idempotencyKey: "later").text, "Changed source")
    }
    func testDerivedLineageAndSpanValidation() throws {
        let store = BrainStore(store: try MemoryStore(inMemory: true, embeddingDim: 4), authorization: auth)
        let invalidSpan = BrainEvidence(id: "span", sourceKind: .userMessage, speakerID: "self:user", threadID: "thread-1", observedAt: 1, recordedAt: 1, span: .init(start: 0, end: 100), accessScope: .user, text: "tiny")
        XCTAssertThrowsError(try store.recordEvidence(invalidSpan, idempotencyKey: "span"))
        let forged = BrainEvidence(id: "derived", sourceKind: .derived, speakerID: "extractor", threadID: "thread-1", observedAt: 1, recordedAt: 1, accessScope: .user, text: "summary", parentEvidenceIDs: ["missing"])
        XCTAssertThrowsError(try store.recordEvidence(forged, idempotencyKey: "derived"))
        let cycle = BrainEvidence(id: "cycle", sourceKind: .derived, speakerID: "extractor", threadID: "thread-1", observedAt: 1, recordedAt: 1, accessScope: .user, text: "summary", parentEvidenceIDs: ["cycle"])
        XCTAssertThrowsError(try store.recordEvidence(cycle, idempotencyKey: "cycle"))
    }
    func testLegacyBindingRequiresMatchingTupleAndOwner() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let old = Node(id: "old", kind: "fact", label: "old", body: "unverified old value", layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 1, decayRate: 0, confidence: .maybe, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: #"{"subjectId":"self:user","ownerId":"user"}"#)
        try db.upsert(old)
        try db.setEmbedding(nodeId: old.id, [1, 0, 0, 0])
        func granted(_ binding: BrainLegacyBinding) -> BrainStore {
            BrainStore(store: db, authorization: BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]], mayProject: true, legacyBindings: [binding], mayCommitClaims: true))
        }
        let wrong = granted(.init(claimID: "c1", subject: "self:user", predicate: "name", nodeIDs: ["old"]))
        XCTAssertThrowsError(try wrong.commit(request("wrong", claim(), 0, evidence: [evidence()])))
        XCTAssertEqual(try wrong.revision(), 0)
        let valid = granted(.init(claimID: "c1", subject: "self:user", predicate: "color", nodeIDs: ["old"]))
        XCTAssertEqual(try valid.commit(request("valid", claim(), 0, evidence: [evidence()])).disposition, .committed)
        XCTAssertNotNil(try db.node(id: "old")) // source history is retained
        XCTAssertFalse(try db.allNodes().contains { $0.id == "old" })
        XCTAssertFalse(try db.searchFTS(query: "unverified", limit: 10).contains { $0.id == "old" })
        XCTAssertFalse(try db.nearest(to: [1, 0, 0, 0], k: 10).contains { $0.id == "old" })
        XCTAssertThrowsError(try db.upsert(old))
        var projected = try XCTUnwrap(db.allNodes().first { $0.id == "brain-claim:c1" })
        projected.body = "forged"
        XCTAssertThrowsError(try db.upsert(projected))
        let block = MemoryRetriever(store: db, embedder: nil).injectionBlock(for: try db.allNodes())
        XCTAssertFalse(block.contains("unverified old value"))
    }
    func testUserScopeCanRecallAcrossThreads() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let writer = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try writer.commit(request("op", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let reader = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["other-thread"], sourceSpeakers: [:])
        let brain = BrainStore(store: db, authorization: reader)
        XCTAssertEqual(try brain.claims(subject: "self:user", asOf: 20, scope: .user).map(\.id), ["c1"])
        XCTAssertThrowsError(try brain.commit(request("denied", claim("c2"), 1))) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
    }

    func testDifferentOwnerSameThreadCannotRead() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let writer = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try writer.commit(request("op", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let other = BrainAuthorization(principal: "other", owner: "other", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [:])
        XCTAssertThrowsError(try BrainStore(store: db, authorization: other).claims(subject: "self:user", asOf: 20, scope: .user)) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
    }
    func testThreadScopeDoesNotGrantOtherThread() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let writeAuth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.thread], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]], mayProject: true, mayCommitClaims: true)
        let writer = BrainStore(store: db, authorization: writeAuth)
        XCTAssertEqual(try writer.commit(request("op", claim(), 0, evidence: [evidence(scope: .thread)])).disposition, .committed)
        XCTAssertTrue(try db.allNodes().isEmpty, "thread-private claims must not appear in global legacy nodes")
        let readAuth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.thread], threads: ["thread-2"], sourceSpeakers: [:])
        XCTAssertTrue(try BrainStore(store: db, authorization: readAuth).claims(subject: "self:user", asOf: 20, scope: .thread).isEmpty)
    }
    func testDelegatedReaderNeedsNoProducerGrant() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let writer = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try writer.commit(request("op", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let delegated = BrainAuthorization(principal: "reader", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [:], allowDelegated: true)
        let reader = BrainStore(store: db, authorization: delegated)
        XCTAssertEqual(try reader.claims(subject: "self:user", asOf: 20, scope: .user).map(\.id), ["c1"])
        XCTAssertThrowsError(try reader.commit(request("denied", claim("c2"), 1))) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
        let untrusted = BrainAuthorization(principal: "reader", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [:])
        XCTAssertThrowsError(try BrainStore(store: db, authorization: untrusted).claims(subject: "self:user", asOf: 20, scope: .user)) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
    }
    func testMultipleValuesCoexistAndExplicitCorrectionOnlyReplacesItsTarget() throws {
        let store = BrainStore(store: try MemoryStore(inMemory: true, embeddingDim: 4), authorization: auth)
        XCTAssertEqual(try store.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        XCTAssertEqual(try store.commit(request("two", claim("c2", value: "green", source: "e2"), 1, evidence: [evidence("e2", text: "I like green")])).disposition, .committed)
        XCTAssertEqual(Set(try store.claims(subject: "self:user", asOf: 30, scope: .user).map(\.id)), ["c1", "c2"])
        XCTAssertEqual(try store.commit(request("three", claim("c3", value: "red", time: 20, source: "e3", previous: "c1"), 2, evidence: [evidence("e3", text: "Correction: I like red")])).disposition, .committed)
        XCTAssertEqual(Set(try store.claims(subject: "self:user", asOf: 30, scope: .user).map(\.id)), ["c2", "c3"])
    }

    func testUserCorrectionAndDerivedRootsCanCrossChats() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let first = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try first.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let secondAuth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-2"], sourceSpeakers: [.userMessage: ["self:user"], .derived: ["extractor"]], mayCommitClaims: true)
        let second = BrainStore(store: db, authorization: secondAuth)
        let fresh = evidence("e2", thread: "thread-2", text: "Correction: I like red")
        let summary = BrainEvidence(id: "summary", sourceKind: .derived, speakerID: "extractor", threadID: "thread-2", observedAt: 20, recordedAt: 21, accessScope: .user, text: "Color correction", parentEvidenceIDs: ["e1", "e2"])
        XCTAssertEqual(try second.commit(request("two", claim("c2", value: "red", time: 20, source: "summary", previous: "c1"), 1, evidence: [fresh, summary])).disposition, .committed)
        XCTAssertEqual(try second.claims(subject: "self:user", asOf: 30, scope: .user).map(\.id), ["c2"])
        let roots = try db.dbQueue.read { try second.roots(of: summary, db: $0) }
        XCTAssertEqual(roots, ["e1", "e2"])
        let d1 = BrainEvidence(id: "d1", sourceKind: .derived, speakerID: "extractor", threadID: "thread-2", observedAt: 21, recordedAt: 22, accessScope: .user, text: "Blue summary one", parentEvidenceIDs: ["e1"])
        let d2 = BrainEvidence(id: "d2", sourceKind: .derived, speakerID: "extractor", threadID: "thread-2", observedAt: 21, recordedAt: 22, accessScope: .user, text: "Blue summary two", parentEvidenceIDs: ["e1"])
        let proposal = BrainClaim(id: "c3", revision: 0, subject: "self:user", predicate: "other-color", value: .string("blue"), modality: .proposed, status: .active, validFrom: 21, recordedAt: 22, evidenceIDs: ["d1", "d2"])
        XCTAssertEqual(try second.commit(request("three", proposal, 2, evidence: [d1, d2])).disposition, .committed)
        let independent = try db.dbQueue.read { db in try second.roots(of: d1, db: db).union(second.roots(of: d2, db: db)) }
        XCTAssertEqual(independent, ["e1"])
        XCTAssertEqual(try second.revision(), 3)
        XCTAssertThrowsError(try BrainStore(store: db).revision()) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
        let other = BrainAuthorization(principal: "other", owner: "other", subjects: ["self:user"], scopes: [.user], threads: ["thread-2"], sourceSpeakers: [:])
        XCTAssertThrowsError(try BrainStore(store: db, authorization: other).revision()) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
    }

    func testProjectionReconcilesEventTimeAndNeverRevivesExpiredCorrection() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let brain = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try brain.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let correction = BrainClaim(id: "c2", revision: 0, subject: "self:user", predicate: "color", value: .string("red"), modality: .asserted, status: .active, validFrom: 20, validTo: 30, recordedAt: 21, evidenceIDs: ["e2"], supersedesID: "c1")
        XCTAssertEqual(try brain.commit(request("two", correction, 1, evidence: [evidence("e2", text: "Correction: I like red")])).disposition, .committed)
        try brain.reconcileProjections(now: 15)
        XCTAssertEqual(try db.allNodes().map(\.id), ["brain-claim:c1"])
        try brain.reconcileProjections(now: 25)
        XCTAssertEqual(try db.allNodes().map(\.id), ["brain-claim:c2"])
        try brain.reconcileProjections(now: 35)
        XCTAssertTrue(try db.allNodes().isEmpty)
        try brain.reconcileProjections(now: 25)
        try db.softDelete(nodeId: "brain-claim:c2")
        try brain.reconcileProjections(now: 25)
        XCTAssertTrue(try db.allNodes().isEmpty, "explicit deletion must not be undone by reconciliation")
    }
    func testCorrectionWithdrawsProjectionWithoutProjectionGrant() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let writer = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try writer.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let noProject = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]], mayCommitClaims: true)
        let corrector = BrainStore(store: db, authorization: noProject)
        XCTAssertEqual(try corrector.commit(request("two", claim("c2", value: "red", time: 20, source: "e2", previous: "c1"), 1, evidence: [evidence("e2", text: "Correction: I like red")])).disposition, .committed)
        XCTAssertTrue(try db.allNodes().isEmpty)
    }
    func testForgedClaimExtraIsNotSourceBound() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let fake = Node(id: "fake", kind: "fact", label: "color", body: "forged", layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 1, decayRate: 0, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: #"{"claimID":"c1"}"#)
        try db.upsert(fake)
        let block = MemoryRetriever(store: db, embedder: nil).injectionBlock(for: [fake])
        XCTAssertTrue(block.contains("unverified legacy"))
        XCTAssertFalse(block.contains("source-bound classification"))
    }

    func testStaleConflictDoesNotBindEmptyDatabaseOwner() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let first = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try first.commit(request("stale", claim(), 1)).disposition, .conflict)
        let otherAuth = BrainAuthorization(principal: "other", owner: "other", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]], mayCommitClaims: true)
        let other = BrainStore(store: db, authorization: otherAuth)
        XCTAssertEqual(try other.commit(request("ok", claim(), 0, evidence: [evidence()])).disposition, .committed)
    }

    func testContradictionLinksSurviveWireAndReopenAndRejectInvalidTargets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let linked = BrainClaim(id: "c2", revision: 0, subject: "self:user", predicate: "color", value: .string("red"), modality: .asserted, status: .active, validFrom: 20, recordedAt: 21, evidenceIDs: ["e2"], contradictsIDs: ["c1"])
        let encoded = try JSONEncoder().encode(linked)
        XCTAssertEqual(try JSONDecoder().decode(BrainClaim.self, from: encoded).contradictsIDs, ["c1"])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "contradictsIDs")
        XCTAssertEqual(try JSONDecoder().decode(BrainClaim.self, from: JSONSerialization.data(withJSONObject: legacy)).contradictsIDs, [])
        do {
            let db = try MemoryStore(url: url, embeddingDim: 4)
            let store = BrainStore(store: db, authorization: auth)
            XCTAssertEqual(try store.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
            XCTAssertEqual(try store.commit(request("two", linked, 1, evidence: [evidence("e2", text: "I like red")])).disposition, .committed)
            let invalid = BrainClaim(id: "c3", revision: 0, subject: "self:user", predicate: "color", value: .string("green"), modality: .asserted, status: .active, validFrom: 30, recordedAt: 31, evidenceIDs: ["e3"], contradictsIDs: ["missing"])
            XCTAssertThrowsError(try store.commit(request("bad", invalid, 2, evidence: [evidence("e3", text: "I like green")])))
            XCTAssertEqual(try store.revision(), 2)
        }
        let reopened = BrainStore(store: try MemoryStore(url: url, embeddingDim: 4), authorization: auth)
        let claims = try reopened.claims(subject: "self:user", asOf: 30, scope: .user)
        XCTAssertEqual(claims.first { $0.id == "c2" }?.contradictsIDs, ["c1"])
    }
    func testProposalCannotSupersedeFactualAssertion() throws {
        let store = BrainStore(store: try MemoryStore(inMemory: true, embeddingDim: 4), authorization: auth)
        XCTAssertEqual(try store.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let proposed = BrainClaim(id: "c2", revision: 0, subject: "self:user", predicate: "color", value: .string("red"), modality: .proposed, status: .active, validFrom: 20, recordedAt: 21, evidenceIDs: ["e2"], supersedesID: "c1")
        XCTAssertThrowsError(try store.commit(request("proposal", proposed, 1, evidence: [evidence("e2", text: "Maybe I like red")])))
        XCTAssertEqual(try store.revision(), 1)
        XCTAssertEqual(try store.claims(subject: "self:user", asOf: 30, scope: .user).map(\.id), ["c1"])
    }
    func testClaimRevisionAndSupersessionConflictsReturnDispositionAndRollback() throws {
        let store = BrainStore(store: try MemoryStore(inMemory: true, embeddingDim: 4), authorization: auth)
        XCTAssertEqual(try store.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let correction = claim("c2", value: "red", time: 20, source: "e2", previous: "c1")
        let stale = try BrainCommitRequest(clientOperationID: "stale-claim", evidence: [evidence("e2", text: "Correction: I like red")], updates: [.init(claim: correction, expectedRevision: 999)], expectedRevision: 1)
        XCTAssertEqual(try store.commit(stale).disposition, .conflict)
        XCTAssertEqual(try store.revision(), 1)
        XCTAssertEqual(try store.recordEvidence(evidence("e2", text: "Correction: I like red; source after rollback"), idempotencyKey: "after").text, "Correction: I like red; source after rollback")
        XCTAssertEqual(try store.commit(request("two", correction, 1)).disposition, .committed)
        let staleSupersession = claim("c3", value: "green", time: 30, source: "e3", previous: "c1")
        XCTAssertEqual(try store.commit(request("stale-target", staleSupersession, 2, evidence: [evidence("e3", text: "Correction: I like green")])).disposition, .conflict)
        XCTAssertEqual(try store.revision(), 2)
    }

    func testRenderCannotBorrowProjectionIdentityForForgedBody() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let brain = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try brain.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        var forged = try XCTUnwrap(db.node(id: "brain-claim:c1"))
        forged.body = "forged in memory"
        let block = MemoryRetriever(store: db, embedder: nil).injectionBlock(for: [forged])
        XCTAssertFalse(block.contains("forged in memory"))
        XCTAssertTrue(block.contains("blue"))
    }
    func testLegacyBindingCannotTargetManagedProjection() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let writer = BrainStore(store: db, authorization: auth)
        XCTAssertEqual(try writer.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
        let binding = BrainLegacyBinding(claimID: "c2", subject: "self:user", predicate: "color", nodeIDs: ["brain-claim:c1"])
        let granted = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]], mayProject: true, legacyBindings: [binding], mayCommitClaims: true)
        let next = BrainStore(store: db, authorization: granted)
        XCTAssertThrowsError(try next.commit(request("two", claim("c2", value: "red", time: 20, source: "e2"), 1, evidence: [evidence("e2", text: "I like red")])))
        XCTAssertEqual(try next.revision(), 1)
        XCTAssertEqual(try db.allNodes().map(\.id), ["brain-claim:c1"])
    }

    func testUpgradeV10PreservesLegacyDataAndAllowsFirstBrainCommit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let extra = #"{"subjectId":"self:user","legacyFlag":"kept"}"#
        let original = Node(id: "legacy-node", kind: "fact", label: "synthetic label", body: "synthetic original body", layer: .daily, createdAt: 1, updatedAt: 2, lastSeenAt: 2, salience: 1, decayRate: 0, confidence: .maybe, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra)
        do {
            let v11 = try MemoryStore(url: url, embeddingDim: 4)
            try v11.upsert(original)
            try v11.setEmbedding(nodeId: original.id, [1, 0, 0, 0])
            let transcripts = TranscriptStore(dbQueue: v11.dbQueue)
            _ = try transcripts.append(threadId: "legacy-thread", turnIndex: 0, role: "user", text: "synthetic prior turn", now: 3)
            try v11.dbQueue.write { db in
                for table in ["brain_legacy_binding", "brain_projection", "brain_commit", "brain_claim", "brain_evidence_operations", "brain_evidence", "brain_meta"] {
                    try db.execute(sql: "DROP TABLE \(table)")
                }
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier=?", arguments: ["v11-brain-store"])
            }
        }
        let upgraded = try MemoryStore(url: url, embeddingDim: 4)
        let applied = try upgraded.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier=?", arguments: ["v11-brain-store"]) }
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(try upgraded.node(id: original.id), original)
        XCTAssertEqual(try upgraded.searchFTS(query: "synthetic", limit: 10).map(\.id), [original.id])
        XCTAssertEqual(try upgraded.nearest(to: [1, 0, 0, 0], k: 1).first?.id, original.id)
        XCTAssertEqual(try TranscriptStore(dbQueue: upgraded.dbQueue).recent(threadId: "legacy-thread", maxTurns: 5, maxChars: 100).map(\.text), ["synthetic prior turn"])
        let brain = BrainStore(store: upgraded, authorization: auth)
        XCTAssertEqual(try brain.commit(request("first", claim(), 0, evidence: [evidence()])).disposition, .committed)
        XCTAssertEqual(try brain.revision(), 1)
        XCTAssertEqual(try upgraded.node(id: original.id), original)
    }

    func testReconciliationCannotPublishOrRetireOutsideSubjectAndScope() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let legacy = Node(id: "legacy-future", kind: "fact", label: "tone", body: "old legacy", layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 1, decayRate: 0, confidence: .maybe, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: #"{"subjectId":"self:user","ownerId":"user"}"#)
        try db.upsert(legacy)
        let future: Double = 20
        let binding = BrainLegacyBinding(claimID: "future", subject: "self:user", predicate: "tone", nodeIDs: [legacy.id])
        let writerAuth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]], mayProject: true, legacyBindings: [binding], mayCommitClaims: true)
        let writer = BrainStore(store: db, authorization: writerAuth, clock: { 10 })
        let futureClaim = BrainClaim(id: "future", revision: 0, subject: "self:user", predicate: "tone", value: .string("blue"), modality: .asserted, status: .active, validFrom: future, recordedAt: future - 1, evidenceIDs: ["e1"])
        XCTAssertEqual(try writer.commit(request("future-op", futureClaim, 0, evidence: [evidence()])).disposition, .committed)
        XCTAssertEqual(try db.node(id: legacy.id)?.deleted, false)
        XCTAssertEqual(try db.node(id: "brain-claim:future")?.deleted, true)
        let unrelated = BrainAuthorization(principal: "worker", owner: "user", subjects: ["self:agent"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [:], mayProject: true, allowDelegated: true)
        try BrainStore(store: db, authorization: unrelated).reconcileProjections(now: future + 1)
        XCTAssertEqual(try db.node(id: legacy.id)?.deleted, false)
        XCTAssertEqual(try db.node(id: "brain-claim:future")?.deleted, true)
        let threadOnly = BrainAuthorization(principal: "worker", owner: "user", subjects: ["self:agent"], scopes: [.thread], threads: ["thread-1"], sourceSpeakers: [.assistantMessage: ["self:agent"]], mayProject: true, allowDelegated: true, mayCommitClaims: true)
        let actor = BrainStore(store: db, authorization: threadOnly, clock: { 25 })
        XCTAssertThrowsError(try actor.reconcileProjections(now: future + 1)) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
        let threadEvidence = BrainEvidence(id: "agent-e", sourceKind: .assistantMessage, speakerID: "self:agent", threadID: "thread-1", observedAt: future, recordedAt: future, accessScope: .thread, text: "synthetic agent statement")
        let threadClaim = BrainClaim(id: "agent-c", revision: 0, subject: "self:agent", predicate: "status", value: .string("ready"), modality: .asserted, status: .active, validFrom: future, recordedAt: future, evidenceIDs: ["agent-e"])
        XCTAssertEqual(try actor.commit(request("agent-op", threadClaim, 1, evidence: [threadEvidence])).disposition, .committed)
        XCTAssertEqual(try db.node(id: legacy.id)?.deleted, false)
        XCTAssertEqual(try db.node(id: "brain-claim:future")?.deleted, true)
        try writer.reconcileProjections(now: future + 1)
        XCTAssertEqual(try db.node(id: legacy.id)?.deleted, true)
        XCTAssertEqual(try db.node(id: "brain-claim:future")?.deleted, false)
    }
    func testLegacyDedupSkipsManagedProjectionForExactAndSemanticCandidates() throws {
        for semantic in [false, true] {
            let db = try MemoryStore(inMemory: true, embeddingDim: 4)
            let brain = BrainStore(store: db, authorization: auth)
            XCTAssertEqual(try brain.commit(request("one", claim(), 0, evidence: [evidence()])).disposition, .committed)
            let projected = try XCTUnwrap(db.node(id: "brain-claim:c1"))
            try db.setEmbedding(nodeId: projected.id, [1, 0, 0, 0])
            let candidate = Node(id: "legacy-new", kind: "fact", label: "color", body: "new candidate", layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 1, decayRate: 0, confidence: .maybe, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: #"{"subjectId":"self:user","ownerId":"user"}"#)
            if semantic {
                XCTAssertNil(try db.findSemanticDuplicate(kind: "fact", embedding: [1, 0, 0, 0], threshold: 0.2, candidate: candidate))
                XCTAssertEqual(try db.upsertMergingSemantic(candidate, embedding: [1, 0, 0, 0], embedder: nil), candidate.id)
            } else {
                XCTAssertNil(try db.findDuplicate(kind: "fact", label: "color", candidate: candidate))
                XCTAssertEqual(try db.upsertMerging(candidate), candidate.id)
            }
            XCTAssertEqual(try db.node(id: projected.id)?.body, "blue")
            XCTAssertThrowsError(try db.upsertMerging(projected))
        }
    }
    func testLegacyDedupSkipsPendingManagedBinding() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let legacy = Node(id: "bound", kind: "fact", label: "color", body: "legacy original", layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 1, decayRate: 0, confidence: .maybe, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: #"{"subjectId":"self:user","ownerId":"user"}"#)
        try db.upsert(legacy)
        let binding = BrainLegacyBinding(claimID: "c1", subject: "self:user", predicate: "color", nodeIDs: [legacy.id])
        let granted = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]], mayProject: true, legacyBindings: [binding], mayCommitClaims: true)
        let brain = BrainStore(store: db, authorization: granted, clock: { 10 })
        let future: Double = 20
        XCTAssertEqual(try brain.commit(request("one", claim(time: future), 0, evidence: [evidence()])).disposition, .committed)
        var candidate = legacy; candidate.id = "new-legacy"
        XCTAssertEqual(try db.upsertMerging(candidate), candidate.id)
        XCTAssertEqual(try db.node(id: legacy.id)?.body, "legacy original")
        XCTAssertThrowsError(try db.upsertMerging(legacy))
    }
}
