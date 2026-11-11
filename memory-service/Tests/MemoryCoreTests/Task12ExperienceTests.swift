import XCTest
import BrainContract
import GRDB
@testable import MemoryCore

private struct Task12Extractor: BrainTurnExtractor {
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] { [] }
}

private struct Task12Authority: ExperienceAuthority {
    let verifyOutcome: Bool
    let confirmUser: Bool
    let verifyProcedure: Bool
    func attribution(for outcome: BrainOutcome, evidence: [BrainEvidence]) -> ExperienceAttribution {
        if verifyOutcome && ["verified", "failed", "future"].contains(outcome.id) && evidence.map(\.id) == outcome.evidenceIDs { return .independentlyVerified }
        if confirmUser && evidence.contains(where: { $0.sourceKind == .userMessage && $0.speakerID == "self:user" }) { return .userConfirmed }
        return .reported
    }
    func approves(procedure: BrainProcedure, outcomes: [BrainOutcome], evidence: [BrainEvidence], environment: String) -> Bool {
        verifyProcedure && environment == "env-a" && procedure.version == 1 && procedure.outcomeIDs == outcomes.map(\.id) && outcomes.contains(where: { $0.id == "verified" }) && evidence.map(\.id) == outcomes[0].evidenceIDs
    }
}

final class Task12ExperienceTests: XCTestCase {
    private func fixture() async throws -> (MemoryStore, BrainAuthorization, BrainTurnService, String) {
        let store = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread-1"], sourceSpeakers: [.userMessage: ["self:user"], .assistantMessage: ["self:agent"]], mayCommitClaims: true, mayForget: true)
        let turns = BrainTurnService(store: store, authorization: auth, extractor: Task12Extractor(), clock: { 20 })
        let req = try BrainTurnRequest(clientOperationID: "turn", threadID: "thread-1", message: .init(id: "message", speakerID: "self:user", text: "It worked", observedAt: 10, evidenceIDs: []), budget: .init(contextTokens: 1000, outputTokens: 100))
        let turn = try await turns.begin(req)
        return (store, auth, turns, turn.completion.evidenceIDs[0])
    }

    func test_reported_success_and_timeout_cannot_validate_even_with_authority() async throws {
        let (store, auth, turns, evidence) = try await fixture()
        let authority = Task12Authority(verifyOutcome: false, confirmUser: false, verifyProcedure: true)
        let experiences = ExperienceStore(store: store, authorization: auth, authority: authority)
        for (id, status) in [("fake", BrainOutcomeStatus.succeeded), ("timeout", .unknown)] {
            _ = try turns.recordOutcome(.init(id: id, description: "success", status: status, recordedAt: 21, evidenceIDs: [evidence], observation: .init(operation: .httpCheck, httpStatus: 200)))
            let library = ProcedureLibrary(experience: experiences)
            let procedure = try await library.proposeProcedure(sourceOutcomeIDs: [id])
            XCTAssertThrowsError(try library.validateProcedure(id: procedure.id, version: procedure.version, verificationEvidenceIDs: [evidence], environment: "env-a"))
            XCTAssertTrue(try library.procedures(for: procedure.description, environment: "env-a", asOf: 30).isEmpty)
        }
    }

    func test_partial_idempotence_user_attribution_and_sanitization() async throws {
        let (store, auth, turns, evidence) = try await fixture()
        let outcome = BrainOutcome(id: "partial", description: "Cookie: session=secret1 Bearer secret2 apiKey=secret3", status: .partial, recordedAt: 21, evidenceIDs: [evidence])
        let first = try turns.recordOutcome(outcome)
        XCTAssertEqual(try turns.recordOutcome(outcome), first)
        _ = try turns.recordOutcome(.init(id: "confirmed", description: "done", status: .succeeded, recordedAt: 22, evidenceIDs: [evidence]))
        let experience = ExperienceStore(store: store, authorization: auth, authority: Task12Authority(verifyOutcome: false, confirmUser: true, verifyProcedure: false))
        XCTAssertEqual(try experience.outcome(id: "confirmed")?.attribution, .userConfirmed)
        let recalled = try experience.outcome(id: "partial")
        XCTAssertEqual(recalled?.outcome.status, .partial)
        XCTAssertEqual(recalled?.attribution, .userConfirmed)
        let payload = try await store.dbQueue.read { try String.fetchOne($0, sql: "SELECT payload FROM brain_turn_outcome LIMIT 1") ?? "" }
        for secret in ["secret1", "secret2", "secret3"] {
            XCTAssertFalse(payload.contains(secret))
            XCTAssertFalse(String(describing: recalled).contains(secret))
        }
        let count = try await store.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM brain_turn_outcome") }
        XCTAssertEqual(count, 2)
    }

    func test_closed_observation_renderer_contains_only_audited_metadata() {
        XCTAssertEqual(SafeToolObservation(result: .partial, httpStatus: 206).rendered, "result=partial; httpStatus=206")
        XCTAssertEqual(SafeToolObservation(result: .unknown, httpStatus: 900).rendered, "result=unknown")
    }

    func test_attested_failure_informs_failure_mode_but_never_a_success_step() async throws {
        let (store, auth, turns, evidence) = try await fixture()
        for (id, status) in [("verified", BrainOutcomeStatus.succeeded), ("failed", .failed)] {
            _ = try turns.recordToolOutcome(id: id, status: status, recordedAt: 21, evidenceIDs: [evidence], observation: .init(operation: .httpCheck, httpStatus: status == .succeeded ? 200 : 500))
        }
        let experiences = ExperienceStore(store: store, authorization: auth, authority: Task12Authority(verifyOutcome: true, confirmUser: false, verifyProcedure: true), clock: { 22 })
        let library = ProcedureLibrary(experience: experiences)
        let procedure = try await library.proposeProcedure(sourceOutcomeIDs: ["verified", "failed"])
        XCTAssertEqual(procedure.steps.count, 1)
        XCTAssertTrue(procedure.failureModes.contains(where: { $0.contains("failed") }))
        try library.validateProcedure(id: procedure.id, version: procedure.version, verificationEvidenceIDs: [evidence], environment: "env-a")
        XCTAssertEqual(try library.procedures(for: "HTTP check", environment: "env-a", asOf: 30).count, 1)
        _ = try turns.recordToolOutcome(id: "future", status: .succeeded, recordedAt: 23, evidenceIDs: [evidence], observation: .init(operation: .httpCheck))
        let future = try await library.proposeProcedure(sourceOutcomeIDs: ["verified", "future"])
        XCTAssertThrowsError(try library.validateProcedure(id: future.id, version: future.version, verificationEvidenceIDs: [evidence], environment: "env-a"))
    }

    func test_verified_version_environment_and_retraction() async throws {
        let (store, auth, turns, evidence) = try await fixture()
        _ = try turns.recordToolOutcome(id: "verified", status: .succeeded, recordedAt: 21, evidenceIDs: [evidence], observation: .init(operation: .httpCheck, httpStatus: 200))
        let experiences = ExperienceStore(store: store, authorization: auth, authority: Task12Authority(verifyOutcome: true, confirmUser: false, verifyProcedure: true), clock: { 22 })
        let library = ProcedureLibrary(experience: experiences)
        let procedure = try await library.proposeProcedure(sourceOutcomeIDs: ["verified"])
        XCTAssertThrowsError(try library.validateProcedure(id: procedure.id, version: procedure.version + 1, verificationEvidenceIDs: [evidence], environment: "env-a"))
        let revision = try await library.reviseProcedure(id: procedure.id, sourceOutcomeIDs: ["verified"])
        XCTAssertEqual(revision.version, 2)
        XCTAssertThrowsError(try library.validateProcedure(id: revision.id, version: revision.version, verificationEvidenceIDs: [evidence], environment: "env-a"))
        try library.validateProcedure(id: procedure.id, version: procedure.version, verificationEvidenceIDs: [evidence], environment: "env-a")
        XCTAssertThrowsError(try library.validateProcedure(id: procedure.id, version: procedure.version, verificationEvidenceIDs: [evidence], environment: "env-b"))
        XCTAssertEqual(try library.procedures(for: procedure.description, environment: "env-a", asOf: 30).first?.state, .validated)
        XCTAssertEqual(try library.procedures(for: procedure.description, environment: "env-b", asOf: 30).first?.state, .needsRevalidation)
        let reopened = ProcedureLibrary(experience: ExperienceStore(store: store, authorization: auth))
        XCTAssertEqual(try reopened.procedures(for: procedure.description, environment: "env-a", asOf: 30).first?.state, .validated)
        let brain = BrainStore(store: store, authorization: auth)
        _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: evidence), expectedRevision: brain.revision(), operationID: "forget")
        XCTAssertNil(try experiences.outcome(id: "verified"))
        XCTAssertTrue(try library.procedures(for: procedure.description, environment: "env-a", asOf: 30).isEmpty)
    }
}

private struct Task12ReviewAuthority: ExperienceAuthority {
    func attribution(for outcome: BrainOutcome, evidence: [BrainEvidence]) -> ExperienceAttribution { .independentlyVerified }
    func approves(procedure: BrainProcedure, outcomes: [BrainOutcome], evidence: [BrainEvidence], environment: String) -> Bool { ["env-a", "env-b"].contains(environment) }
}

extension Task12ExperienceTests {
    func test_review_raw_tool_text_rejected_and_legacy_grouped_context_redacted() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let auth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["t"], sourceSpeakers: [.assistantMessage: ["self:agent"], .toolObservation: ["tool:test"]], mayForget: true)
        let brain = BrainStore(store: store, authorization: auth, clock: { 40 })
        let secret = "Cookie: sid=secret1 Bearer secret2 apiKey=secret3"
        let unsafe = BrainEvidence(id: "tool", sourceKind: .toolObservation, speakerID: "tool:test", threadID: "t", observedAt: 2, recordedAt: 2, accessScope: .user, text: secret)
        XCTAssertThrowsError(try brain.recordEvidence(unsafe, idempotencyKey: "bad-tool"))
        let safeText = SafeToolObservation(result: .succeeded, httpStatus: 200).rendered
        let safe = BrainEvidence(id: "safe", sourceKind: .toolObservation, speakerID: "tool:test", threadID: "t", observedAt: 3, recordedAt: 3, accessScope: .user, text: safeText)
        _ = try brain.recordEvidence(safe, idempotencyKey: "safe")
        let call = BrainEvidence(id: "call", sourceKind: .assistantMessage, speakerID: "self:agent", threadID: "t", observedAt: 1, recordedAt: 1, accessScope: .user, text: "Calling tool")
        _ = try brain.recordEvidence(call, idempotencyKey: "call")
        // Simulate rows from before the tool-observation boundary existed.
        try await store.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO brain_evidence(id,payload) VALUES (?,?)", arguments: [unsafe.id, try BrainStore.encode(unsafe)])
        }
        let state = ConversationStateStore(brain: brain, unitGroups: [.init(id: "group", evidenceIDs: ["call", "tool"])])
        let request = try BrainContextRequest(clientOperationID: "context", threadID: "t", query: "result", budget: .init(contextTokens: 4096, outputTokens: 100))
        let context = try await BrainContextAssembler(store: state).context(request)
        XCTAssertFalse(context.renderedContext.contains("secret"))
        XCTAssertFalse(context.recentMessageUnits.contains { $0.text.contains("secret") })
        let safeState = ConversationStateStore(brain: brain, unitGroups: [.init(id: "safe-group", evidenceIDs: ["call", "safe"])])
        let safeContext = try await BrainContextAssembler(store: safeState).context(request)
        XCTAssertTrue(safeContext.recentMessageUnits.contains { $0.evidenceIDs == ["safe"] && $0.text == safeText })
        _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: "tool"), expectedRevision: brain.revision(), operationID: "erase-legacy")
    }

    func test_review_full_lineage_time_is_enforced() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let auth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["t"], sourceSpeakers: [.userMessage: ["self:user"], .derived: ["self:agent"]], mayForget: true)
        let brain = BrainStore(store: store, authorization: auth, clock: { 20 })
        let root = BrainEvidence(id: "future-root", sourceKind: .userMessage, speakerID: "self:user", threadID: "t", observedAt: 30, recordedAt: 30, accessScope: .user, text: "future")
        let child = BrainEvidence(id: "child", sourceKind: .derived, speakerID: "self:agent", threadID: "t", observedAt: 10, recordedAt: 10, accessScope: .user, text: "derived", parentEvidenceIDs: [root.id])
        _ = try brain.recordEvidence(root, idempotencyKey: "root")
        _ = try brain.recordEvidence(child, idempotencyKey: "child")
        do { _ = try await store.dbQueue.read { try brain.availableEvidence([child.id], asOf: 25, db: $0) }; XCTFail("future ancestry was admitted") } catch {}
        let turns = BrainTurnService(store: store, authorization: auth, extractor: Task12Extractor(), clock: { 20 })
        _ = try turns.recordToolOutcome(id: "lineage", status: .succeeded, recordedAt: 10, evidenceIDs: [child.id], observation: .init(operation: .httpCheck, httpStatus: 200))
        let library = ProcedureLibrary(experience: ExperienceStore(store: store, authorization: auth, authority: Task12ReviewAuthority(), clock: { 20 }))
        let p = try await library.proposeProcedure(sourceOutcomeIDs: ["lineage"])
        XCTAssertThrowsError(try library.validateProcedure(id: p.id, version: p.version, verificationEvidenceIDs: [child.id], environment: "env-a"))
    }

    func test_review_environment_attestations_are_historical_and_independently_revocable() async throws {
        let (store, auth, turns, source) = try await fixture()
        let brain = BrainStore(store: store, authorization: auth, clock: { 40 })
        let proof = BrainEvidence(id: "proof-b", sourceKind: .userMessage, speakerID: "self:user", threadID: "thread-1", observedAt: 25, recordedAt: 25, accessScope: .user, text: "proof")
        _ = try brain.recordEvidence(proof, idempotencyKey: "proof-b")
        _ = try turns.recordToolOutcome(id: "operation", status: .succeeded, recordedAt: 21, evidenceIDs: [source], observation: .init(operation: .httpCheck, httpStatus: 200))
        var now: Double = 22
        let library = ProcedureLibrary(experience: ExperienceStore(store: store, authorization: auth, authority: Task12ReviewAuthority(), clock: { now }))
        let p = try await library.proposeProcedure(sourceOutcomeIDs: ["operation"])
        try library.validateProcedure(id: p.id, version: p.version, verificationEvidenceIDs: [source], environment: "env-a")
        now = 30
        try library.validateProcedure(id: p.id, version: p.version, verificationEvidenceIDs: [proof.id], environment: "env-b")
        XCTAssertEqual(try library.procedures(for: "HTTP", environment: "env-b", asOf: 24).first?.state, .needsRevalidation)
        XCTAssertEqual(try library.procedures(for: "HTTP", environment: "env-a", asOf: 35).first?.state, .validated)
        XCTAssertEqual(try library.procedures(for: "HTTP", environment: "env-b", asOf: 35).first?.state, .validated)
        _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: proof.id), expectedRevision: brain.revision(), operationID: "erase-proof")
        XCTAssertEqual(try library.procedures(for: "HTTP", environment: "env-a", asOf: 35).first?.state, .validated)
        XCTAssertEqual(try library.procedures(for: "HTTP", environment: "env-b", asOf: 35).first?.state, .needsRevalidation)
    }
}

extension Task12ExperienceTests {
    func test_review_legacy_deep_lineage_remains_available_to_generic_reads() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let auth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["t"], sourceSpeakers: [.userMessage: ["self:user"], .derived: ["self:agent"]], mayCommitClaims: true)
        let brain = BrainStore(store: store, authorization: auth, clock: { 30 })
        let root = BrainEvidence(id: "deep-root", sourceKind: .userMessage, speakerID: "self:user", threadID: "t", observedAt: 1, recordedAt: 1, accessScope: .user, text: "source")
        _ = try brain.recordEvidence(root, idempotencyKey: root.id)
        var parent = root.id
        for index in 0..<20 {
            let evidence = BrainEvidence(id: "deep-\(index)", sourceKind: .derived, speakerID: "self:agent", threadID: "t", observedAt: 1, recordedAt: 1, accessScope: .user, text: "derived", parentEvidenceIDs: [parent])
            _ = try brain.recordEvidence(evidence, idempotencyKey: evidence.id)
            parent = evidence.id
        }
        let leafID = parent
        let claim = BrainClaim(id: "deep-claim", revision: 0, subject: "self:user", predicate: "note", value: .string("supported"), modality: .asserted, status: .active, validFrom: 1, recordedAt: 1, evidenceIDs: [leafID])
        _ = try brain.commit(.init(clientOperationID: "deep-commit", evidence: [], updates: [.init(claim: claim)], expectedRevision: 0))
        XCTAssertEqual(try brain.claims(subject: "self:user", asOf: 30, scope: .user).map(\.id), ["deep-claim"])
        let turns = BrainTurnService(store: store, authorization: auth, extractor: Task12Extractor())
        XCTAssertEqual(try turns.recordOutcome(.init(id: "deep-outcome", description: "", status: .succeeded, recordedAt: 2, evidenceIDs: [leafID])).id, "deep-outcome")
        do { _ = try await store.dbQueue.read { try brain.availableEvidence([leafID], asOf: 30, db: $0) }; XCTFail("strict proof accepted excessive depth") } catch {}
    }
}
