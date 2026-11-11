import XCTest
import GRDB
import BrainContract
@testable import MemoryCore

private struct ContextModel: ConversationSummaryModel {
    let body: ([BrainEvidence]) async throws -> ConversationStateCandidate
    func summarize(sources: [BrainEvidence]) async throws -> ConversationStateCandidate { try await body(sources) }
}
private struct ContextSelector: ConversationDetailSelector {
    let body: (ConversationSelectionInput) async throws -> ConversationSelection
    func select(_ input: ConversationSelectionInput) async throws -> ConversationSelection { try await body(input) }
}

final class AdaptiveConversationTests: XCTestCase {
    func auth(_ threads: Set<String> = ["t", "other", "main", "global"]) -> BrainAuthorization {
        BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user, .thread], threads: threads,
            sourceSpeakers: [.userMessage: ["self:user"], .assistantMessage: ["self:agent"], .toolObservation: ["tool:search"]], mayCommitClaims: true, mayForget: true)
    }
    func setup() throws -> (MemoryStore, BrainStore, ConversationStateStore) {
        let db = try MemoryStore(inMemory: true, embeddingDim: 4)
        let brain = BrainStore(store: db, authorization: auth(), clock: { 100 })
        return (db, brain, ConversationStateStore(brain: brain))
    }
    @discardableResult func source(_ brain: BrainStore, _ id: String, _ text: String, _ time: Double = 1,
                                  thread: String = "t", kind: BrainSourceKind = .userMessage, scope: BrainAccessScope = .user) throws -> BrainEvidence {
        let speaker = kind == .assistantMessage ? "self:agent" : kind == .toolObservation ? "tool:search" : "self:user"
        let e = BrainEvidence(id: id, sourceKind: kind, speakerID: speaker, threadID: thread, observedAt: time, recordedAt: time, accessScope: scope, text: kind == .toolObservation ? SafeToolObservation(result: .succeeded, httpStatus: 200).rendered : text)
        return try brain.recordEvidence(e, idempotencyKey: id)
    }
    func request(_ query: String = "sigue", tokens: Int = 12000, thread: String = "t") throws -> BrainContextRequest {
        try BrainContextRequest(clientOperationID: UUID().uuidString, threadID: thread, query: query,
            budget: BrainContextBudget(contextTokens: tokens, outputTokens: 512, systemTokens: 256, toolTokens: 128))
    }
    func statement(_ text: String, _ ids: [String], _ modality: BrainClaimModality = .asserted) -> ConversationStatement {
        ConversationStatement(text: text, evidenceIDs: ids, modality: modality)
    }
    func compact(_ state: ConversationStateStore, through: String, candidate: ConversationStateCandidate) async throws {
        try await ConversationCompactor(store: state, model: ContextModel { _ in candidate }).update(threadID: "t", throughEvidenceID: through)
    }
    func testParkDefaultsToFaithfulGistThenDrillsIntoRawSwingOnlyOnSelection() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "park", "Fui al parque con mi hija. El columpio azul estaba roto.")
        try await compact(state, through: "park", candidate: .init(gist: [statement("Visita al parque con su hija.", ["park"])]))
        try source(brain, "now", "¿Qué hacemos mañana?", 2)
        let normal = try await BrainContextAssembler(store: state).context(request())
        XCTAssertTrue(normal.renderedContext.contains("Visita al parque con su hija."))
        XCTAssertFalse(normal.renderedContext.contains("columpio"))
        XCTAssertFalse(normal.renderedContext.contains("esposa"))
        XCTAssertFalse(normal.recentMessageUnits.contains { $0.evidenceIDs.contains("park") })
        let selector = ContextSelector { _ in .init(detailEvidenceIDs: ["park"]) }
        let detailed = try await BrainContextAssembler(store: state, selector: selector).context(request("¿Y el columpio?"))
        XCTAssertTrue(detailed.renderedContext.contains("El columpio azul estaba roto."))
        XCTAssertTrue(detailed.sourceReferences.contains { $0.id == "park" })
        XCTAssertEqual(detailed.sourceUses?["park"], [.renderedDetail, .derivedSupport])
    }
    func testLiteralQuoteUsesOriginalBytesNeverSummaryParaphrase() async throws {
        let (_, brain, state) = try setup()
        let original = "Dije: «¡Ese columpio, no el otro!» 🛝"
        try source(brain, "quote", original)
        try await compact(state, through: "quote", candidate: .init(gist: [statement("Señaló un columpio.", ["quote"])]))
        try source(brain, "now", "Cita mis palabras.", 2)
        let selector = ContextSelector { _ in .init(quoteEvidenceIDs: ["quote"]) }
        let bundle = try await BrainContextAssembler(store: state, selector: selector).context(request("Cita exactamente"))
        XCTAssertTrue(bundle.renderedContext.contains(original))
        XCTAssertTrue(bundle.renderedContext.contains("original quote"))
    }
    func testQualifiedStateKeepsOldConstraintDecisionAndAmbiguousReferent() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "old", "No reserves nada. Si tuviera una hija iríamos al parque. Elegí el parque norte; ese queda cerca.")
        let c = ConversationStateCandidate(gist: [statement("Iría al parque si tuviera una hija.", ["old"], .hypothetical)],
            subjects: [statement("parque norte", ["old"])], intent: [statement("considerar una salida", ["old"], .proposed)],
            decisions: [statement("Eligió parque norte", ["old"])], constraints: [statement("No reserves nada", ["old"], .negated)],
            openReferents: [statement("ese: parque norte", ["old"])])
        try await compact(state, through: "old", candidate: c)
        try source(brain, "now", "¿Y ese?", 2)
        let bundle = try await BrainContextAssembler(store: state).context(request())
        for text in ["hypothetical", "No reserves nada", "negated", "Eligió parque norte", "ese: parque norte"] {
            XCTAssertTrue(bundle.renderedContext.contains(text), text)
        }
        XCTAssertFalse(bundle.renderedContext.contains("Tiene una hija"))
    }
    func testExplicitToolGroupIsAtomicAndOrphanOrUnknownRolesAreNeverUser() async throws {
        let (db, brain, _) = try setup()
        try source(brain, "call", "Buscar parque", 1, kind: .assistantMessage)
        try source(brain, "result", "Parque abierto", 2, kind: .toolObservation)
        try source(brain, "orphan", "Resultado sin llamada", 3, kind: .toolObservation)
        let state = ConversationStateStore(brain: brain, unitGroups: [.init(id: "tool-round", evidenceIDs: ["call", "result"])])
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        try transcript.append(threadId: "t", turnIndex: 9, role: "mystery", text: "Unattributed secret", now: 9)
        let bundle = try await BrainContextAssembler(store: state).context(request())
        XCTAssertEqual(Set(bundle.recentMessageUnits.flatMap(\.evidenceIDs)), ["call", "result"])
        XCTAssertEqual(Set(bundle.recentMessageUnits.compactMap(\.groupID)), ["tool-round"])
        XCTAssertEqual(bundle.recentMessageUnits.first { $0.evidenceIDs == ["result"] }?.speakerID, "tool:search")
        XCTAssertFalse(bundle.renderedContext.contains("Unattributed secret"))
    }
    func test4096BudgetCountsUTF8WrappersReferencesDuplicatesAndAllReservations() async throws {
        let (_, brain, state) = try setup()
        let huge = String(repeating: "¡niña! 👨‍👩‍👧‍👦 ", count: 1500)
        try source(brain, "large", huge)
        let req = try request("continúa", tokens: 4096)
        let bundle = try await BrainContextAssembler(store: state).context(req)
        let accounting = try XCTUnwrap(bundle.accounting)
        let encoded = try JSONEncoder().encode(bundle).count
        XCTAssertGreaterThanOrEqual(accounting.estimatedInputTokens, encoded + req.query.utf8.count)
        XCTAssertLessThanOrEqual(accounting.estimatedInputTokens + 512 + 256 + 128, 4096)
        let truncation = try XCTUnwrap(bundle.truncations?.first { $0.evidenceID == "large" })
        XCTAssertEqual(truncation.originalUTF8Bytes, huge.utf8.count)
        XCTAssertLessThan(truncation.includedUTF8Bytes, huge.utf8.count)
        let text = try XCTUnwrap(bundle.recentMessageUnits.first?.text)
        XCTAssertTrue(huge.hasPrefix(text))
        XCTAssertEqual(text.utf8.count, truncation.includedUTF8Bytes)
        XCTAssertGreaterThan(truncation.includedUTF8Bytes, 0)
    }
    func testStrictRecentThreadIncludingLegacyMainGlobalAndMissingModelFallback() async throws {
        let (db, _, state) = try setup()
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        for thread in ["main", "global", "other"] {
            try transcript.append(threadId: thread, turnIndex: 1, role: "user", text: "only-" + thread, now: 1)
        }
        for thread in ["main", "global"] {
            let bundle = try await BrainContextAssembler(store: state).context(request(thread: thread))
            XCTAssertEqual(bundle.recentMessageUnits.map(\.text), ["only-" + thread])
            XCTAssertTrue(bundle.sourceReferences.allSatisfy { $0.threadID == thread })
        }
        try await ConversationCompactor(store: state, model: nil).update(threadID: "main", throughEvidenceID: "unused")
        XCTAssertTrue(try state.snapshot(threadID: "main").segments.isEmpty)
        do { _ = try await BrainContextAssembler(store: state).context(request(thread: "")); XCTFail("empty thread allowed") }
        catch { XCTAssertEqual(error as? BrainStoreError, .denied) }
    }
    func testIncrementalCompactionReadsRawOnlyAndDoesNotSummarizeItsOwnSummary() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "one", "Original one")
        try await compact(state, through: "one", candidate: .init(gist: [statement("Derived first gist", ["one"])]))
        try source(brain, "two", "Original two", 2)
        let model = ContextModel { sources in
            XCTAssertEqual(sources.map(\.text), ["Original two"])
            return .init(gist: [.init(text: "Second gist", evidenceIDs: ["two"], modality: .asserted)])
        }
        try await ConversationCompactor(store: state, model: model).update(threadID: "t", throughEvidenceID: "two")
        XCTAssertEqual(try state.snapshot(threadID: "t").segments.count, 2)
        try await ConversationCompactor(store: state, model: model).update(threadID: "t", throughEvidenceID: "two")
        XCTAssertEqual(try state.snapshot(threadID: "t").segments.count, 2)
    }
    func testForgetPurgesDerivedPayloadImmediatelyAndInflightSummaryCannotResurrectIt() async throws {
        let (db, brain, state) = try setup()
        try source(brain, "x", "Private park")
        try await compact(state, through: "x", candidate: .init(gist: [statement("Private derived gist", ["x"])]))
        let model = ContextModel { _ in
            try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: "x"), expectedRevision: brain.revision(), operationID: "forget")
            return .init(gist: [.init(text: "Must never return", evidenceIDs: ["y"], modality: .asserted)])
        }
        try source(brain, "y", "Second private source", 2)
        do { try await ConversationCompactor(store: state, model: model).update(threadID: "t", throughEvidenceID: "y"); XCTFail("stale summary persisted") }
        catch { XCTAssertEqual(error as? BrainStoreError, .conflict) }
        let count = try countSegments(db)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try state.snapshot(threadID: "t").segments.isEmpty)
    }
    func countSegments(_ db: MemoryStore) throws -> Int {
        try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM brain_conversation_segment") ?? -1 }
    }
    func testRawTranscriptCorrectionInvalidatesStateWithoutBrainRevisionChange() async throws {
        let (db, _, state) = try setup()
        let id = try TranscriptStore(dbQueue: db.dbQueue).append(threadId: "t", turnIndex: 1, role: "user", text: "Original park", now: 1)
        let sourceID = try XCTUnwrap(state.snapshot(threadID: "t").sources.first?.evidence.id)
        try await compact(state, through: sourceID, candidate: .init(gist: [statement("Old park gist", [sourceID])]))
        try correctTranscript(db, id: id)
        XCTAssertTrue(try state.snapshot(threadID: "t").segments.isEmpty)
        XCTAssertEqual(try countSegments(db), 0)
        let bundle = try await BrainContextAssembler(store: state).context(request())
        XCTAssertFalse(bundle.renderedContext.contains("Old park gist"))
        XCTAssertEqual(bundle.recentMessageUnits.map(\.text), ["Corrected park"])
    }
    func correctTranscript(_ db: MemoryStore, id: String) throws {
        try db.dbQueue.write { try $0.execute(sql: "UPDATE transcript SET text='Corrected park' WHERE id=?", arguments: [id]) }
    }
    func testSelectorAfterForgetCannotReturnStaleOriginalAndRejectsForeignIDs() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "x", "Private original")
        let selector = ContextSelector { _ in
            try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: "x"), expectedRevision: brain.revision(), operationID: "forget")
            return .init(quoteEvidenceIDs: ["x"])
        }
        do { _ = try await BrainContextAssembler(store: state, selector: selector).context(request()); XCTFail("stale quote returned") }
        catch { XCTAssertEqual(error as? BrainStoreError, .conflict) }
        try source(brain, "foreign", "Other chat raw", 2, thread: "other")
        let foreign = ContextSelector { _ in .init(detailEvidenceIDs: ["foreign"]) }
        do { _ = try await BrainContextAssembler(store: state, selector: foreign).context(request()); XCTFail("foreign detail allowed") }
        catch { XCTAssertEqual(error as? BrainStoreError, .denied) }
    }
    func testUserMemoryCanCrossChatsButThreadPrivateMemoryCannot() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "shared", "No peanuts", 1, thread: "other")
        try source(brain, "private", "Private other constraint", 2, thread: "other", scope: .thread)
        let shared = BrainClaim(id: "allergy", revision: 0, subject: "self:user", predicate: "constraint", value: .string("No peanuts"), modality: .negated, status: .active, validFrom: 1, recordedAt: 1, evidenceIDs: ["shared"])
        let hidden = BrainClaim(id: "hidden", revision: 0, subject: "self:user", predicate: "constraint", value: .string("Private other constraint"), modality: .asserted, status: .active, validFrom: 2, recordedAt: 2, evidenceIDs: ["private"])
        _ = try brain.commit(BrainCommitRequest(clientOperationID: "claims", evidence: [], updates: [.init(claim: shared), .init(claim: hidden)], expectedRevision: 0))
        let reader = ConversationStateStore(brain: BrainStore(store: state.brain.store, authorization: auth(["t"]), clock: { 100 }))
        let selector = ContextSelector { input in
            XCTAssertEqual(input.claims.map(\.id), ["allergy"])
            return .init(claimIDs: ["allergy"])
        }
        let bundle = try await BrainContextAssembler(store: reader, selector: selector).context(request())
        XCTAssertTrue(bundle.renderedContext.contains("No peanuts"))
        XCTAssertTrue(bundle.sourceReferences.contains { $0.id == "shared" })
        XCTAssertEqual(bundle.sourceUses?["shared"], [.derivedSupport])
        XCTAssertTrue(bundle.exactCitationSourceReferences(includingRenderedContext: true, forwardedRecentUnitIDs: []).isEmpty)
        XCTAssertFalse(bundle.renderedContext.contains("Private other constraint"))
    }
    func testMalformedSummaryCannotPersistInventedSource() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "x", "Real source")
        do {
            try await compact(state, through: "x", candidate: .init(gist: [statement("Invented", ["nonexistent"])]))
            XCTFail("fabricated provenance stored")
        } catch { XCTAssertEqual(error as? BrainStoreError, .invalid) }
        XCTAssertTrue(try state.snapshot(threadID: "t").segments.isEmpty)
    }
    func testNewAndEmptyCommitsRetainExistingIncrementalSegments() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "old", "Existing context")
        try await compact(state, through: "old", candidate: .init(gist: [statement("Existing gist", ["old"])]))
        let empty = try BrainCommitRequest(clientOperationID: "empty", evidence: [], updates: [], expectedRevision: 0)
        XCTAssertEqual(try brain.commit(empty).state, .committed)
        XCTAssertEqual(try state.snapshot(threadID: "t").segments.count, 1)
        try source(brain, "new", "New unrelated preference", 2)
        let claim = BrainClaim(id: "new-claim", revision: 0, subject: "self:user", predicate: "preference", value: .string("tea"), modality: .asserted, status: .active, validFrom: 2, recordedAt: 2, evidenceIDs: ["new"])
        _ = try brain.commit(BrainCommitRequest(clientOperationID: "new", evidence: [], updates: [.init(claim: claim)], expectedRevision: 1))
        let snapshot = try state.snapshot(threadID: "t")
        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(snapshot.segments.first?.revision, 0)
        XCTAssertEqual(snapshot.revision, 2)
    }
    func testExplicitClaimCorrectionInvalidatesOnlyItsDependentSegment() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "old", "I prefer blue")
        let old = BrainClaim(id: "blue", revision: 0, subject: "self:user", predicate: "color", value: .string("blue"), modality: .asserted, status: .active, validFrom: 1, recordedAt: 1, evidenceIDs: ["old"])
        _ = try brain.commit(BrainCommitRequest(clientOperationID: "old", evidence: [], updates: [.init(claim: old)], expectedRevision: 0))
        try await compact(state, through: "old", candidate: .init(gist: [statement("Prefers blue", ["old"])]))
        try source(brain, "other", "Walk in the park", 2)
        try await compact(state, through: "other", candidate: .init(gist: [statement("Park visit", ["other"])]))
        try source(brain, "new", "Correction: red", 3)
        let new = BrainClaim(id: "red", revision: 0, subject: "self:user", predicate: "color", value: .string("red"), modality: .asserted, status: .active, validFrom: 3, recordedAt: 3, evidenceIDs: ["new"], supersedesID: "blue")
        _ = try brain.commit(BrainCommitRequest(clientOperationID: "correction", evidence: [], updates: [.init(claim: new)], expectedRevision: 1))
        let snapshot = try state.snapshot(threadID: "t")
        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(snapshot.segments.first?.state.gist.first?.text, "Park visit")
    }

    func testBudgetPressurePreservesOldConstraintAndReferentBeforeOversizedRecentText() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "old", "No reserves. Ese es el parque norte.")
        try await compact(state, through: "old", candidate: .init(
            constraints: [statement("No reserves", ["old"], .negated)],
            openReferents: [statement("ese: parque norte", ["old"])]))
        try source(brain, "new", String(repeating: "Más información 🛝 ", count: 1000), 2)
        let bundle = try await BrainContextAssembler(store: state).context(request(tokens: 4096))
        XCTAssertTrue(bundle.renderedContext.contains("No reserves"))
        XCTAssertTrue(bundle.renderedContext.contains("ese: parque norte"))
        XCTAssertFalse(bundle.recentMessageUnits.isEmpty)
        XCTAssertLessThanOrEqual(try XCTUnwrap(bundle.accounting).estimatedInputTokens + 896, 4096)
    }
    func testExtendingDurableTurnInvalidatesPartialSegmentAndRebuildsFromBothOriginals() async throws {
        let (db, _, state) = try setup()
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        try transcript.append(threadId: "t", turnIndex: 1, role: "user", text: "Busca el parque", now: 1)
        let first = try XCTUnwrap(state.snapshot(threadID: "t").sources.first?.evidence.id)
        try await compact(state, through: first, candidate: .init(gist: [statement("Requested search", [first])]))
        try transcript.append(threadId: "t", turnIndex: 1, role: "assistant", text: "Encontré el parque", now: 2)
        let snapshot = try state.snapshot(threadID: "t")
        XCTAssertTrue(snapshot.segments.isEmpty)
        let last = try XCTUnwrap(snapshot.sources.last?.evidence.id)
        let model = ContextModel { originals in
            XCTAssertEqual(originals.map(\.text), ["Busca el parque", "Encontré el parque"])
            return .init(gist: [.init(text: "Search answered", evidenceIDs: originals.map(\.id), modality: .asserted)])
        }
        try await ConversationCompactor(store: state, model: model).update(threadID: "t", throughEvidenceID: last)
        XCTAssertEqual(try state.snapshot(threadID: "t").segments.first?.sources.count, 2)
    }
    func testModelInputsAreBoundedAndOversizedCompactionFallsBackToRaw() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "oversized", String(repeating: "original 🛝 ", count: 1500))
        let model = ContextModel { _ in XCTFail("oversized raw was sent to model"); return .init() }
        let modelBudget = try BrainContextBudget(contextTokens: 1024, outputTokens: 256, systemTokens: 256)
        try await ConversationCompactor(store: state, model: model, modelBudget: modelBudget).update(threadID: "t", throughEvidenceID: "oversized")
        XCTAssertTrue(try state.snapshot(threadID: "t").segments.isEmpty)
        let selector = ContextSelector { input in
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(input).count + 64 + 896, 4096)
            XCTAssertTrue(input.sourceReferences.allSatisfy { $0.text == nil })
            throw BrainStoreError.unimplemented
        }
        let bundle = try await BrainContextAssembler(store: state, selector: selector).context(request(tokens: 4096))
        XCTAssertFalse(bundle.recentMessageUnits.isEmpty)
        XCTAssertNotNil(bundle.truncations?.first)
    }
    func testOversizedQueryCannotBeMisreportedAsFittingAndQuoteOmissionIsExplicit() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "large", String(repeating: "Original largo ", count: 1000))
        do {
            _ = try await BrainContextAssembler(store: state).context(request(String(repeating: "x", count: 5000), tokens: 4096))
            XCTFail("oversized mandatory query claimed fit")
        } catch { XCTAssertEqual(error as? BrainContextAssemblyError, .insufficientBudget) }
        let selector = ContextSelector { _ in .init(quoteEvidenceIDs: ["large"]) }
        let bundle = try await BrainContextAssembler(store: state, selector: selector).context(request(tokens: 4096))
        XCTAssertFalse(bundle.renderedContext.contains("original quote"))
        XCTAssertTrue(bundle.truncations?.contains { $0.evidenceID == "large" && $0.reason == "quoteOmittedBudget" && $0.includedUTF8Bytes == 0 } == true)
    }

    func testExistingPrivateEvidenceScopeCannotBeBypassedThroughTranscriptAdaptation() async throws {
        let (db, brain, _) = try setup()
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        try transcript.append(threadId: "t", turnIndex: 1, role: "user", text: "Private scoped source", now: 1)
        let row = try XCTUnwrap(transcript.range(threadId: "t", from: 1, to: 1).first)
        let privateEvidence = try XCTUnwrap(ConsolidationEvidenceAdapter.evidence(for: row, scope: .thread))
        _ = try brain.recordEvidence(privateEvidence, idempotencyKey: "private-canonical")
        let userOnly = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["t"], sourceSpeakers: [:])
        let reader = ConversationStateStore(brain: BrainStore(store: db, authorization: userOnly))
        let bundle = try await BrainContextAssembler(store: reader).context(request())
        XCTAssertTrue(bundle.recentMessageUnits.isEmpty)
        XCTAssertTrue(bundle.sourceReferences.isEmpty)
    }

    func testLegacyOnlyShortOriginalCanBeForgottenByReturnedEvidenceID() async throws {
        let (db, brain, state) = try setup()
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        let rowID = try transcript.append(threadId: "t", turnIndex: 1, role: "user", text: "Sí", now: 1)
        let bundle = try await BrainContextAssembler(store: state).context(request())
        let evidenceID = try XCTUnwrap(bundle.sourceReferences.first?.id)
        try await compact(state, through: evidenceID, candidate: .init(gist: [statement("Derived short answer", [evidenceID])]))
        do {
            let receipt = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: evidenceID), expectedRevision: brain.revision(), operationID: "forget-legacy")
            XCTAssertTrue(receipt.forgottenEvidenceIDs.contains(evidenceID))
            XCTAssertTrue(receipt.affectedIDs?.contains(rowID) == true)
        } catch { XCTFail("Returned original cannot be forgotten: \(error)") }
        XCTAssertTrue(try transcript.rows(ids: [rowID]).isEmpty)
        XCTAssertEqual(try countSegments(db), 0)
        XCTAssertTrue(try state.snapshot(threadID: "t").sources.isEmpty)
    }
    func testPersistedCanonicalCopyCannotReintroduceCorrectedTranscriptText() async throws {
        let (db, brain, state) = try setup()
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        let rowID = try transcript.append(threadId: "t", turnIndex: 1, role: "user", text: "Original park", now: 1)
        let row = try XCTUnwrap(transcript.rows(ids: [rowID]).first)
        let evidence = try XCTUnwrap(ConsolidationEvidenceAdapter.evidence(for: row))
        _ = try brain.recordEvidence(evidence, idempotencyKey: "stored-original")
        try await compact(state, through: evidence.id, candidate: .init(gist: [statement("Old park gist", [evidence.id])]))
        try correctTranscript(db, id: rowID)
        let bundle = try await BrainContextAssembler(store: state).context(request())
        XCTAssertEqual(bundle.recentMessageUnits.map(\.text), ["Corrected park"])
        XCTAssertFalse(bundle.sourceReferences.contains { $0.id == evidence.id })
        XCTAssertFalse(bundle.renderedContext.contains("Old park gist"))
    }
    func testCanonicalForgetFallbackCannotBypassPersistedScopeOrUnknownRole() throws {
        let (db, brain, _) = try setup()
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        let rowID = try transcript.append(threadId: "t", turnIndex: 1, role: "user", text: "Sí", now: 1)
        let row = try XCTUnwrap(transcript.rows(ids: [rowID]).first)
        let evidence = try XCTUnwrap(ConsolidationEvidenceAdapter.evidence(for: row, scope: .thread))
        _ = try brain.recordEvidence(evidence, idempotencyKey: "private-forget")
        let userOnly = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["t"], sourceSpeakers: [:], mayForget: true)
        let reader = BrainStore(store: db, authorization: userOnly)
        XCTAssertThrowsError(try BrainRetractionService(brain: reader).forget(scope: .init(kind: .evidence, id: evidence.id), expectedRevision: 0, operationID: "private")) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
        let unknownID = try transcript.append(threadId: "t", turnIndex: 2, role: "unknown", text: "mystery", now: 2)
        let unknown = try XCTUnwrap(transcript.rows(ids: [unknownID]).first)
        XCTAssertThrowsError(try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: ConsolidationEvidenceAdapter.evidenceID(for: unknown)), expectedRevision: 0, operationID: "unknown"))
        XCTAssertEqual(try transcript.count(), 2)
    }

    func testLegacyCapturedOperationRemainsReplayableAfterBudgetContractExtension() throws {
        let (db, brain, _) = try setup()
        // Literal sorted JSON produced by the pre-Task8 request contract, without new fields.
        let legacy = #"{"budget":{"contextTokens":4096,"outputTokens":512},"clientOperationID":"legacy-operation","message":{"evidenceIDs":[],"id":"legacy-message","observedAt":10,"speakerID":"self:user","text":"hola"},"schemaVersion":1,"threadID":"t"}"#
        let request = try JSONDecoder().decode(BrainTurnRequest.self, from: Data(legacy.utf8))
        let journal = BrainTurnStore(brain: brain)
        let originalID = try journal.capture(request)
        try db.dbQueue.write { db in
            try db.execute(sql: "UPDATE brain_turn_operation SET request_hash=? WHERE namespace='begin' AND operation_hash=?",
                           arguments: [BrainStore.digest(legacy), try BrainTurnStore.key("legacy-operation")])
        }
        do {
            let replayID = try journal.capture(request)
            XCTAssertEqual(replayID, originalID)
        } catch { XCTFail("Legacy operation replay rejected: \(error)") }
        XCTAssertEqual(try TranscriptStore(dbQueue: db.dbQueue).count(), 1)
        let changed = try BrainTurnRequest(clientOperationID: request.clientOperationID, threadID: "t", message: request.message,
                                          budget: .init(contextTokens: 4096, outputTokens: 512, systemTokens: 256))
        XCTAssertThrowsError(try journal.capture(changed)) { XCTAssertEqual($0 as? BrainStoreError, .conflict) }
    }

    func testSelectedOriginalOmissionMustThrowWhenMandatoryDisclosureCannotFit() async throws {
        let (_, brain, state) = try setup()
        let probe = try await BrainContextAssembler(store: state).context(request("q", tokens: 4096))
        let envelope = try XCTUnwrap(probe.accounting).estimatedInputTokens
        // Leave only 32 bytes beyond a fitting mandatory query/envelope, less than a disclosure.
        let query = String(repeating: "q", count: 3200 - envelope + 1 - 32)
        try source(brain, "large", String(repeating: "Original ", count: 1000))
        for quote in [true, false] {
            let selector = ContextSelector { _ in
                quote ? .init(quoteEvidenceIDs: ["large"]) : .init(detailEvidenceIDs: ["large"])
            }
            do {
                _ = try await BrainContextAssembler(store: state, selector: selector).context(request(query, tokens: 4096))
                XCTFail("Returned success without space for required original-omission disclosure")
            } catch { XCTAssertEqual(error as? BrainContextAssemblyError, .insufficientBudget) }
        }
    }
    func testEveryRequestedQuoteRemainsExactOrExplicitlyOmittedWhenEarlierQuotesConsumeBudget() async throws {
        for length in stride(from: 2000, through: 3000, by: 50) {
            let (_, brain, state) = try setup()
            let first = String(repeating: "a", count: length), second = String(repeating: "b", count: 10000)
            try source(brain, "first", first, 1)
            try source(brain, "second", second, 2)
            let selector = ContextSelector { _ in .init(quoteEvidenceIDs: ["first", "second"]) }
            let bundle = try await BrainContextAssembler(store: state, selector: selector).context(request(tokens: 4096))
            var omitted = [String: Int]()
            for (id, original) in [("first", first), ("second", second)] {
                let header = "[original quote source=\(id)]\n"
                let full = bundle.renderedContext.contains(header + original)
                XCTAssertEqual(bundle.renderedContext.contains(header), full, "Partial quote for \(id)")
                XCTAssertEqual(bundle.sourceUses?[id]?.contains(.renderedQuote) == true, full)
                if !full { omitted[id] = original.utf8.count }
            }
            let truncations = bundle.truncations ?? []
            let resolved = Set(bundle.sourceReferences.map(\.id))
            XCTAssertTrue(Set(truncations.compactMap(\.evidenceID)).isSubset(of: resolved))
            let notices = truncations.filter { $0.reason == "quoteOmittedBudget" }
            let aggregates = notices.filter { $0.evidenceID == nil }
            XCTAssertLessThanOrEqual(aggregates.count, 1)
            for notice in notices {
                XCTAssertEqual(notice.includedUTF8Bytes, 0)
                if let id = notice.evidenceID {
                    XCTAssertNil(notice.omittedEvidenceCount)
                    XCTAssertEqual(omitted.removeValue(forKey: id), notice.originalUTF8Bytes,
                                   "Unexpected quote omission for \(id), first length \(length)")
                }
            }
            if let aggregate = aggregates.first {
                XCTAssertFalse(omitted.isEmpty)
                XCTAssertEqual(aggregate.omittedEvidenceCount, omitted.count)
                XCTAssertEqual(aggregate.originalUTF8Bytes, omitted.values.reduce(0, +))
            } else {
                XCTAssertTrue(omitted.isEmpty, "Missing quote omissions at first length \(length)")
            }
            if length == 2000 {
                XCTAssertEqual(notices.map(\.evidenceID), ["second"], "Roomy quote omission should name the source")
            }
            XCTAssertLessThanOrEqual(try XCTUnwrap(bundle.accounting).estimatedInputTokens + 896, 4096)
        }
    }
    func testSelectedOriginalsUseBoundedDisclosureFloor() async throws {
        let (_, brain, state) = try setup()
        let ids = (0..<20).map { String(format: "selected-%02d", $0) }
        let exact = "Cita exacta: ¡sí! 🛝"
        let long = String(repeating: "x", count: 6000)
        for (index, id) in ids.enumerated() {
            try source(brain, id, index == 0 ? exact : long, Double(index + 1))
        }
        try source(brain, "newest", "Seguimos aquí.", 21)
        let selector = ContextSelector { input in
            XCTAssertTrue(Set(ids).isSubset(of: Set(input.sourceReferences.map(\.id))))
            return .init(detailEvidenceIDs: Array(ids.dropFirst(11)), quoteEvidenceIDs: Array(ids.prefix(11)))
        }
        let req = try request("cita", tokens: 4096)
        let bundle: BrainContextBundle
        do {
            bundle = try await BrainContextAssembler(store: state, selector: selector).context(req)
        } catch BrainContextAssemblyError.insufficientBudget {
            return XCTFail("3200 input tokens should fit bounded omissions for 20 selected originals")
        }
        XCTAssertTrue(bundle.renderedContext.contains("[original quote source=selected-00]\n" + exact))
        XCTAssertTrue(bundle.recentMessageUnits.contains { $0.id == "newest" && $0.text == "Seguimos aquí." })
        let truncations = try XCTUnwrap(bundle.truncations)
        let quote = try XCTUnwrap(truncations.first { $0.reason == "quoteOmittedBudget" && $0.evidenceID == nil })
        XCTAssertEqual(quote.originalUTF8Bytes, 60_000)
        XCTAssertEqual(quote.omittedEvidenceCount, 10)
        let details = truncations.filter { $0.reason == "detailOmittedBudget" }
        XCTAssertEqual(details.reduce(0) { $0 + $1.originalUTF8Bytes }, 54_000)
        XCTAssertEqual(details.reduce(0) { $0 + ($1.omittedEvidenceCount ?? 1) }, 9)
        let resolved = Set(bundle.sourceReferences.map(\.id))
        XCTAssertTrue(Set(truncations.compactMap(\.evidenceID)).isSubset(of: resolved))
        let encoded = try JSONEncoder().encode(bundle)
        let estimate = try XCTUnwrap(bundle.accounting).estimatedInputTokens
        XCTAssertGreaterThanOrEqual(estimate, encoded.count + req.query.utf8.count + 64)
        XCTAssertLessThanOrEqual(estimate, 3200)
    }

    func testBundleWireDistinguishesOriginalFromGistSupport() async throws {
        let (_, brain, state) = try setup()
        try source(brain, "park", "El columpio azul estaba roto.")
        try await compact(state, through: "park", candidate: .init(gist: [statement("Visitó el parque.", ["park"])]))
        try source(brain, "now", "¿Cómo sigue?", 2)
        let bundle = try await BrainContextAssembler(store: state).context(request())
        XCTAssertTrue(bundle.renderedContext.contains("Visitó el parque."))
        XCTAssertTrue(bundle.sourceReferences.contains { $0.id == "park" })
        let decoded = try JSONDecoder().decode(BrainContextBundle.self, from: JSONEncoder().encode(bundle))
        XCTAssertEqual(decoded.sourceUses?["park"], [.derivedSupport])
        XCTAssertEqual(decoded.sourceUses?["now"], [.recentWhole])
        XCTAssertEqual(decoded.exactCitationSourceReferences(includingRenderedContext: false, forwardedRecentUnitIDs: ["now"]).map(\.id), ["now"])
    }

    func testMixedOriginalsShareChronologyForRecentContextAndCompactionPrefix() async throws {
        let (db, brain, state) = try setup()
        try source(brain, "earlier", "Earlier persisted original", 1)
        try TranscriptStore(dbQueue: db.dbQueue).append(threadId: "t", turnIndex: 1, role: "user", text: "Later transcript turn", now: 2)
        let snapshot = try state.snapshot(threadID: "t")
        XCTAssertEqual(snapshot.sources.map { $0.evidence.text }, ["Earlier persisted original", "Later transcript turn"])
        let latest = try XCTUnwrap(snapshot.sources.first { $0.evidence.text == "Later transcript turn" }?.evidence.id)
        let bundle = try await BrainContextAssembler(store: state).context(request())
        XCTAssertEqual(bundle.recentMessageUnits.map(\.text), ["Earlier persisted original", "Later transcript turn"])
        let model = ContextModel { originals in
            XCTAssertEqual(originals.map(\.text), ["Earlier persisted original", "Later transcript turn"])
            return .init(gist: [.init(text: "Ordered conversation", evidenceIDs: originals.map(\.id), modality: .asserted)])
        }
        try await ConversationCompactor(store: state, model: model).update(threadID: "t", throughEvidenceID: latest)
        XCTAssertEqual(try state.snapshot(threadID: "t").segments.first?.sources.count, 2)
    }
    func testOlderLargePersistedOriginalCannotDisplaceActualNewestTranscriptTurn() async throws {
        let (db, brain, state) = try setup()
        try source(brain, "earlier", String(repeating: "Old original ", count: 1000), 1)
        try TranscriptStore(dbQueue: db.dbQueue).append(threadId: "t", turnIndex: 1, role: "user", text: "Newest user turn", now: 2)
        let bundle = try await BrainContextAssembler(store: state).context(request(tokens: 4096))
        XCTAssertEqual(bundle.recentMessageUnits.last?.text, "Newest user turn")
        XCTAssertEqual(bundle.recentMessageUnits.last?.observedAt, 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(bundle.accounting).estimatedInputTokens + 896, 4096)
    }
    func testEqualTimestampTimelineRetainsTranscriptSequenceBeforeStableUnsequencedTie() async throws {
        let (db, brain, state) = try setup()
        let transcript = TranscriptStore(dbQueue: db.dbQueue)
        for (turn, role, text) in [(1, "user", "user one"), (1, "assistant", "assistant one"),
                                   (2, "user", "user two"), (2, "assistant", "assistant two")] {
            try transcript.append(threadId: "t", turnIndex: turn, role: role, text: text, now: 5)
        }
        try source(brain, "unsequenced", "unsequenced", 5)
        XCTAssertEqual(try state.snapshot(threadID: "t").sources.map { $0.evidence.text },
                       ["user one", "assistant one", "user two", "assistant two", "unsequenced"])
    }

}
