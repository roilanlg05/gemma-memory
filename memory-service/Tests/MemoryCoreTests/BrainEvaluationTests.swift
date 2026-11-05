import Foundation
import XCTest
@testable import MemoryCore

final class BrainEvaluationTests: XCTestCase {
    private func fact(subject: String = "self:user", number: Double = 3, state: String = "current",
                      role: String = "user", sources: [String] = ["m1"]) -> BrainEvaluationAssertion {
        BrainEvaluationAssertion(subject: subject, predicate: "tokenCount", value: "blue", number: number,
                                 state: state, sourceRole: role, sourceIDs: sources)
    }
    private func sample(_ id: String = "sample", category: String = "factsCorrections") -> BrainEvaluationCase {
        BrainEvaluationCase(id: id, category: category, language: "en",
            messages: [BrainEvaluationMessage(id: "m1", role: "user", text: "I have 3 blue tokens.", state: "active"),
                       BrainEvaluationMessage(id: "old", role: "user", text: "I have 2 blue tokens.", state: "withdrawn")],
            query: "How many blue tokens do I have?", expectedEvidenceIDs: ["m1"],
            expectedAssertions: [fact()], forbiddenAssertions: [fact(number: 2, sources: ["old"])], legacyRecall: false)
    }
    private func prediction(_ id: String = "sample", assertions: [BrainEvaluationAssertion]? = nil,
                            evidence: [String] = ["m1"], unsupported: String? = nil) -> BrainEvaluationPrediction {
        BrainEvaluationPrediction(caseID: id, unsupportedReason: unsupported, evidenceIDs: evidence,
                                  assertions: assertions ?? [fact()])
    }
    private func fixtures() throws -> [BrainEvaluationCase] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "brain-scenarios", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([BrainEvaluationCase].self, from: Data(contentsOf: url))
    }

    // Catches counting absent/empty predictions as successes or omitting missing from denominators.
    func testMissingAndEmptyOutputsNeverReceivePerfectAccuracy() throws {
        let absent = try BrainEvaluation.score(cases: [sample()], predictions: [])
        XCTAssertEqual(absent.counts.total, 1)
        XCTAssertEqual(absent.counts.missing, 1)
        XCTAssertEqual(absent.counts.correct, 0)
        XCTAssertEqual(absent.exactAssertionAccuracy, 0)
        let empty = try BrainEvaluation.score(cases: [sample()], predictions: [prediction(assertions: [], evidence: [])])
        XCTAssertEqual(empty.counts.evaluated, 1)
        XCTAssertEqual(empty.counts.correct, 0)
        XCTAssertEqual(empty.exactAssertionAccuracy, 0)
        XCTAssertNil(try BrainEvaluation.score(cases: [], predictions: []).exactAssertionAccuracy)
    }

    // Catches ignoring subject, numeric value, role, state or source identity.
    func testWrongSpeakerNumberStateOrWithdrawnEvidenceFails() throws {
        for a in [fact(subject: "self:agent"), fact(number: 30), fact(state: "completed"),
                  fact(role: "assistant"), fact(sources: ["old"]), fact(sources: ["invented"])] {
            let report = try BrainEvaluation.score(cases: [sample()], predictions: [prediction(assertions: [a])])
            XCTAssertEqual(report.counts.evaluated, 1)
            XCTAssertEqual(report.counts.correct, 0)
            XCTAssertEqual(report.results.first?.outcome, "incorrect")
            XCTAssertFalse(report.results.first?.reasons.isEmpty ?? true)
        }
    }

    func testForbiddenAndUnexpectedAssertionsFail() throws {
        for extra in [fact(number: 2, sources: ["old"]), fact(subject: "third:synthetic")] {
            let report = try BrainEvaluation.score(cases: [sample()], predictions: [prediction(assertions: [fact(), extra])])
            XCTAssertEqual(report.counts.correct, 0)
            XCTAssertEqual(report.counts.evaluated, 1)
            XCTAssertEqual(report.results.first?.outcome, "incorrect")
        }
    }

    // Catches lexical matching and ignoring evidence; evidence order must not affect a true match.
    func testExactAssertionsAndEvidenceRequiredButOrderingDoesNotMatter() throws {
        var c = sample()
        c.messages.append(BrainEvaluationMessage(id: "m2", role: "user", text: "The tokens are for practice.", state: "active"))
        c.expectedEvidenceIDs = ["m1", "m2"]
        c.expectedAssertions[0].sourceIDs = ["m1", "m2"]
        var a = fact(sources: ["m2", "m1"])
        let good = try BrainEvaluation.score(cases: [c], predictions: [prediction(assertions: [a], evidence: ["m2", "m1"])])
        XCTAssertEqual(good.counts.correct, 1)
        XCTAssertEqual(good.exactAssertionAccuracy, 1)
        XCTAssertEqual(try BrainEvaluation.score(cases: [c], predictions: [prediction(assertions: [a])]).counts.correct, 0)
        a.value = "3 blue tokens user current m1 m2"
        XCTAssertEqual(try BrainEvaluation.score(cases: [c], predictions: [prediction(assertions: [a], evidence: ["m1", "m2"])]).counts.correct, 0)
    }

    func testUnsupportedMissingAndCategoryCountsRemainSeparate() throws {
        let cases = [sample("a"), sample("b", category: "temporal"), sample("c", category: "temporal")]
        let report = try BrainEvaluation.score(cases: cases, predictions: [prediction("a"), prediction("b", assertions: [], evidence: [], unsupported: "No temporal support")])
        XCTAssertEqual(report.counts.total, 3)
        XCTAssertEqual(report.counts.evaluated, 1)
        XCTAssertEqual(report.counts.unsupported, 1)
        XCTAssertEqual(report.counts.missing, 1)
        XCTAssertEqual(report.counts.correct, 1)
        XCTAssertEqual(report.exactAssertionAccuracy, 0.5)
        XCTAssertEqual(try XCTUnwrap(report.coverage), 1.0 / 3.0, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(report.overallExactAssertionAccuracy), 1.0 / 3.0, accuracy: 0.00001)
        XCTAssertEqual(report.byCategory["temporal"]?.unsupported, 1)
        XCTAssertEqual(report.byCategory["temporal"]?.missing, 1)
        let unsupported = try BrainEvaluation.score(cases: [sample()], predictions: [prediction(assertions: [], evidence: [], unsupported: "Not implemented")])
        XCTAssertNil(unsupported.exactAssertionAccuracy)
        XCTAssertEqual(unsupported.overallExactAssertionAccuracy, 0)
    }

    // Catches ambiguous or malformed runs silently overwritten or coerced to a score.
    func testDuplicateUnknownAndMalformedInputsAreRejected() throws {
        XCTAssertThrowsError(try BrainEvaluation.score(cases: [sample(), sample()], predictions: []))
        XCTAssertThrowsError(try BrainEvaluation.score(cases: [sample()], predictions: [prediction(), prediction()]))
        XCTAssertThrowsError(try BrainEvaluation.score(cases: [sample()], predictions: [prediction("unknown")]))
        var c = sample(); c.expectedAssertions = []
        XCTAssertThrowsError(try BrainEvaluation.score(cases: [c], predictions: []))
        c = sample(); c.expectedEvidenceIDs = ["old"]
        XCTAssertThrowsError(try BrainEvaluation.score(cases: [c], predictions: []))
        c = sample(); c.messages.append(c.messages[0])
        XCTAssertThrowsError(try BrainEvaluation.score(cases: [c], predictions: []))
        XCTAssertThrowsError(try BrainEvaluation.score(cases: [sample()], predictions: [prediction(unsupported: "Not implemented")]))
        XCTAssertThrowsError(try BrainEvaluation.score(cases: [sample()], predictions: [prediction(assertions: [], evidence: [], unsupported: " ")]))
    }

    func testSyntheticCorpusHasRequiredCoverageAndCheckableExpectations() throws {
        let cases = try fixtures()
        XCTAssertEqual(cases.count, 200)
        XCTAssertEqual(Dictionary(grouping: cases, by: \.category).mapValues(\.count), ["factsCorrections": 40, "temporal": 30, "forgettingProvenance": 30, "conversationAffect": 40, "procedure": 30, "failurePortability": 30])
        XCTAssertEqual(Set(cases.map(\.id)).count, 200)
        for group in Dictionary(grouping: cases, by: \.category).values {
            XCTAssertEqual(Set(group.map(\.language)), ["es", "en"])
            XCTAssertTrue(group.allSatisfy { !$0.expectedAssertions.isEmpty && !$0.expectedEvidenceIDs.isEmpty && !$0.forbiddenAssertions.isEmpty })
            XCTAssertGreaterThan(Set(group.map { $0.expectedAssertions }).count, 10)
        }
        let report = try BrainEvaluation.score(cases: cases, predictions: [])
        XCTAssertEqual(report.counts.missing, 200)
        XCTAssertEqual(report.overallExactAssertionAccuracy, 0)
    }

    func testLegacyRetrievalBaselineReportsOnlySupportedRecall() throws {
        let cases = try fixtures()
        var predictions: [BrainEvaluationPrediction] = []
        for c in cases {
            guard c.legacyRecall else {
                predictions.append(prediction(c.id, assertions: [], evidence: [], unsupported: "Legacy adapter unsupported: \(c.category)"))
                continue
            }
            XCTAssertEqual(c.category, "factsCorrections")
            XCTAssertEqual(c.messages.count, 1)
            let store = try MemoryStore(inMemory: true, embeddingDim: 4)
            // Explicit pre-extracted facts: this does not measure model/extraction correctness.
            for m in c.messages {
                try store.upsert(Node(id: m.id, kind: "fact", label: m.text, body: m.text, layer: .daily,
                    createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 5, decayRate: 0,
                    confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: m.id,
                    origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
            }
            let nodes = try MemoryRetriever(store: store, embedder: nil).retrieve(query: c.query, k: 4, now: 1)
            // Evidence-only prediction deliberately cannot pass the semantic assertion contract.
            predictions.append(prediction(c.id, assertions: [], evidence: nodes.compactMap(\.sourceRef)))
        }
        let report = try BrainEvaluation.score(cases: cases, predictions: predictions)
        XCTAssertEqual(report.counts.total, 200)
        XCTAssertEqual(report.counts.evaluated, 10)
        XCTAssertEqual(report.counts.unsupported, 190)
        XCTAssertEqual(report.counts.correct, 0)
        XCTAssertEqual(report.counts.missing, 0)
        let supportedIDs = Set(cases.filter(\.legacyRecall).map(\.id))
        let hits = predictions.filter { supportedIDs.contains($0.caseID) && $0.evidenceIDs == ["m1"] }.count
        XCTAssertEqual(hits, 10)
        print("LEGACY_BASELINE total=\(report.counts.total) evaluated=\(report.counts.evaluated) unsupported=\(report.counts.unsupported) missing=\(report.counts.missing) exactAssertionCorrect=\(report.counts.correct) evidenceSelectionHits=\(hits)/10; pre-extracted FTS only, no model semantic accuracy")
    }
}
