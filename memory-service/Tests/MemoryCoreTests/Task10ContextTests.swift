import XCTest
import BrainContract
@testable import MemoryCore

private struct Task10EmptyTurnExtractor: BrainTurnExtractor {
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] { [] }
}

private struct Task10AffectFixture: BrainAffectExtractor {
    let qualification: BrainAffectQualification
    func extract(_ input: BrainAffectInput) async throws -> [BrainAffectCandidate] {
        let source = input.source
        return [.init(subjectID: "self:user", evidenceID: source.id,
               span: .init(start: 0, end: source.text?.utf8.count ?? 0),
               qualification: qualification, basis: .selfReported, label: .sadness, certainty: .moderate)]
    }
}

final class Task10ContextTests: XCTestCase {
    private let auth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"],
        scopes: [.user], threads: ["a", "b"], sourceSpeakers: [.userMessage: ["self:user"], .assistantMessage: ["self:agent"]],
        mayCommitClaims: true, mayForget: true)

    func testAffectAttributionCorrectionAndExactThread() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 0 })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10EmptyTurnExtractor())
        let fixtures: [(String, BrainAffectQualification)] = [
            ("Mi amigo está triste", .thirdParty), ("No estoy enfadado", .negated),
            ("Dijo «estoy triste»", .quoted), ("Si perdiera, estaría triste", .hypothetical),
            ("Qué alegría, se rompió otra vez 🙄", .sarcastic), ("Vale.", .ambiguous),
            ("Hoy estoy triste", .firstPerson)
        ]
        for (index, fixture) in fixtures.enumerated() {
            let now = Double(index + 10)
            let service = try AffectiveContextService(brain: brain, extractor: Task10AffectFixture(qualification: fixture.1), ttl: 5)
            let turn = try await turns.begin(.init(clientOperationID: String(index), threadID: "a",
                message: .init(id: "synthetic", speakerID: "self:user", text: fixture.0, observedAt: now, evidenceIDs: []),
                budget: .init(contextTokens: 10_000, outputTokens: 100)))
            let result = try await service.observe(turnID: turn.turnID, now: now)
            guard fixture.1 == .firstPerson else { XCTAssertTrue(result.isEmpty, fixture.0); continue }
            let hypothesis = try XCTUnwrap(result.first)
            XCTAssertEqual(hypothesis.basis, .selfReported)
            XCTAssertEqual(hypothesis.evidenceIDs, turn.completion.evidenceIDs)
            XCTAssertTrue(try service.context(threadID: "b", now: now).hypotheses.isEmpty)
            try service.correct(hypothesisID: hypothesis.id, operationID: "correction", correction: .dismiss)
            try service.correct(hypothesisID: hypothesis.id, operationID: "correction", correction: .dismiss)
            let retry = try await service.observe(turnID: turn.turnID, now: now + 1)
            XCTAssertTrue(retry.isEmpty)
            XCTAssertTrue(try service.context(threadID: "a", now: now + 5).hypotheses.isEmpty)
            XCTAssertTrue(try brain.claims(subject: "self:user", asOf: now, scope: .user).isEmpty)
        }
    }

    func testSparseTasteProfileDeclaresMissingInformation() throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth)
        let profile = try TastePreferenceService(brain: brain).profile(subject: "self:user", domain: "music", context: nil, now: 20)
        XCTAssertTrue(profile.records.isEmpty)
        XCTAssertTrue(profile.missingInformation?.contains(.taste) == true)
    }
}


private struct Task10AffectModel: BrainAffectExtractor {
    let response: (BrainEvidence) async throws -> [BrainAffectCandidate]
    func extract(_ input: BrainAffectInput) async throws -> [BrainAffectCandidate] { try await response(input.source) }
}

private struct Task10TurnModel: BrainTurnExtractor {
    let response: (BrainEvidence) async throws -> [BrainTurnProposal]
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] { try await response(source) }
}

private actor Task10AffectGate {
    let entered = XCTestExpectation(description: "fixture reached await")
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false

    func pauseFirstCall() async {
        guard !used else { return }
        used = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class Task10AffectClock {
    private let lock = NSLock()
    private var time: Double = 0

    func now() -> Double { lock.withLock { time } }
    func set(_ now: Double) { lock.withLock { time = now } }
}

extension Task10ContextTests {
    fileprivate func begin(_ text: String, at now: Double, thread: String = "a",
                           operationID: String? = nil, turns: BrainTurnService) async throws -> BrainTurnResult {
        try await turns.begin(.init(clientOperationID: operationID ?? "\(thread)-\(now)", threadID: thread,
            message: .init(id: "synthetic", speakerID: "self:user", text: text, observedAt: now, evidenceIDs: []),
            budget: .init(contextTokens: 9_000, outputTokens: 100)))
    }

    private func candidate(_ source: BrainEvidence, subject: String = "self:user",
                           evidenceID: String? = nil, end: Int? = nil,
                           certainty: BrainAffectCertainty = .moderate) -> BrainAffectCandidate {
        .init(subjectID: subject, evidenceID: evidenceID ?? source.id,
              span: .init(start: 0, end: end ?? source.text!.utf8.count),
              qualification: .firstPerson, basis: .inferred, label: .worry, certainty: certainty,
              interaction: .init(focus: .stayWithTopic, interest: .exploreTopic, tension: .slowDown))
    }

    func testAffectRequiresLiveSupportAndDeclinesLowCertaintyGuidance() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 0 })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10EmptyTurnExtractor())
        let affect = try AffectiveContextService(brain: brain, extractor: Task10AffectModel { source in
            [self.candidate(source, subject: "self:agent"), self.candidate(source, evidenceID: "foreign"),
             self.candidate(source, end: 1), self.candidate(source, certainty: .low)]
        }, ttl: 8)
        let turn = try await begin("Ánimo, puede salir mal", at: 10, turns: turns)
        let result = try await affect.observe(turnID: turn.turnID, now: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.certainty, .low)
        XCTAssertEqual(result.first?.basis, .inferred)
        XCTAssertNil(try affect.context(threadID: "a", now: 10).interaction)
        XCTAssertTrue(try affect.context(threadID: "a", now: 18).hypotheses.isEmpty)

        let restarted = try AffectiveContextService(brain: brain, extractor: Task10AffectFixture(qualification: .firstPerson))
        let historical = try await restarted.observe(turnID: turn.turnID, now: 11)
        XCTAssertTrue(historical.isEmpty)
        let next = try await begin("Estoy triste hoy", at: 12, turns: turns)
        let beforeEnd = try await restarted.observe(turnID: next.turnID, now: 12)
        XCTAssertEqual(beforeEnd.count, 1)
        try restarted.endSession(threadID: "a")
        let afterEnd = try await restarted.observe(turnID: next.turnID, now: 13)
        XCTAssertTrue(afterEnd.isEmpty)
        XCTAssertTrue(try restarted.context(threadID: "a", now: 13).hypotheses.isEmpty)
    }

    func testOlderAwaitCannotSupersedeNewerTurnOrResurrectDismissedGuidance() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 0 })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10EmptyTurnExtractor())
        let gate = Task10AffectGate()
        let affect = try AffectiveContextService(brain: brain, extractor: Task10AffectModel { source in
            await gate.pauseFirstCall()
            return [self.candidate(source)]
        })
        let first = try await begin("Me preocupa el resultado", at: 10, turns: turns)
        let pending = Task { try await affect.observe(turnID: first.turnID, now: 10) }
        await fulfillment(of: [gate.entered], timeout: 5)
        let latest = try await begin("Estoy intentando decidir", at: 11, turns: turns)
        let result = try await affect.observe(turnID: latest.turnID, now: 11)
        let hypothesis = try XCTUnwrap(result.first)
        XCTAssertEqual(hypothesis.evidenceIDs, latest.completion.evidenceIDs + first.completion.evidenceIDs)
        XCTAssertNotNil(try affect.context(threadID: "a", now: 11).interaction)
        try affect.correct(hypothesisID: hypothesis.id, operationID: "dismiss-latest", correction: .dismiss)
        await gate.release()
        let older = try await pending.value
        XCTAssertTrue(older.isEmpty)
        XCTAssertNil(try affect.context(threadID: "a", now: 11).interaction)
    }

    func testNewerTurnInvalidatesAffectBeforeItsObservationStarts() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let clock = Task10AffectClock()
        let brain = BrainStore(store: db, authorization: auth, clock: { clock.now() })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10EmptyTurnExtractor())
        let gate = Task10AffectGate()
        let affect = try AffectiveContextService(brain: brain, extractor: Task10AffectModel { source in
            await gate.pauseFirstCall()
            return [self.candidate(source)]
        })
        let first = try await begin("Me preocupa el resultado", at: 10, turns: turns)
        let pending = Task { try await affect.observe(turnID: first.turnID, now: 10) }
        await fulfillment(of: [gate.entered], timeout: 5)
        let second = try await begin("Pasemos a otro tema", at: 11, turns: turns)
        clock.set(11)
        await gate.release()
        let stale = try await pending.value
        XCTAssertTrue(stale.isEmpty)
        let retry = try await affect.observe(turnID: first.turnID, now: 11)
        XCTAssertTrue(retry.isEmpty)
        let fresh = try await affect.observe(turnID: second.turnID, now: 11)
        XCTAssertEqual(fresh.count, 1)
        _ = try await begin("De acuerdo", at: 12, turns: turns)
        XCTAssertTrue(try affect.context(threadID: "a", now: 12).hypotheses.isEmpty)
        XCTAssertNil(try affect.context(threadID: "a", now: 12).interaction)
    }

    func testPendingTurnSupersedesEarlierAffectWithoutProducingItsOwn() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 0 })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10TurnModel { source in
            if source.text == "Pasemos a otro tema" { throw BrainStoreError.invalid }
            return []
        })
        let affect = try AffectiveContextService(brain: brain, extractor: Task10AffectModel { [self.candidate($0)] })
        let first = try await begin("Me preocupa el resultado", at: 10, turns: turns)
        let observed = try await affect.observe(turnID: first.turnID, now: 10)
        XCTAssertEqual(observed.count, 1)
        XCTAssertNotNil(try affect.context(threadID: "a", now: 10).interaction)
        let next = try await begin("Pasemos a otro tema", at: 11, turns: turns)
        XCTAssertEqual(next.completion.state, .pending)
        let stale = try await affect.observe(turnID: first.turnID, now: 11)
        XCTAssertTrue(stale.isEmpty)
        XCTAssertNil(try affect.context(threadID: "a", now: 11).interaction)
        do {
            _ = try await affect.observe(turnID: next.turnID, now: 11)
            XCTFail("Pending turn produced affect")
        } catch {
            XCTAssertEqual(error as? BrainStoreError, .denied)
        }
    }

    func testProviderAwaitRevalidatesForgetAndClock() async throws {
        for forget in [false, true] {
            let db = try MemoryStore(inMemory: true, embeddingDim: 16)
            let clock = Task10AffectClock()
            let brain = BrainStore(store: db, authorization: auth, clock: { clock.now() })
            let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10EmptyTurnExtractor())
            let gate = Task10AffectGate()
            let affect = try AffectiveContextService(brain: brain, extractor: Task10AffectModel { source in
                await gate.pauseFirstCall()
                return [self.candidate(source)]
            }, ttl: 5)
            let turn = try await begin("Esto me preocupa", at: 10, turns: turns)
            let pending = Task { try await affect.observe(turnID: turn.turnID, now: 10) }
            await fulfillment(of: [gate.entered], timeout: 5)
            if forget {
                _ = try BrainRetractionService(brain: brain).forget(
                    scope: .init(kind: .evidence, id: turn.completion.evidenceIDs.first),
                    expectedRevision: brain.revision(), operationID: "forget-awaiting")
            } else { clock.set(15) }
            await gate.release()
            do {
                let result = try await pending.value
                XCTAssertFalse(forget, "withdrawn observation returned")
                XCTAssertTrue(result.isEmpty)
            } catch {
                XCTAssertTrue(forget)
                XCTAssertEqual(error as? BrainStoreError, .denied)
            }
            XCTAssertTrue(try affect.context(threadID: "a", now: 15).hypotheses.isEmpty)
        }
    }

    func testExpressedAdviceAndCuesReachOnlyBudgetedSourceBoundContext() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 11 })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10TurnModel { source in
            let claim = BrainClaim(id: "listen-today", revision: 0, subject: "self:user",
                predicate: AffectiveContextService.advicePreferencePredicate, value: .string("listen"),
                modality: .asserted, status: .active, validFrom: 11, validTo: 20, recordedAt: 11,
                evidenceIDs: [source.id])
            return [.init(update: .init(claim: claim), span: .init(start: 0, end: source.text!.utf8.count), intent: .explicit)]
        })
        let affect = try AffectiveContextService(brain: brain, extractor: Task10AffectModel { [self.candidate($0)] })
        let turn = try await begin("Hoy no quiero consejos", at: 11, turns: turns)
        _ = try await affect.observe(turnID: turn.turnID, now: 11)
        let source = try XCTUnwrap(turn.completion.evidenceIDs.first)
        let guidance = try affect.context(threadID: "a", now: 11)
        XCTAssertEqual(guidance.advice?.mode, .listen)
        XCTAssertEqual(guidance.advice?.evidenceIDs, [source])
        XCTAssertNil(try affect.context(threadID: "a", now: 20).advice)
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain), affect: affect)
        func bundle(thread: String, budget: Int = 9_000) async throws -> BrainContextBundle {
            try await assembler.context(.init(clientOperationID: "context", threadID: thread, query: "",
                budget: .init(contextTokens: budget, outputTokens: 100)))
        }
        let sameThread = try await bundle(thread: "a")
        XCTAssertTrue(sameThread.renderedContext.contains("Listen without offering unsolicited advice"))
        XCTAssertTrue(sameThread.renderedContext.contains("Use a patient pace"))
        XCTAssertFalse(sameThread.renderedContext.contains("worry"))
        XCTAssertTrue(sameThread.sourceUses?[source]?.contains(.derivedSupport) == true)
        XCTAssertNil(sameThread.sourceReferences.first { $0.id == source }?.text)
        XCTAssertLessThanOrEqual(try XCTUnwrap(sameThread.accounting).estimatedInputTokens, 8_900)
        let other = try await bundle(thread: "b")
        XCTAssertFalse(other.renderedContext.contains("unsolicited advice"))
        XCTAssertFalse(other.renderedContext.contains("patient pace"))
        XCTAssertFalse(other.sourceReferences.contains { $0.id == source })
        let policy = BrainConversationPolicy.canonical.instructions
        for term in ["retaliation", "reassurance", "catalog", "playback", "variety"] {
            XCTAssertTrue(policy.contains(term), term)
        }
        _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: source),
            expectedRevision: brain.revision(), operationID: "forget-guidance")
        let afterForget = try await bundle(thread: "a")
        XCTAssertFalse(afterForget.renderedContext.contains("unsolicited advice"))
        XCTAssertFalse(afterForget.renderedContext.contains("patient pace"))
        XCTAssertFalse(afterForget.sourceReferences.contains { $0.id == source })
    }
}


extension Task10ContextTests {
    func testTypedTasteProfileKeepsEnduringTastesComparisonsAndCurrentIntentSeparate() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 30 })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10TurnModel { source in
            func proposal(_ kind: BrainTasteKind, _ target: String, domain: String = "music",
                          alternatives: [String]? = nil, criterion: String? = nil, context: String? = nil,
                          intensity: BrainTasteIntensity? = nil, durability: BrainTasteDurability = .enduring,
                          provenance: BrainTasteProvenance = .explicit, until: Double? = nil,
                          qualification: BrainTurnQualification = .firstPerson) throws -> BrainTurnProposal {
                let record = BrainTasteRecord(id: "\(source.observedAt)-\(target)", subjectID: "self:user", kind: kind,
                    target: target, alternatives: alternatives, criterion: criterion, domain: domain, context: context,
                    provenance: provenance, durability: durability, recordedAt: source.recordedAt, evidenceIDs: [source.id],
                    intensity: intensity, modality: provenance == .explicit ? .asserted : .inferred, attribution: .direct)
                return .init(update: try TastePreferenceService.update(record, validTo: until),
                    span: .init(start: 0, end: source.text!.utf8.count),
                    intent: provenance == .explicit ? .explicit : .candidate, qualification: qualification)
            }
            switch source.text {
            case "Me gustan Azul y Ocre": return [try proposal(.liking, "Azul"), try proposal(.liking, "Ocre")]
            case "Pon Verde": return [try proposal(.selection, "Verde", durability: .contextual, until: 24)]
            case "Escuché Índigo":
                return [try proposal(.selection, "Índigo", durability: .contextual, provenance: .inferred, until: 27)]
            case "Mi favorito es Nube": return [try proposal(.comparativePreference, "Nube", criterion: "favorite", durability: .contextual)]
            case "Odio Sombras": return [try proposal(.disliking, "Sombras", domain: "games", intensity: .strong)]
            case "Para relajarme el fin de semana prefiero nadar a correr":
                return [try proposal(.comparativePreference, "nadar", domain: "activity", alternatives: ["correr"],
                                     criterion: "relax", context: "weekend", durability: .contextual)]
            case "Hoy quiero algo distinto": return [try proposal(.variety, "something different", durability: .contextual, until: 22)]
            case "Pon Rojo para mi amiga":
                return [try proposal(.selection, "Rojo", durability: .contextual, until: 24, qualification: .thirdParty)]
            case "Ella dijo «me gusta Plata»": return [try proposal(.liking, "Plata", qualification: .quoted)]
            case "Ajá": return [try proposal(.liking, "Verde", durability: .contextual, provenance: .inferred, until: 25)]
            case "Volví a escuchar Violeta":
                return [try proposal(.liking, "Violeta", durability: .contextual, provenance: .inferred, until: 28)]
            default: return []
            }
        })
        _ = try await begin("Pon Verde", at: 10, turns: turns)
        let likes = try await begin("Me gustan Azul y Ocre", at: 11, turns: turns)
        _ = try await begin("Mi favorito es Nube", at: 12, turns: turns)
        _ = try await begin("Odio Sombras", at: 13, turns: turns)
        _ = try await begin("Para relajarme el fin de semana prefiero nadar a correr", at: 14, turns: turns)
        _ = try await begin("Escuché Índigo", at: 16, turns: turns)
        _ = try await begin("Hoy quiero algo distinto", at: 17, turns: turns)
        _ = try await begin("Pon Rojo para mi amiga", at: 18, turns: turns)
        _ = try await begin("Ella dijo «me gusta Plata»", at: 19, turns: turns)
        let asks = try await begin("¿Qué sugieres?", at: 19.5, turns: turns)
        let recommendation = try turns.recordAssistant(turnID: asks.turnID, operationID: "suggest-verde", text: "Te sugiero Verde")
        XCTAssertEqual(recommendation.speakerID, "self:agent")
        let ack = try await begin("Ajá", at: 20, turns: turns)
        XCTAssertFalse(try turns.currentClaims(turnID: ack.turnID, asOf: 20).contains {
            $0.predicate == "preference.taste" && $0.evidenceIDs == ack.completion.evidenceIDs
        })
        _ = try await begin("Volví a escuchar Violeta", at: 21, turns: turns)

        let tastes = TastePreferenceService(brain: brain)
        let inA = BrainTasteContext(threadID: "a")
        let first = try tastes.profile(subject: "self:user", domain: "music", context: inA, now: 10)
        XCTAssertTrue(first.records.isEmpty)
        XCTAssertEqual(first.currentIntent?.map(\.target), ["Verde"])
        let firstIntent = try XCTUnwrap(first.currentIntent?.first)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(firstIntent)) as? [String: Any])
        XCTAssertEqual(encoded["validFrom"] as? Double, 10)
        XCTAssertEqual(encoded["validTo"] as? Double, 24)
        let afterCandidate = try tastes.profile(subject: "self:user", domain: "music", context: inA, now: 16)
        XCTAssertEqual(afterCandidate.currentIntent?.map(\.target), ["Verde"])
        let afterVariety = try tastes.profile(subject: "self:user", domain: "music", context: inA, now: 22)
        XCTAssertEqual(afterVariety.currentIntent, [])
        XCTAssertTrue(try brain.claims(subject: "self:user", asOf: 10, scope: .user).isEmpty)
        let music = try tastes.profile(subject: "self:user", domain: "music", context: inA, now: 20)
        XCTAssertEqual(Set(music.records.map(\.target)), ["Azul", "Ocre", "Nube"])
        XCTAssertEqual(music.currentIntent?.map(\.kind), [.variety])
        XCTAssertNil(music.records.first { $0.target == "Nube" }?.alternatives)
        XCTAssertEqual(music.records.first { $0.target == "Nube" }?.criterion, "favorite")
        let inferred = try tastes.profile(subject: "self:user", domain: "music", context: inA, now: 21)
        let violet = try XCTUnwrap(inferred.records.first { $0.target == "Violeta" })
        XCTAssertEqual(violet.provenance, .inferred)
        XCTAssertEqual(violet.modality, .inferred)
        XCTAssertFalse(violet.isEnduringTaste)
        let other = try tastes.profile(subject: "self:user", domain: "music", context: .init(threadID: "b"), now: 21)
        XCTAssertEqual(other.currentIntent, [])
        XCTAssertEqual(other.records, music.records)
        let games = try tastes.profile(subject: "self:user", domain: "games", context: nil, now: 20)
        XCTAssertEqual(games.records.first?.intensity, .strong)
        let activity = try tastes.profile(subject: "self:user", domain: "activity", context: .init(situation: "weekend"), now: 20)
        XCTAssertEqual(activity.records.first?.alternatives, ["correr"])
        XCTAssertEqual(activity.records.first?.criterion, "relax")
        XCTAssertEqual(activity.records.first?.context, "weekend")
        let expired = try tastes.profile(subject: "self:user", domain: "music", context: inA, now: 28)
        XCTAssertEqual(expired.currentIntent, [])
        XCTAssertEqual(expired.records, music.records)

        let old = try XCTUnwrap(brain.claims(subject: "self:user", asOf: 20, scope: .user).first { $0.id == "11.0-Azul" })
        let correction = BrainTurnService(store: db, authorization: auth, extractor: Task10TurnModel { source in
            let record = BrainTasteRecord(id: "correction-azul", subjectID: "self:user", kind: .disliking,
                target: "Azul", domain: "music", provenance: .explicit, durability: .enduring,
                recordedAt: source.recordedAt, evidenceIDs: [source.id], modality: .asserted, attribution: .direct)
            return [.init(update: try TastePreferenceService.update(record, superseding: old),
                          span: .init(start: 0, end: source.text!.utf8.count), intent: .explicit)]
        })
        let revised = try await begin("Corrijo: ahora me desagrada Azul", at: 23, turns: correction)
        XCTAssertEqual(revised.completion.state, .committed)
        let corrected = try tastes.profile(subject: "self:user", domain: "music", context: inA, now: 23)
        XCTAssertEqual(corrected.records.filter { $0.target == "Azul" }.map(\.kind), [.disliking])
        _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .evidence, id: likes.completion.evidenceIDs.first),
            expectedRevision: brain.revision(), operationID: "forget-likes")
        let forgotten = try tastes.profile(subject: "self:user", domain: "music", context: inA, now: 24)
        XCTAssertFalse(forgotten.records.contains { $0.target == "Ocre" })
    }

    func testSameTimestampIntentUsesTranscriptOrderDespiteReversedCommits() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 10 })
        let gate = Task10AffectGate()
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10TurnModel { source in
            let first = source.text == "Pon Azul"
            if first { await gate.pauseFirstCall() }
            let target = first ? "Azul" : "Verde"
            let record = BrainTasteRecord(id: target, subjectID: "self:user", kind: .selection,
                target: target, domain: "music", provenance: .explicit, recordedAt: source.recordedAt,
                evidenceIDs: [source.id], attribution: .direct)
            return [.init(update: try TastePreferenceService.update(record, validTo: 20),
                          span: .init(start: 0, end: source.text!.utf8.count), intent: .explicit)]
        })
        let first = Task { try await self.begin("Pon Azul", at: 10, operationID: "first", turns: turns) }
        await fulfillment(of: [gate.entered], timeout: 5)
        let later = try await begin("Pon Verde", at: 10, operationID: "later", turns: turns)
        await gate.release()
        let earlier = try await first.value
        XCTAssertEqual(later.completion.state, .committed)
        XCTAssertEqual(earlier.completion.state, .committed)
        XCTAssertGreaterThan(earlier.completion.revision, later.completion.revision)
        let profile = try TastePreferenceService(brain: brain).profile(
            subject: "self:user", domain: "music", context: .init(threadID: "a"), now: 10)
        XCTAssertEqual(profile.currentIntent?.map(\.evidenceIDs), [later.completion.evidenceIDs])
    }

    func testTasteCommitRequiresValidatedAttributedTurn() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth)
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10EmptyTurnExtractor())
        let turn = try await begin("Me gusta Azul", at: 10, turns: turns)
        let record = BrainTasteRecord(id: "bypass", subjectID: "self:user", kind: .liking, target: "Azul",
            domain: "music", provenance: .explicit, durability: .enduring, recordedAt: 10,
            evidenceIDs: turn.completion.evidenceIDs, modality: .asserted, attribution: .direct)
        let update = try TastePreferenceService.update(record)
        let commit = try BrainCommitRequest(clientOperationID: "bypass", evidence: [], updates: [update],
                                            expectedRevision: brain.revision())
        XCTAssertThrowsError(try brain.commit(commit)) { XCTAssertEqual($0 as? BrainStoreError, .denied) }
        let wire = try BrainCommitRequest(clientOperationID: "wire-tastes", evidence: [], updates: [],
                                          expectedRevision: brain.revision(), tastes: [record])
        XCTAssertThrowsError(try brain.commit(wire)) { XCTAssertEqual($0 as? BrainStoreError, .invalid) }
    }
}


private struct Task10HistoryModel: BrainAffectExtractor {
    let response: (BrainAffectInput) -> [BrainAffectCandidate]
    func extract(_ input: BrainAffectInput) async throws -> [BrainAffectCandidate] { response(input) }
}

extension Task10ContextTests {
    func testCueWithoutAffectLabelCanBeDismissed() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 0 })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10EmptyTurnExtractor())
        let affect = try AffectiveContextService(brain: brain, extractor: Task10AffectModel { source in
            [.init(subjectID: source.speakerID, evidenceID: source.id,
                   span: .init(start: 0, end: source.text!.utf8.count), qualification: .firstPerson,
                   basis: .inferred, certainty: .moderate, interaction: .init(focus: .clarifyGoal))]
        })
        let turn = try await begin("No sé por dónde empezar", at: 10, turns: turns)
        let observed = try await affect.observe(turnID: turn.turnID, now: 10)
        let hypothesis = try XCTUnwrap(observed.first)
        XCTAssertNil(hypothesis.label)
        XCTAssertEqual(hypothesis.evidenceIDs, turn.completion.evidenceIDs)
        XCTAssertNotNil(try affect.context(threadID: "a", now: 10).interaction)
        try affect.correct(hypothesisID: hypothesis.id, operationID: "dismiss-cue", correction: .dismiss)
        XCTAssertNil(try affect.context(threadID: "a", now: 10).interaction)
    }

    func testRecentAffectSupportIsBoundedExactThreadAndCannotSurviveForget() async throws {
        let db = try MemoryStore(inMemory: true, embeddingDim: 16)
        let brain = BrainStore(store: db, authorization: auth, clock: { 16 })
        let turns = BrainTurnService(store: db, authorization: auth, extractor: Task10EmptyTurnExtractor())
        let affect = try AffectiveContextService(brain: brain, extractor: Task10HistoryModel { input in
            XCTAssertEqual(input.source.text, "Hoy sigue siendo difícil")
            XCTAssertEqual(input.recent.compactMap(\.text), ["Paso dos", "Paso tres", "Paso cuatro", "Paso cinco"])
            XCTAssertTrue(input.recent.allSatisfy { $0.threadID == "a" && $0.speakerID == "self:user" })
            return [self.candidate(input.source)]
        })
        _ = try await begin("Paso uno", at: 10, turns: turns)
        let two = try await begin("Paso dos", at: 11, turns: turns)
        _ = try await begin("Otro chat", at: 12, thread: "b", turns: turns)
        let three = try await begin("Paso tres", at: 13, turns: turns)
        let four = try await begin("Paso cuatro", at: 14, turns: turns)
        let supporting = try await begin("Paso cinco", at: 15, turns: turns)
        let current = try await begin("Hoy sigue siendo difícil", at: 16, turns: turns)
        let observed = try await affect.observe(turnID: current.turnID, now: 16)
        let expected = [current, two, three, four, supporting].flatMap { $0.completion.evidenceIDs }
        XCTAssertEqual(observed.first?.evidenceIDs, expected)
        XCTAssertEqual(observed.first?.expiresAt, 911)
        let interaction = try affect.context(threadID: "a", now: 16).interaction
        XCTAssertEqual(interaction?.evidenceIDs, expected)
        XCTAssertEqual(interaction?.expiresAt, 911)
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain), affect: affect)
        let bundle = try await assembler.context(.init(clientOperationID: "context-support", threadID: "a", query: "",
            budget: .init(contextTokens: 9_000, outputTokens: 100)))
        XCTAssertTrue(bundle.renderedContext.contains("Use a patient pace"))
        for id in expected { XCTAssertTrue(bundle.sourceUses?[id]?.contains(.derivedSupport) == true, id) }
        _ = try BrainRetractionService(brain: brain).forget(
            scope: .init(kind: .evidence, id: supporting.completion.evidenceIDs.first),
            expectedRevision: brain.revision(), operationID: "forget-supporting-history")
        XCTAssertTrue(try affect.context(threadID: "a", now: 17).hypotheses.isEmpty)
        let retry = try await affect.observe(turnID: current.turnID, now: 17)
        XCTAssertTrue(retry.isEmpty)
    }
}
