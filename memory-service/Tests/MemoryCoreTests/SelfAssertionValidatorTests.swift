import XCTest
import BrainContract
@testable import MemoryCore

/// The user's identity may only be written from the user asserting it. These cases are the ones a
/// model gets wrong: it paraphrases, it repeats what somebody else said, it takes a hypothetical
/// literally, or it answers with the agent's own name.
final class SelfAssertionValidatorTests: XCTestCase {

    private func row(_ role: String, _ text: String, seq: Int = 1) -> TranscriptRow {
        TranscriptRow(id: "r\(seq)", threadId: "T", turnIndex: seq, seq: seq, role: role,
                      text: text, createdAt: 1_000, consolidated: false)
    }

    private func validate(_ label: String, _ rows: [TranscriptRow],
                          scopes: Set<BrainAccessScope> = [.user],
                          evidenceScope: BrainAccessScope = .user) -> Result<SelfAssertionSupport, SelfAssertionRejection> {
        SelfAssertionValidator.validate(label: label, sources: rows,
                                        permittedScopes: scopes, evidenceScope: evidenceScope)
    }

    private func rejection(_ result: Result<SelfAssertionSupport, SelfAssertionRejection>) -> SelfAssertionRejection? {
        if case .failure(let r) = result { return r }
        return nil
    }

    func test_acceptsUserAssertingTheirOwnName() throws {
        let result = validate("Roilan", [row("user", "me llamo Roilan")])
        let support = try XCTUnwrap(try? result.get())
        XCTAssertEqual(support.rowID, "r1")
        XCTAssertEqual(support.seq, 1)
        XCTAssertEqual(support.evidenceID,
                       ConsolidationEvidenceAdapter.evidenceID(threadID: "T", seq: 1, text: "me llamo Roilan"))
    }

    func test_acceptsEnglishAndAccentInsensitiveNamings() {
        XCTAssertNotNil(try? validate("Roilan", [row("user", "Hi, my name is Roilan")]).get())
        XCTAssertNotNil(try? validate("Jose", [row("user", "me llamo José")]).get())
        // A copular self-description is not a naming, even when the label really is the name:
        // this path writes the `name` predicate, so it accepts only explicit namings.
        XCTAssertEqual(rejection(validate("Jose", [row("user", "yo soy José")])), .notANameAssertion)
    }

    func test_rejectsStatementOnlyTheAgentMade() {
        XCTAssertEqual(rejection(validate("Roilan", [row("assistant", "you are Roilan, right?")])),
                       .noUserSource)
    }

    func test_rejectsModelParaphraseAbsentFromTheSource() {
        XCTAssertEqual(rejection(validate("Stubborn", [row("user", "mi esposa dice que soy terco")])),
                       .noUserSource)
    }

    func test_rejectsThirdPartyAttribution() {
        XCTAssertEqual(rejection(validate("terco", [row("user", "mi esposa dice que soy terco")])),
                       .thirdPartyAttributed)
    }

    func test_rejectsQuotedAssertion() {
        XCTAssertEqual(rejection(validate("Roilan", [row("user", "\"me llamo Roilan\" es lo que puse en el formulario")])),
                       .quoted)
    }

    func test_rejectsNegatedAssertion() {
        XCTAssertEqual(rejection(validate("Roilan", [row("user", "no me llamo Roilan")])), .negated)
    }

    func test_rejectsHypotheticalAssertion() {
        XCTAssertEqual(rejection(validate("Roilan", [row("user", "si me llamo Roilan en el juego, ¿me crees?")])),
                       .hypothetical)
    }

    func test_rejectsExplicitlyDisavowedAssertion() {
        XCTAssertEqual(rejection(validate("Roilan", [row("user", "me llamo Roilan, es broma")])),
                       .sarcasmMarked)
    }

    func test_rejectsMentionThatIsNotAFirstPersonAssertion() {
        XCTAssertEqual(rejection(validate("Roilan", [row("user", "Roilan es el nombre de mi primo")])),
                       .notFirstPersonAssertion)
    }

    func test_rejectsAgentAndStructuralIdentitiesByLabel() {
        for label in ["Gemma", "assistant", "agente", "usuario", "self"] {
            XCTAssertEqual(rejection(validate(label, [row("user", "me llamo \(label)")])), .reservedSubject,
                           "\(label) names the agent or a structural identity, never the user")
        }
    }

    func test_rejectsWhenTheScopeDoesNotPermitIdentity() {
        XCTAssertEqual(rejection(validate("Roilan", [row("user", "me llamo Roilan")], scopes: [.thread])),
                       .scopeNotPermitted)
        XCTAssertEqual(rejection(validate("Roilan", [row("user", "me llamo Roilan")], evidenceScope: .agent)),
                       .scopeNotPermitted)
        XCTAssertEqual(rejection(validate("Roilan", [row("user", "me llamo Roilan")], evidenceScope: .shared)),
                       .scopeNotPermitted)
    }

    func test_rejectsEmptyProposal() {
        XCTAssertEqual(rejection(validate("   ", [row("user", "me llamo Roilan")])), .emptyStatement)
    }

    func test_prefersTheMostRecentAssertingTurn() throws {
        let rows = [row("user", "no me llamo Juan", seq: 1), row("user", "me llamo Roilan", seq: 2)]
        let support = try XCTUnwrap(try? validate("Roilan", rows).get())
        XCTAssertEqual(support.seq, 2)
    }
}

/// The adapter never guesses who spoke, and the same row always adapts to the same record.
final class ConsolidationEvidenceAdapterTests: XCTestCase {

    private func row(_ role: String, _ text: String, seq: Int = 1, thread: String = "T") -> TranscriptRow {
        TranscriptRow(id: "r\(seq)", threadId: thread, turnIndex: seq, seq: seq, role: role,
                      text: text, createdAt: 1_000, consolidated: false)
    }

    func test_evidenceIDIsDerivedFromThreadSeqAndText() {
        let id = ConsolidationEvidenceAdapter.evidenceID(threadID: "T", seq: 2, text: "hola")
        XCTAssertEqual(id, ConsolidationEvidenceAdapter.evidenceID(threadID: "T", seq: 2, text: "hola"))
        XCTAssertNotEqual(id, ConsolidationEvidenceAdapter.evidenceID(threadID: "T", seq: 2, text: "hola!"))
        XCTAssertNotEqual(id, ConsolidationEvidenceAdapter.evidenceID(threadID: "T", seq: 3, text: "hola"))
        XCTAssertNotEqual(id, ConsolidationEvidenceAdapter.evidenceID(threadID: "U", seq: 2, text: "hola"))
    }

    func test_speakerComesFromTheRoleOrNotAtAll() {
        XCTAssertEqual(ConsolidationEvidenceAdapter.speaker(role: "user"), .user)
        XCTAssertEqual(ConsolidationEvidenceAdapter.speaker(role: "Assistant"), .agent)
        for unknown in ["tool", "system", "", "narrator"] {
            XCTAssertNil(ConsolidationEvidenceAdapter.speaker(role: unknown),
                         "an unrecognised role must not be attributed to anyone")
        }
    }

    func test_unattributableOrEmptyRowsYieldNoEvidence() {
        XCTAssertNil(ConsolidationEvidenceAdapter.evidence(for: row("tool", "results")))
        XCTAssertNil(ConsolidationEvidenceAdapter.evidence(for: row("user", "   ")))
    }

    func test_evidenceCarriesTheRecordedSpeakerAndIsByteStable() throws {
        let evidence = try XCTUnwrap(ConsolidationEvidenceAdapter.evidence(for: row("user", "hola")))
        XCTAssertEqual(evidence.speakerID, selfUserID)
        XCTAssertEqual(evidence.sourceKind, BrainSourceKind.userMessage)
        XCTAssertEqual(evidence.observedAt, 1_000, "observed when the turn was spoken")
        XCTAssertEqual(evidence.recordedAt, 1_000,
                       "the transcript row IS the record, so its own createdAt is when it was recorded")
        XCTAssertNil(evidence.parentEvidenceIDs, "a raw turn is a root, not a derived observation")
        // Byte stability is what lets a claim carry its own evidence without colliding with the
        // copy an earlier cycle stored.
        XCTAssertEqual(evidence, ConsolidationEvidenceAdapter.evidence(for: row("user", "hola")))
    }

    func test_authorizationIsNarrowAndNeverGrantsErasure() {
        let auth = ConsolidationEvidenceAdapter.authorization(threads: ["T"])
        XCTAssertFalse(auth.mayForget, "a sleep cycle never grants itself erasure")
        XCTAssertFalse(auth.mayProject)
        XCTAssertFalse(auth.allowDelegated)
        XCTAssertEqual(auth.subjects, [selfUserID])
        XCTAssertEqual(auth.scopes, [.user])
        XCTAssertEqual(auth.threads, ["T"])
    }
}

/// `self:user` has exactly one predicate in this task: the user's name. A self-description that is
/// not a name must not be written as one — it would rename the user and retire their real name as
/// superseded. Traits and autobiography belong to later tasks with their own vocabulary.
final class SelfAssertionNamePredicateTests: XCTestCase {

    private func row(_ role: String, _ text: String, seq: Int = 1) -> TranscriptRow {
        TranscriptRow(id: "r\(seq)", threadId: "T", turnIndex: seq, seq: seq, role: role,
                      text: text, createdAt: 1_000, consolidated: false)
    }

    private func rejection(_ label: String, _ text: String) -> SelfAssertionRejection? {
        let result = SelfAssertionValidator.validate(label: label, sources: [row("user", text)],
                                                     permittedScopes: [.user], evidenceScope: .user)
        if case .failure(let r) = result { return r }
        return nil
    }

    func test_rejectsACopularSelfDescriptionAsAName() {
        XCTAssertEqual(rejection("diabético", "soy diabético"), .notANameAssertion,
                       "'soy diabético' says something true about the user, but it is not their name")
        XCTAssertEqual(rejection("stubborn", "i am stubborn"), .notANameAssertion)
        XCTAssertEqual(rejection("tired", "im tired"), .notANameAssertion)
        XCTAssertEqual(rejection("cubano", "yo soy cubano"), .notANameAssertion)
    }

    func test_stillAcceptsAnExplicitNaming() {
        for text in ["me llamo Roilan", "mi nombre es Roilan", "my name is Roilan",
                     "call me Roilan", "llámame Roilan"] {
            XCTAssertNil(rejection("Roilan", text), "\(text) names the user explicitly")
        }
    }

    func test_aNonNameSelfAssertionNeverReachesTheIdentityNodeOrAClaim() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "soy diabético", now: 1_000)
        let json = #"{"entities":[{"entity":"diabético","kind":"self","detail":"condición"}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                               runtime: SchemaAwareRuntime(["entities": json]),
                                               transcriptStore: ts, now: { 2_000 })
        let report = await engine.runCycleReporting(isCancelled: { false })

        XCTAssertNil(try store.selfNode(), "the user was not renamed to their condition")
        let brain = BrainStore(store: store,
                               authorization: ConsolidationEvidenceAdapter.authorization(threads: ["T"]),
                               clock: { 9_000 })
        XCTAssertTrue(try brain.claims(subject: selfUserID, asOf: 9_000, scope: .user).isEmpty,
                      "and no name claim was committed for it")
        XCTAssertEqual(report.refusals.map { $0.code }, ["self_notANameAssertion"],
                       "the refusal records why, rather than passing silently")
    }

    func test_aNonNameAssertionDoesNotRetireTheRealName() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me llamo Roilan", now: 1_000)
        let naming = MemoryConsolidationEngine(
            store: store, embedder: nil,
            runtime: SchemaAwareRuntime(["entities": #"{"entities":[{"entity":"Roilan","kind":"self"}]}"#]),
            transcriptStore: ts, now: { 2_000 })
        _ = await naming.runCycleReporting(isCancelled: { false })

        try ts.append(threadId: "T", turnIndex: 1, role: "user", text: "soy diabético", now: 3_000)
        let condition = MemoryConsolidationEngine(
            store: store, embedder: nil,
            runtime: SchemaAwareRuntime(["entities": #"{"entities":[{"entity":"diabético","kind":"self"}]}"#]),
            transcriptStore: ts, now: { 4_000 })
        _ = await condition.runCycleReporting(isCancelled: { false })

        XCTAssertEqual(try store.selfNode()?.label, "Roilan", "the user is still called Roilan")
        let brain = BrainStore(store: store,
                               authorization: ConsolidationEvidenceAdapter.authorization(threads: ["T"]),
                               clock: { 9_000 })
        let names = try brain.claims(subject: selfUserID, asOf: 9_000, scope: .user)
            .filter { $0.predicate == ConsolidationIdentityClaim.namePredicate }
        XCTAssertEqual(names.map { $0.value }, [.string("Roilan")],
                       "the real name was not superseded by a condition")
    }
}
