import XCTest
@testable import BrainContract

final class AdaptiveContextContractTests: XCTestCase {
    func testLegacyBudgetDecodesAndAllReservationsAreValidatedWithoutOverflow() throws {
        let old = try JSONDecoder().decode(BrainContextBudget.self, from: Data(#"{"contextTokens":4096,"outputTokens":512}"#.utf8))
        XCTAssertEqual(old.systemTokens, 0)
        XCTAssertEqual(old.toolTokens, 0)
        XCTAssertNoThrow(try BrainContextBudget(contextTokens: 4096, outputTokens: 512, systemTokens: 1024, toolTokens: 256))
        XCTAssertThrowsError(try BrainContextBudget(contextTokens: 4096, outputTokens: 512, systemTokens: 3500, toolTokens: 256))
        XCTAssertThrowsError(try BrainContextBudget(contextTokens: Int.max, outputTokens: Int.max, systemTokens: 1, toolTokens: 1))
        XCTAssertThrowsError(try BrainContextBudget(contextTokens: 100, outputTokens: 0, systemTokens: -1, toolTokens: 0))
    }
    func testOldMessageAndBundleDecodeWithoutNewMetadata() throws {
        let unit = try JSONDecoder().decode(BrainMessageUnit.self, from: Data(#"{"id":"x","speakerID":"self:user","text":"hola","observedAt":1,"evidenceIDs":[]}"#.utf8))
        XCTAssertNil(unit.groupID)
        let bundle = try JSONDecoder().decode(BrainContextBundle.self, from: Data(#"{"renderedContext":"","recentMessageUnits":[],"sourceReferences":[],"revision":0,"policyRevision":2}"#.utf8))
        XCTAssertNil(bundle.accounting)
        XCTAssertNil(bundle.truncations)
    }
    func testExactCitationsUseExplicitDeliveryIndependentlyOfOmissions() throws {
        let whole = BrainEvidence(id: "raw", sourceKind: .userMessage, speakerID: "self:user",
                                  threadID: "t", observedAt: 1, recordedAt: 1, accessScope: .thread)
        let support = BrainEvidence(id: "gist", sourceKind: .userMessage, speakerID: "self:user",
                                    threadID: "t", observedAt: 2, recordedAt: 2, accessScope: .thread)
        let unit = BrainMessageUnit(id: "raw", speakerID: "self:user", text: "hola",
                                    observedAt: 1, evidenceIDs: ["raw"])
        let omission = BrainContextTruncation(evidenceID: "raw", originalUTF8Bytes: 4,
                                              includedUTF8Bytes: 0, reason: "quoteOmittedBudget")
        func roundTrip(uses: [String: [BrainContextSourceUse]]?) throws -> BrainContextBundle {
            let bundle = BrainContextBundle(renderedContext: "[gist asserted sources=gist]\nA greeting.",
                                            recentMessageUnits: [unit], sourceReferences: [whole, support],
                                            revision: 1, policyRevision: 2, truncations: [omission], sourceUses: uses)
            return try JSONDecoder().decode(BrainContextBundle.self, from: JSONEncoder().encode(bundle))
        }
        let current = try roundTrip(uses: ["raw": [.recentWhole], "gist": [.derivedSupport]])
        XCTAssertTrue(current.exactCitationSourceReferences(includingRenderedContext: true, forwardedRecentUnitIDs: []).isEmpty)
        XCTAssertTrue(current.exactCitationSourceReferences(includingRenderedContext: false, forwardedRecentUnitIDs: []).isEmpty)
        XCTAssertEqual(current.exactCitationSourceReferences(includingRenderedContext: false, forwardedRecentUnitIDs: ["raw"]).map(\.id), ["raw"])
        XCTAssertEqual(current.sourceUses?["raw"], [.recentWhole])
        XCTAssertEqual(current.truncations, [omission])
        let legacy = try roundTrip(uses: nil)
        XCTAssertNil(legacy.sourceUses)
        XCTAssertTrue(legacy.exactCitationSourceReferences(includingRenderedContext: true, forwardedRecentUnitIDs: ["raw"]).isEmpty)
    }
    func testZeroReservationsPreserveLegacyWireShapeAndNonzeroReservationsRoundTrip() throws {
        let legacy = try BrainContextBudget(contextTokens: 4096, outputTokens: 512)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["contextTokens", "outputTokens"])
        let reserved = try BrainContextBudget(contextTokens: 4096, outputTokens: 512, systemTokens: 256, toolTokens: 128)
        XCTAssertEqual(try JSONDecoder().decode(BrainContextBudget.self, from: JSONEncoder().encode(reserved)), reserved)
    }

}
