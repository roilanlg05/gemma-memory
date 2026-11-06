import XCTest
import BrainContract
import GRDB
@testable import MemoryCore

private struct EmptyTurnExtractor: BrainTurnExtractor {
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] { [] }
}

private struct FailingTurnExtractor: BrainTurnExtractor {
    struct Failure: Error {}
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] { throw Failure() }
}

private struct PreferenceTurnExtractor: BrainTurnExtractor {
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] {
        let claim = BrainClaim(id: "claim-coffee", revision: 0, subject: "self:user",
            predicate: "preference.drink", value: .string("tea"), modality: .asserted,
            status: .active, validFrom: source.observedAt, recordedAt: source.recordedAt,
            evidenceIDs: [source.id])
        return [.init(update: .init(claim: claim), span: .init(start: 0, end: source.text!.utf8.count), intent: .explicit)]
    }
}

private struct BadTurnExtractor: BrainTurnExtractor {
    let subject: String
    let foreignEvidence: Bool
    let badSpan: Bool
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] {
        let claim = BrainClaim(id: "bad", revision: 0, subject: subject, predicate: "preference.drink",
            value: .string("tea"), modality: .asserted, status: .active,
            validFrom: source.observedAt, recordedAt: source.recordedAt,
            evidenceIDs: [foreignEvidence ? "foreign" : source.id])
        return [.init(update: .init(claim: claim), span: .init(start: 0, end: badSpan ? source.text!.utf8.count + 1 : source.text!.utf8.count), intent: .explicit)]
    }
}

final class BrainTurnServiceTests: XCTestCase {
    private func authorization() -> BrainAuthorization {
        BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user],
            threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"], .assistantMessage: ["self:agent"]],
            mayCommitClaims: true, mayForget: true)
    }
    private func request(_ text: String = "I prefer tea", operation: String = "op-1") throws -> BrainTurnRequest {
        try BrainTurnRequest(clientOperationID: operation, threadID: "thread-1",
            message: .init(id: "message-1", speakerID: "self:user", text: text, observedAt: 10, evidenceIDs: []),
            budget: .init(contextTokens: 1000, outputTokens: 100))
    }
    func test_begin_retry_is_one_input_and_changed_payload_conflicts() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let service = BrainTurnService(store: db, authorization: authorization(), extractor: EmptyTurnExtractor(), clock: { 20 })
        let first = try await service.begin(request())
        let retry = try await service.begin(request())
        XCTAssertEqual(first.turnID, retry.turnID)
        XCTAssertEqual(first.reply, "")
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
        do { _ = try await service.begin(request("I prefer coffee")); XCTFail("expected conflict") }
        catch { XCTAssertEqual(error as? BrainStoreError, .conflict) }
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
    }
    func test_failed_extraction_retains_one_pending_input_without_assistant() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let service = BrainTurnService(store: db, authorization: authorization(), extractor: FailingTurnExtractor(), clock: { 20 })
        let result = try await service.begin(request())
        XCTAssertEqual(result.completion.state, .pending)
        XCTAssertEqual(result.reply, "")
        let rows = try TranscriptStore(dbQueue: db.dbQueue).range(threadId: "thread-1", from: 1, to: 99)
        XCTAssertEqual(rows.map(\.role), ["user"])
    }
    func test_explicit_preference_is_committed_before_begin_returns_without_embedder() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = authorization()
        let service = BrainTurnService(store: db, authorization: auth, extractor: PreferenceTurnExtractor(), clock: { 20 })
        let result = try await service.begin(request())
        XCTAssertEqual(result.completion.state, .committed)
        let claims = try BrainStore(store: db, authorization: auth).claims(subject: "self:user", asOf: 20, scope: .user)
        XCTAssertEqual(claims.map(\.value), [.string("tea")])
        XCTAssertEqual(claims.first?.evidenceIDs, result.completion.evidenceIDs)
    }
    func test_forgotten_turn_retry_cannot_recreate_input() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = authorization()
        let service = BrainTurnService(store: db, authorization: auth, extractor: FailingTurnExtractor(), clock: { 20 })
        let result = try await service.begin(request("tea"))
        let brain = BrainStore(store: db, authorization: auth)
        let forget = BrainRetractionService(brain: brain)
        _ = try forget.forget(scope: .init(kind: .evidence, id: result.completion.evidenceIDs[0]), expectedRevision: brain.revision(), operationID: "forget-1")
        do { _ = try await service.begin(request("tea")); XCTFail("forgotten replay must be denied") }
        catch { XCTAssertEqual(error as? BrainStoreError, .denied) }
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 0)
    }
    func test_invalid_span_foreign_evidence_and_other_subject_remain_pending() async throws {
        for extractor in [BadTurnExtractor(subject: "self:user", foreignEvidence: false, badSpan: true),
                          BadTurnExtractor(subject: "self:user", foreignEvidence: true, badSpan: false),
                          BadTurnExtractor(subject: "self:agent", foreignEvidence: false, badSpan: false)] {
            let db = try MemoryStore(inMemory: true, embeddingDim: 16)
            let auth = authorization()
            let service = BrainTurnService(store: db, authorization: auth, extractor: extractor, clock: { 20 })
            let result = try await service.begin(request())
            XCTAssertEqual(result.completion.state, .pending)
            XCTAssertTrue(try BrainStore(store: db, authorization: auth).claims(subject: "self:user", asOf: 20, scope: .user).isEmpty)
            XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
        }
    }
}


private struct ClosureTurnExtractor: BrainTurnExtractor {
    let body: (BrainEvidence) async throws -> [BrainTurnProposal]
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] { try await body(source) }
}

extension BrainTurnServiceTests {
    func test_retrieval_observes_exact_correction_before_reply() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = authorization()
        let brain = BrainStore(store: db, authorization: auth)
        let old = BrainEvidence(id: "old", sourceKind: .userMessage, speakerID: "self:user", threadID: "thread-1", observedAt: 1, recordedAt: 1, accessScope: .user, text: "I prefer coffee")
        let previous = BrainClaim(id: "previous", revision: 0, subject: "self:user", predicate: "preference.drink", value: .string("coffee"), modality: .asserted, status: .active, validFrom: 1, recordedAt: 1, evidenceIDs: ["old"])
        _ = try brain.commit(.init(clientOperationID: "old-commit", evidence: [old], updates: [.init(claim: previous)], expectedRevision: 0))
        let extractor = ClosureTurnExtractor { source in
            let corrected = BrainClaim(id: "corrected", revision: 0, subject: "self:user", predicate: "preference.drink", value: .string("tea"), modality: .asserted, status: .active, validFrom: 10, recordedAt: 20, evidenceIDs: [source.id], supersedesID: "previous")
            return [.init(update: .init(claim: corrected, expectedRevision: 1), span: .init(start: 0, end: source.text!.utf8.count), intent: .explicit)]
        }
        let service = BrainTurnService(store: db, authorization: auth, extractor: extractor, clock: { 20 }, retrieval: { _, _ in
            let claims = try brain.claims(subject: "self:user", asOf: 20, scope: .user)
            return BrainContextBundle(renderedContext: claims.map(\.id).joined(separator: ","), recentMessageUnits: [], sourceReferences: [], revision: try brain.revision(), policyRevision: 0)
        })
        let result = try await service.begin(request("Actually I prefer tea"))
        XCTAssertEqual(result.context?.renderedContext, "corrected")
        XCTAssertEqual(result.completion.state, .committed)
    }

    func test_concurrent_clients_and_reopened_service_share_one_durable_turn() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = authorization()
        let a = BrainTurnService(store: db, authorization: auth, extractor: EmptyTurnExtractor(), clock: { 20 })
        let b = BrainTurnService(store: db, authorization: auth, extractor: EmptyTurnExtractor(), clock: { 21 })
        let input = try request()
        async let first = a.begin(input)
        async let second = b.begin(input)
        let results = try await [first, second]
        XCTAssertEqual(Set(results.map(\.turnID)).count, 1)
        XCTAssertTrue(results.allSatisfy { $0.completion.state == .committed })
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
        XCTAssertEqual(try BrainStore(store: db, authorization: auth).revision(), 1)
    }

    func test_short_source_forget_purges_assistant_outcome_and_denies_all_replays() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = authorization()
        let brain = BrainStore(store: db, authorization: auth)
        let service = BrainTurnService(store: db, authorization: auth, extractor: EmptyTurnExtractor(), clock: { 20 })
        let input = try request("tea")
        let turn = try await service.begin(input)
        let assistant = try service.recordAssistant(turnID: turn.turnID, operationID: "assistant-1", text: "Recorded your choice")
        let replay = try service.recordAssistant(turnID: turn.turnID, operationID: "assistant-1", text: "Recorded your choice")
        XCTAssertEqual(assistant, replay)
        let outcome = BrainOutcome(id: "outcome-1", description: "secret tool body", status: .failed, recordedAt: 21, evidenceIDs: turn.completion.evidenceIDs)
        let saved = try service.recordOutcome(outcome)
        XCTAssertEqual(saved.description, "")
        XCTAssertEqual(saved.status, .failed)
        _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: turn.completion.evidenceIDs[0]), expectedRevision: brain.revision(), operationID: "forget-short")
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 0)
        do { _ = try await service.begin(input); XCTFail("replay resurrected source") } catch { XCTAssertEqual(error as? BrainStoreError, .denied) }
        XCTAssertThrowsError(try service.recordAssistant(turnID: turn.turnID, operationID: "assistant-1", text: "Recorded your choice"))
        XCTAssertThrowsError(try service.recordOutcome(outcome))
        let journalCounts = try await db.dbQueue.read { db in
            try ["brain_turn", "brain_turn_ref", "brain_turn_claim", "brain_turn_outcome", "brain_turn_outcome_ref", "brain_commit"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(journalCounts, [0, 0, 0, 0, 0, 0])
        let tombstones = try await db.dbQueue.read { try Row.fetchAll($0, sql: "SELECT * FROM brain_turn_operation WHERE withdrawn=1") }
        XCTAssertEqual(tombstones.count, 3)
        for row in tombstones {
            XCTAssertNil(row["request_hash"] as String?)
            XCTAssertNil(row["turn_id"] as String?)
            XCTAssertNil(row["result_id"] as String?)
            XCTAssertFalse(["op-1", "assistant-1", "outcome-1"].contains(row["operation_hash"] as String))
        }
        let next = try await service.begin(request("water", operation: "new-input"))
        XCTAssertNotEqual(next.turnID, turn.turnID)
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).range(threadId: "thread-1", from: 1, to: 99).map(\.seq), [3])
    }

    func test_forget_during_extraction_cannot_finalize_or_recreate_claim() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = authorization()
        let brain = BrainStore(store: db, authorization: auth)
        let extractor = ClosureTurnExtractor { source in
            _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: source.id), expectedRevision: brain.revision(), operationID: "forget-inflight")
            return try await PreferenceTurnExtractor().extract(source: source)
        }
        let service = BrainTurnService(store: db, authorization: auth, extractor: extractor, clock: { 20 })
        do { _ = try await service.begin(request()); XCTFail("forgotten turn completed") }
        catch { XCTAssertEqual(error as? BrainStoreError, .denied) }
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 0)
        XCTAssertTrue(try brain.claims(subject: "self:user", asOf: 20, scope: .user).isEmpty)
    }

    func test_candidate_quoted_and_hypothetical_proposals_stay_pending() async throws {
        for qualification: BrainTurnQualification in [.firstPerson, .quoted, .hypothetical, .thirdParty, .uncertain] {
            let db = try MemoryStore(inMemory: true, embeddingDim: 16)
            let auth = authorization()
            let extractor = ClosureTurnExtractor { source in
                let base = try await PreferenceTurnExtractor().extract(source: source)[0]
                return [.init(update: base.update, span: base.span, intent: qualification == .firstPerson ? .candidate : .explicit, qualification: qualification)]
            }
            let service = BrainTurnService(store: db, authorization: auth, extractor: extractor, clock: { 20 })
            let result = try await service.begin(request())
            XCTAssertEqual(result.completion.state, .pending)
            XCTAssertTrue(try BrainStore(store: db, authorization: auth).claims(subject: "self:user", asOf: 20, scope: .user).isEmpty)
        }
    }

    func test_client_cannot_spoof_role_or_promote_unvalidated_updates() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let service = BrainTurnService(store: db, authorization: authorization(), extractor: FailingTurnExtractor(), clock: { 20 })
        let forged = try BrainTurnRequest(clientOperationID: "forged", threadID: "thread-1", message: .init(id: "x", speakerID: "self:agent", text: "I prefer tea", observedAt: 10, evidenceIDs: []), budget: .init(contextTokens: 1000, outputTokens: 100))
        do { _ = try await service.begin(forged); XCTFail("role accepted") } catch { XCTAssertEqual(error as? BrainStoreError, .denied) }
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 0)
        let turn = try await service.begin(request())
        let invented = BrainClaim(id: "injected", revision: 0, subject: "self:user", predicate: "preference.drink", value: .string("coffee"), modality: .asserted, status: .active, validFrom: 10, recordedAt: 20, evidenceIDs: turn.completion.evidenceIDs)
        XCTAssertThrowsError(try service.commitUpdates([.init(claim: invented)], turnID: turn.turnID))
    }
}


extension BrainTurnServiceTests {
    func test_pending_input_reopens_and_retries_without_second_source() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var turnID = ""
        do {
            let db = try MemoryStore(url: url, embeddingDim: 16)
            let service = BrainTurnService(store: db, authorization: authorization(), extractor: FailingTurnExtractor(), clock: { 20 })
            let result = try await service.begin(request())
            turnID = result.turnID
            XCTAssertEqual(result.completion.state, .pending)
        }
        let reopened = try MemoryStore(url: url, embeddingDim: 16)
        let service = BrainTurnService(store: reopened, authorization: authorization(), extractor: PreferenceTurnExtractor(), clock: { 30 })
        let result = try await service.begin(request())
        XCTAssertEqual(result.turnID, turnID)
        XCTAssertEqual(result.completion.state, .committed)
        XCTAssertEqual(try TranscriptStore(dbQueue: reopened.dbQueue).count(), 1)
        XCTAssertEqual(try service.currentClaims(turnID: turnID, asOf: 30).map(\.value), [.string("tea")])
    }

    func test_repeated_candidate_cannot_be_promoted_by_a_retry() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let candidate = ClosureTurnExtractor { source in
            let base = try await PreferenceTurnExtractor().extract(source: source)[0]
            return [.init(update: base.update, span: base.span, intent: .candidate)]
        }
        let first = BrainTurnService(store: db, authorization: authorization(), extractor: candidate, clock: { 20 })
        let pending = try await first.begin(request())
        XCTAssertEqual(pending.completion.state, .pending)
        let retry = BrainTurnService(store: db, authorization: authorization(), extractor: PreferenceTurnExtractor(), clock: { 30 })
        let result = try await retry.begin(request())
        XCTAssertEqual(result.completion.state, .pending)
        XCTAssertTrue(try retry.currentClaims(turnID: result.turnID, asOf: 30).isEmpty)
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
    }

    func test_valid_explicit_update_commits_while_unrelated_candidate_stays_pending() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let extractor = ClosureTurnExtractor { source in
            let explicit = try await PreferenceTurnExtractor().extract(source: source)[0]
            let candidate = BrainClaim(id: "candidate", revision: 0, subject: "self:user", predicate: "preference.food", value: .string("rice"), modality: .hypothetical, status: .active, validFrom: 10, recordedAt: 20, evidenceIDs: [source.id])
            return [explicit, .init(update: .init(claim: candidate), span: explicit.span, intent: .candidate)]
        }
        let service = BrainTurnService(store: db, authorization: authorization(), extractor: extractor, clock: { 20 })
        let result = try await service.begin(request("I prefer tea; perhaps rice someday"))
        XCTAssertEqual(result.completion.state, .pending)
        XCTAssertEqual(try service.currentClaims(turnID: result.turnID, asOf: 20).map(\.id), ["claim-coffee"])
    }

    func test_negated_preference_remains_negated_and_allows_old_valid_from() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let extractor = ClosureTurnExtractor { source in
            let claim = BrainClaim(id: "negative", revision: 0, subject: "self:user", predicate: "preference.drink", value: .string("coffee"), modality: .negated, status: .active, validFrom: 1, recordedAt: 20, evidenceIDs: [source.id])
            return [.init(update: .init(claim: claim), span: .init(start: 0, end: source.text!.utf8.count), intent: .explicit)]
        }
        let service = BrainTurnService(store: db, authorization: authorization(), extractor: extractor, clock: { 20 })
        let result = try await service.begin(request("I have never liked coffee"))
        XCTAssertEqual(result.completion.state, .committed)
        let claim = try XCTUnwrap(service.currentClaims(turnID: result.turnID, asOf: 20).first)
        XCTAssertEqual(claim.modality, .negated)
        XCTAssertEqual(claim.validFrom, 1)
    }

    func test_span_cannot_split_a_utf8_scalar() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let extractor = ClosureTurnExtractor { source in
            let base = try await PreferenceTurnExtractor().extract(source: source)[0]
            return [.init(update: base.update, span: .init(start: 1, end: 2), intent: .explicit)]
        }
        let service = BrainTurnService(store: db, authorization: authorization(), extractor: extractor, clock: { 20 })
        let result = try await service.begin(request("é"))
        XCTAssertEqual(result.completion.state, .pending)
        XCTAssertTrue(try service.currentClaims(turnID: result.turnID, asOf: 20).isEmpty)
    }

    func test_subject_claim_thread_and_all_forget_invalidate_turn_and_output() async throws {
        let scopes: [BrainForgetScope] = [.init(kind: .subject, id: "self:user"), .init(kind: .claim, id: "claim-coffee"), .init(kind: .thread, id: "thread-1"), .init(kind: .all)]
        for scope in scopes {
            let db = try MemoryStore(inMemory: true, embeddingDim: 16)
            let auth = authorization()
            let brain = BrainStore(store: db, authorization: auth)
            let service = BrainTurnService(store: db, authorization: auth, extractor: PreferenceTurnExtractor(), clock: { 20 })
            let result = try await service.begin(request("tea"))
            _ = try service.recordAssistant(turnID: result.turnID, operationID: "answer", text: "okay")
            _ = try BrainRetractionService(brain: brain).forget(scope: scope, expectedRevision: brain.revision(), operationID: "erase")
            XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 0)
            XCTAssertTrue(try brain.claims(subject: "self:user", asOf: 20, scope: .user).isEmpty)
            do { _ = try await service.begin(request("tea")); XCTFail("replayed erased input") }
            catch { XCTAssertEqual(error as? BrainStoreError, .denied) }
            XCTAssertThrowsError(try service.recordAssistant(turnID: result.turnID, operationID: "new-answer", text: "okay"))
        }
    }

    func test_staged_proposal_cannot_commit_after_source_forget() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = authorization()
        let pending = BrainTurnService(store: db, authorization: auth, extractor: FailingTurnExtractor(), clock: { 20 })
        let turn = try await pending.begin(request())
        let service = BrainTurnService(store: db, authorization: auth, extractor: PreferenceTurnExtractor(), clock: { 20 })
        let updates = try await service.proposeUpdates(turnID: turn.turnID)
        let brain = BrainStore(store: db, authorization: auth)
        _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: turn.completion.evidenceIDs[0]), expectedRevision: brain.revision(), operationID: "erase-staged")
        let revision = try brain.revision()
        XCTAssertThrowsError(try service.commitUpdates(updates, turnID: turn.turnID)) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
        XCTAssertEqual(try brain.revision(), revision)
        XCTAssertTrue(try brain.claims(subject: "self:user", asOf: 20, scope: .user).isEmpty)
    }

    func test_multi_source_outcome_is_redacted_conflicts_on_raw_change_and_is_erased_by_either_source() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = authorization()
        let service = BrainTurnService(store: db, authorization: auth, extractor: EmptyTurnExtractor(), clock: { 20 })
        let a = try await service.begin(request("tea"))
        let b = try await service.begin(request("water", operation: "op-2"))
        let outcome = BrainOutcome(id: "multi-outcome", description: "synthetic private tool observation", status: .failed, recordedAt: 21, evidenceIDs: a.completion.evidenceIDs + b.completion.evidenceIDs)
        let saved = try service.recordOutcome(outcome)
        XCTAssertEqual(saved.description, "")
        XCTAssertEqual(saved.status, .failed)
        XCTAssertEqual(try service.recordOutcome(outcome), saved)
        let changed = BrainOutcome(id: outcome.id, description: "different synthetic private observation", status: outcome.status, recordedAt: outcome.recordedAt, evidenceIDs: outcome.evidenceIDs)
        XCTAssertThrowsError(try service.recordOutcome(changed)) { XCTAssertEqual($0 as? BrainStoreError, .conflict) }
        let payload = try await db.dbQueue.read { try String.fetchOne($0, sql: "SELECT payload FROM brain_turn_outcome") }
        XCTAssertFalse(try XCTUnwrap(payload).contains("synthetic private tool observation"))
        let redacted = try await db.dbQueue.read { try Bool.fetchOne($0, sql: "SELECT redacted FROM brain_turn_outcome") }
        XCTAssertEqual(redacted, true)
        let brain = BrainStore(store: db, authorization: auth)
        _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: a.completion.evidenceIDs[0]), expectedRevision: brain.revision(), operationID: "erase-one-source")
        let remainingCounts = try await db.dbQueue.read { db in
            try ["brain_turn_outcome", "brain_turn_outcome_ref"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(remainingCounts, [0, 0])
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
        XCTAssertThrowsError(try service.recordOutcome(outcome)) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
        let survivor = try await service.begin(request("water", operation: "op-2"))
        XCTAssertEqual(survivor.turnID, b.turnID)
    }

    func test_outcome_rejects_noncanonical_server_owner() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let other = BrainAuthorization(principal: "other", owner: "other", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]])
        let brain = BrainStore(store: db, authorization: other)
        let evidence = BrainEvidence(id: "other-source", sourceKind: .userMessage, speakerID: "self:user", threadID: "thread-1", observedAt: 1, recordedAt: 1, accessScope: .user, text: "synthetic source")
        _ = try brain.recordEvidence(evidence, idempotencyKey: "other-source-operation")
        let service = BrainTurnService(store: db, authorization: other, extractor: EmptyTurnExtractor())
        XCTAssertThrowsError(try service.recordOutcome(.init(id: "outcome", description: "observation", status: .unknown, recordedAt: 2, evidenceIDs: [evidence.id]))) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
    }

    func test_retrieval_failure_keeps_committed_input_without_fake_assistant() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let service = BrainTurnService(store: db, authorization: authorization(), extractor: PreferenceTurnExtractor(), clock: { 20 }, retrieval: { _, _ in throw FailingTurnExtractor.Failure() })
        do { _ = try await service.begin(request()); XCTFail("retrieval should fail") } catch is FailingTurnExtractor.Failure {}
        let rows = try TranscriptStore(dbQueue: db.dbQueue).range(threadId: "thread-1", from: 1, to: 99)
        XCTAssertEqual(rows.map(\.role), ["user"])
        let retry = BrainTurnService(store: db, authorization: authorization(), extractor: EmptyTurnExtractor(), clock: { 21 })
        let result = try await retry.begin(request())
        XCTAssertEqual(result.reply, "")
        XCTAssertEqual(result.completion.state, .committed)
        XCTAssertEqual(try retry.currentClaims(turnID: result.turnID, asOf: 21).map(\.value), [.string("tea")])
    }
}


extension BrainTurnServiceTests {
    func test_source_recording_grant_does_not_imply_claim_commit_permission() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let captureOnly = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"]], mayCommitClaims: false)
        let service = BrainTurnService(store: db, authorization: captureOnly, extractor: PreferenceTurnExtractor(), clock: { 20 })
        let result = try await service.begin(request())
        XCTAssertEqual(result.completion.state, .pending)
        XCTAssertTrue(try service.currentClaims(turnID: result.turnID, asOf: 20).isEmpty)
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
        let noSourceGrant = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [:], mayCommitClaims: true)
        let denied = BrainTurnService(store: db, authorization: noSourceGrant, extractor: EmptyTurnExtractor(), clock: { 20 })
        do { _ = try await denied.begin(request("water", operation: "denied-source")); XCTFail("source grant is required") }
        catch { XCTAssertEqual(error as? BrainStoreError, .denied) }
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
    }
}
