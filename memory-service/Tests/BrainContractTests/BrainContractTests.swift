import XCTest
@testable import BrainContract

final class BrainContractTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    private func roundTrip<T: Codable & Equatable & Sendable>(_ type: T.Type, _ json: String) throws {
        let original = try decode(type, json)
        XCTAssertEqual(try JSONDecoder().decode(type, from: JSONEncoder().encode(original)), original)
    }
    func testAllWireTypesPreserveSourceAndStateOnRoundTrip() throws {
        try roundTrip(BrainEvidence.self, #"{"id":"e","sourceKind":"userMessage","speakerID":"self:user","threadID":"t","observedAt":1,"recordedAt":2,"span":{"start":0,"end":3},"accessScope":"thread"}"#)
        try roundTrip(BrainClaim.self, #"{"id":"c","revision":7,"subject":"self:user","predicate":"likes","value":{"nested":[true,2,null]},"modality":"asserted","status":"active","validFrom":1,"validTo":9,"recordedAt":2,"evidenceIDs":["e"],"supersedesID":"old"}"#)
        try roundTrip(BrainClaimUpdate.self, #"{"claim":{"id":"c","revision":7,"subject":"self:user","predicate":"likes","value":"tea","modality":"asserted","status":"active","validFrom":1,"recordedAt":2,"evidenceIDs":["e"]},"expectedRevision":6}"#)
        try roundTrip(BrainCommitRequest.self, #"{"schemaVersion":1,"clientOperationID":"commit1","evidence":[],"updates":[],"tastes":[],"expectedRevision":6}"#)
        try roundTrip(BrainCommitResult.self, #"{"clientOperationID":"commit1","state":"committed","revision":7,"claimIDs":["c"],"disposition":"idempotent"}"#)
        try roundTrip(BrainContextBudget.self, #"{"contextTokens":4096,"outputTokens":512}"#)
        try roundTrip(BrainContextRequest.self, #"{"schemaVersion":1,"clientOperationID":"context1","threadID":"t","query":"tea","budget":{"contextTokens":4096,"outputTokens":512}}"#)
        try roundTrip(BrainContextBundle.self, #"{"renderedContext":"Tea was requested.","recentMessageUnits":[{"id":"m","speakerID":"self:user","text":"Tea please","observedAt":1,"evidenceIDs":["e"]}],"sourceReferences":[],"revision":7,"policyRevision":1}"#)
        try roundTrip(BrainTurnRequest.self, #"{"schemaVersion":1,"clientOperationID":"turn1","threadID":"t","message":{"id":"m","speakerID":"self:user","text":"Tea please","observedAt":1,"evidenceIDs":["e"]},"budget":{"contextTokens":4096,"outputTokens":512}}"#)
        try roundTrip(BrainTurnResult.self, #"{"clientOperationID":"turn1","turnID":"turn1","reply":"Tea sounds good.","completion":{"state":"pending","revision":7,"evidenceIDs":["e"]}}"#)
        try roundTrip(BrainTurnCompletionRequest.self, #"{"schemaVersion":1,"clientOperationID":"complete1","turnID":"turn1","assistantText":"Tea sounds good.","evidenceIDs":["e"]}"#)
        try roundTrip(BrainTurnCompletion.self, #"{"state":"committed","revision":7,"evidenceIDs":["e"]}"#)
        try roundTrip(BrainIdentity.self, #"{"id":"self:agent","kind":"agent","displayName":"Assistant","claimIDs":[]}"#)
        try roundTrip(BrainAffectHypothesis.self, #"{"id":"a","subjectID":"self:user","label":"uncertain","confidence":0.4,"sessionID":"s","observedAt":1,"expiresAt":30,"evidenceIDs":["e"]}"#)
        try roundTrip(BrainOutcome.self, #"{"id":"o","description":"Tea prepared","status":"succeeded","recordedAt":2,"evidenceIDs":["e"]}"#)
        try roundTrip(BrainProcedure.self, #"{"id":"p","description":"Prepare tea","steps":["Boil water"],"evidenceIDs":["e"],"outcomeIDs":["o"]}"#)
        try roundTrip(BrainProspectiveCandidate.self, #"{"id":"p","description":"Offer tea","evidenceIDs":["e"],"requiresAuthorization":true}"#)
        try roundTrip(BrainTasteRecord.self, #"{"id":"t","subjectID":"self:user","kind":"comparativePreference","target":"tea","alternatives":["coffee"],"criterion":"less caffeine","domain":"drinks","context":"evening","provenance":"explicit","durability":"contextual","recordedAt":1,"evidenceIDs":["e"]}"#)
        try roundTrip(BrainTasteProfile.self, #"{"subjectID":"self:user","revision":7,"records":[]}"#)
        try roundTrip(BrainModelCapabilities.self, #"{"contextTokens":4096,"outputTokens":512,"tools":["search"],"structuredOutput":true,"images":false,"tokenizerEstimatePolicy":"conservative"}"#)
        try roundTrip(BrainForgetScope.self, #"{"kind":"subject","id":"self:user"}"#)
        try roundTrip(BrainForgetReceipt.self, #"{"clientOperationID":"forget1","scope":{"kind":"subject","id":"self:user"},"state":"committed","revision":8,"forgottenEvidenceIDs":["e"],"forgottenClaimIDs":["c"],"affectedIDs":["derived1"],"sourceEvidenceIDs":["e"]}"#)
        let policy = BrainConversationPolicy.canonical
        XCTAssertEqual(try JSONDecoder().decode(BrainConversationPolicy.self, from: JSONEncoder().encode(policy)), policy)
    }
    func testLegacyAdditionsDefaultConservatively() throws {
        let c = try decode(BrainClaim.self, #"{"id":"c","revision":1,"subject":"self:user","predicate":"likes","value":"tea","modality":"asserted","status":"active","validFrom":1,"recordedAt":1,"evidenceIDs":["e"]}"#)
        XCTAssertNil(c.validTo); XCTAssertNil(c.supersedesID)
        let e = try decode(BrainEvidence.self, #"{"id":"e","sourceKind":"userMessage","speakerID":"self:user","threadID":"t","observedAt":1,"recordedAt":1,"accessScope":"thread"}"#)
        XCTAssertNil(e.span)
        let request = try decode(BrainCommitRequest.self, #"{"clientOperationID":"op","evidence":[],"updates":[]}"#)
        XCTAssertEqual(request.schemaVersion, 1); XCTAssertNil(request.tastes)
        let taste = try decode(BrainTasteRecord.self, #"{"id":"t","subjectID":"self:user","kind":"comparativePreference","target":"tea","provenance":"inferred","recordedAt":1,"evidenceIDs":["e"]}"#)
        XCTAssertNil(taste.alternatives); XCTAssertNil(taste.criterion); XCTAssertNil(taste.context)
        XCTAssertEqual(taste.durability, .contextual); XCTAssertFalse(taste.isEnduringTaste)
    }
    func testUnsupportedRequestSchemasAreRejectedBeforePayloadUse() throws {
        for type: any Decodable.Type in [BrainCommitRequest.self, BrainTurnRequest.self, BrainContextRequest.self, BrainTurnCompletionRequest.self] {
            XCTAssertThrowsError(try JSONDecoder().decode(type, from: Data(#"{"schemaVersion":2,"clientOperationID":"op"}"#.utf8))) { error in
                XCTAssertEqual(error as? BrainContractError, .unsupportedSchemaVersion(2))
            }
        }
        XCTAssertThrowsError(try BrainCommitRequest(clientOperationID: "  ", evidence: [], updates: []))
        XCTAssertThrowsError(try decode(BrainCommitRequest.self, #"{"clientOperationID":"","evidence":[],"updates":[]}"#))
    }
    func testBudgetsRejectNegativeAndImpossibleAllocations() throws {
        for (context, output) in [(-1, 0), (1, -1), (10, 11)] {
            XCTAssertThrowsError(try BrainContextBudget(contextTokens: context, outputTokens: output))
            XCTAssertThrowsError(try BrainModelCapabilities(contextTokens: context, outputTokens: output, tools: [], structuredOutput: false, images: false, tokenizerEstimatePolicy: .conservative))
            XCTAssertThrowsError(try decode(BrainContextBudget.self, "{\"contextTokens\":\(context),\"outputTokens\":\(output)}"))
            XCTAssertThrowsError(try decode(BrainModelCapabilities.self, "{\"contextTokens\":\(context),\"outputTokens\":\(output),\"tools\":[],\"structuredOutput\":false,\"images\":false,\"tokenizerEstimatePolicy\":\"conservative\"}"))
        }
        XCTAssertNoThrow(try BrainContextBudget(contextTokens: 0, outputTokens: 0))
    }
    func testIdentityAndPolicyKeepUserAndAgentDistinct() {
        XCTAssertEqual(BrainIdentity.userID, "self:user"); XCTAssertEqual(BrainIdentity.agentID, "self:agent")
        XCTAssertEqual(BrainIdentity.relationshipID, "relationship:user:agent")
        XCTAssertNotEqual(BrainIdentity.userID, BrainIdentity.agentID)
        let p = BrainConversationPolicy.canonical
        XCTAssertTrue(p.requiresTruthfulIdentity); XCTAssertTrue(p.questionsAreOptional)
        XCTAssertFalse(p.requiresAcknowledgment); XCTAssertNil(p.requiredSentenceCount)
        XCTAssertTrue(p.instructions.contains("evidence")); XCTAssertTrue(p.instructions.contains("authorization"))
    }
    func testOneTimeSelectionIsNotAnEnduringTaste() throws {
        let t = BrainTasteRecord(id: "t", subjectID: BrainIdentity.userID, kind: .comparativePreference, target: "tea", alternatives: ["coffee"], provenance: .explicit, recordedAt: 1, evidenceIDs: ["e"])
        XCTAssertEqual(t.durability, .contextual); XCTAssertFalse(t.isEnduringTaste)
        let liking = BrainTasteRecord(id: "l", subjectID: BrainIdentity.userID, kind: .liking, target: "tea", provenance: .explicit, durability: .enduring, recordedAt: 1, evidenceIDs: ["e"])
        XCTAssertTrue(liking.isEnduringTaste)
    }
    func testCommitReplayAndConflictRemainDistinctFromPersistenceState() throws {
        let conflict = try decode(BrainCommitResult.self, #"{"clientOperationID":"op","state":"pending","revision":7,"claimIDs":[],"disposition":"conflict"}"#)
        XCTAssertEqual(conflict.disposition, .conflict)
        XCTAssertEqual(conflict.state, .pending)
        let replay = try decode(BrainCommitResult.self, #"{"clientOperationID":"op","state":"committed","revision":7,"claimIDs":["c"],"disposition":"idempotent"}"#)
        XCTAssertEqual(replay.disposition, .idempotent)
        XCTAssertEqual(replay.state, .committed)
    }

    func testAbsentCommitDispositionDoesNotInventSuccessfulCommit() throws {
        let result = try decode(BrainCommitResult.self, #"{"clientOperationID":"op","state":"pending","revision":1,"claimIDs":[]}"#)
        XCTAssertEqual(result.state, .pending)
        XCTAssertNil(result.disposition)
    }
    func testSourceBoundOptionalFieldsAreNotDropped() throws {
        let request = try decode(BrainCommitRequest.self, #"{"schemaVersion":1,"clientOperationID":"op","evidence":[],"updates":[],"expectedRevision":6}"#)
        XCTAssertEqual(request.expectedRevision, 6)
        let taste = try decode(BrainTasteRecord.self, #"{"id":"t","subjectID":"self:user","kind":"comparativePreference","target":"tea","alternatives":["coffee"],"criterion":"less caffeine","domain":"drinks","context":"evening","provenance":"explicit","recordedAt":1,"evidenceIDs":["e"]}"#)
        XCTAssertEqual(taste.alternatives, ["coffee"]); XCTAssertEqual(taste.criterion, "less caffeine")
        XCTAssertEqual(taste.domain, "drinks"); XCTAssertEqual(taste.context, "evening")
        XCTAssertEqual(taste.provenance, .explicit); XCTAssertEqual(taste.evidenceIDs, ["e"])
        let receipt = try decode(BrainForgetReceipt.self, #"{"clientOperationID":"f","scope":{"kind":"subject","id":"self:user"},"state":"committed","revision":8,"forgottenEvidenceIDs":["e"],"forgottenClaimIDs":["c"],"affectedIDs":["derived1"],"sourceEvidenceIDs":["e"]}"#)
        XCTAssertEqual(receipt.affectedIDs, ["derived1"]); XCTAssertEqual(receipt.sourceEvidenceIDs, ["e"])
    }
    func testTasteStrengthAndFavoritePreserveScopeWithoutInventingComparison() throws {
        let dislike = try decode(BrainTasteRecord.self, #"{"id":"d","subjectID":"self:user","kind":"disliking","target":"celery","provenance":"explicit","intensity":"strong","modality":"asserted","attribution":"direct","recordedAt":1,"evidenceIDs":["e"]}"#)
        XCTAssertEqual(dislike.intensity, .strong); XCTAssertEqual(dislike.kind, .disliking)
        let favorite = try decode(BrainTasteRecord.self, #"{"id":"f","subjectID":"self:user","kind":"comparativePreference","target":"tea","criterion":"favorite","context":"evening drinks","provenance":"explicit","recordedAt":1,"evidenceIDs":["e"]}"#)
        XCTAssertEqual(favorite.criterion, "favorite"); XCTAssertNil(favorite.alternatives)
        XCTAssertEqual(favorite.durability, .contextual); XCTAssertFalse(favorite.isEnduringTaste)
        XCTAssertNil(favorite.intensity); XCTAssertNil(favorite.modality); XCTAssertNil(favorite.attribution)
        try roundTrip(BrainTasteRecord.self, #"{"id":"d","subjectID":"self:user","kind":"disliking","target":"celery","provenance":"explicit","intensity":"strong","modality":"asserted","attribution":"direct","recordedAt":1,"evidenceIDs":["e"]}"#)
    }
    func testQuotedHypotheticalAndThirdPartyTasteRemainAttributed() throws {
        let quoted = BrainTasteRecord(id: "q", subjectID: BrainIdentity.userID, kind: .disliking, target: "celery", provenance: .explicit, durability: .enduring, recordedAt: 1, evidenceIDs: ["e"], intensity: .strong, modality: .asserted, attribution: .quoted)
        XCTAssertFalse(quoted.isEnduringTaste)
        let hypothetical = BrainTasteRecord(id: "h", subjectID: BrainIdentity.userID, kind: .liking, target: "tea", provenance: .inferred, durability: .enduring, recordedAt: 1, evidenceIDs: ["e"], modality: .hypothetical, attribution: .direct)
        XCTAssertFalse(hypothetical.isEnduringTaste)
        let other = BrainTasteRecord(id: "o", subjectID: "person:synthetic-friend", kind: .disliking, target: "celery", provenance: .explicit, recordedAt: 1, evidenceIDs: ["e"], attribution: .thirdParty)
        XCTAssertEqual(other.attribution, .thirdParty); XCTAssertNotEqual(other.subjectID, BrainIdentity.userID)
        let restored = try JSONDecoder().decode(BrainTasteRecord.self, from: JSONEncoder().encode(quoted))
        XCTAssertEqual(restored.attribution, .quoted); XCTAssertEqual(restored.intensity, .strong)
    }
    func testLegacyPolicyPreservesIndependentJudgmentInsteadOfAutomaticAgreement() throws {
        let legacy = try decode(BrainConversationPolicy.self, #"{"revision":1,"requiresTruthfulIdentity":true,"questionsAreOptional":true,"requiresAcknowledgment":false,"instructions":"legacy"}"#)
        XCTAssertTrue(legacy.requiresIndependentJudgment)
        XCTAssertTrue(BrainConversationPolicy.canonical.requiresIndependentJudgment)
        let encoded = try JSONEncoder().encode(BrainConversationPolicy.canonical)
        let restored = try JSONDecoder().decode(BrainConversationPolicy.self, from: encoded)
        XCTAssertTrue(restored.requiresIndependentJudgment)
        XCTAssertTrue(restored.questionsAreOptional)
    }

    func testEvidenceContentAndDerivationRootsSurviveWireAndLegacyDefaults() throws {
        let source = try decode(BrainEvidence.self, #"{"id":"e1","sourceKind":"toolObservation","speakerID":"self:agent","threadID":"t","observedAt":1,"recordedAt":2,"accessScope":"thread","text":"Synthetic sanitized observation","parentEvidenceIDs":["e0"]}"#)
        XCTAssertEqual(source.text, "Synthetic sanitized observation")
        XCTAssertEqual(source.parentEvidenceIDs, ["e0"])
        XCTAssertEqual(source.speakerID, BrainIdentity.agentID)
        let restored = try JSONDecoder().decode(BrainEvidence.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored.text, "Synthetic sanitized observation")
        XCTAssertEqual(restored.parentEvidenceIDs, ["e0"])
        let legacy = try decode(BrainEvidence.self, #"{"id":"e","sourceKind":"userMessage","speakerID":"self:user","threadID":"t","observedAt":1,"recordedAt":1,"accessScope":"thread"}"#)
        XCTAssertNil(legacy.text); XCTAssertNil(legacy.parentEvidenceIDs)
    }

}
