import Foundation
import BrainContract
import XCTest

final class BrainLongitudinalEvaluationTests: XCTestCase {
    func testUnmappedSourceCountsAgainstPrecision() throws {
        let (_, cases) = try EvaluationCorpusManifest.load()
        let fixture = try XCTUnwrap(cases.first { !$0.expectedEvidenceIDs.isEmpty })
        let expected = try XCTUnwrap(fixture.expectedEvidenceIDs.first)
        let sources = EvaluationSourceSample.sourceIDs(["known", "unrelated"], known: ["known": expected])
        let result = EvaluationSourceMetrics([(fixture, .init(deliveredIDs: sources, latencyMilliseconds: 1,
                                                              withdrawnTextIDs: []))])
        XCTAssertEqual(result.deliveredSources, 2)
        XCTAssertEqual(result.matchedSources, 1)
        XCTAssertEqual(result.precision, 0.5)
    }

    func testWithdrawnSourceLeakIsCountedEvenOutsideRenderedContext() {
        let withdrawnID = "withdrawn-original"
        let original = "A forgotten synthetic sentence."
        let reference = BrainEvidence(id: "other-source", sourceKind: .derived, speakerID: "fixture",
            threadID: "thread", observedAt: 1, recordedAt: 1, accessScope: .user, text: original)
        let unit = BrainMessageUnit(id: "recent", speakerID: "self:user", text: "A different sentence.",
                                    observedAt: 1, evidenceIDs: [withdrawnID])
        let omission = BrainContextTruncation(evidenceID: withdrawnID, originalUTF8Bytes: 20,
                                              includedUTF8Bytes: 0, reason: "omitted")
        let cases = [
            BrainContextBundle(renderedContext: "", recentMessageUnits: [], sourceReferences: [reference], revision: 1, policyRevision: 1),
            BrainContextBundle(renderedContext: "", recentMessageUnits: [unit], sourceReferences: [], revision: 1, policyRevision: 1),
            BrainContextBundle(renderedContext: "", recentMessageUnits: [], sourceReferences: [], revision: 1, policyRevision: 1,
                               truncations: [omission])
        ]
        for bundle in cases {
            XCTAssertTrue(EvaluationSourceSample.withdrawnSourcesExposed(in: bundle, evidenceID: withdrawnID, original: original))
        }
        let clean = BrainContextBundle(renderedContext: "Independent context.", recentMessageUnits: [],
                                       sourceReferences: [], revision: 1, policyRevision: 1)
        XCTAssertFalse(EvaluationSourceSample.withdrawnSourcesExposed(in: clean, evidenceID: withdrawnID, original: original))
    }

    func testOfflineCorpusEvaluationProducesMeasuredAndUnmeasuredResults() async throws {
        let report = try await BrainLongitudinalEvaluation.run()
        XCTAssertEqual(report.corpus.caseCount, 200)
        XCTAssertEqual(report.cases.count, 200)
        XCTAssertEqual(report.partitions[.tuning]?.counts.total, 140)
        XCTAssertEqual(report.partitions[.heldOut]?.counts.total, 60)
        XCTAssertEqual(report.assertions.counts.evaluated, 5)
        XCTAssertEqual(report.assertions.counts.unsupported, 195)
        XCTAssertEqual(report.assertions.counts.missing, 0)
        XCTAssertLessThan(try XCTUnwrap(report.assertions.overallExactAssertionAccuracy), 1)
        XCTAssertEqual(report.context.observedCases, 150)
        XCTAssertEqual(report.context.latencyMilliseconds.samples, 150)
        XCTAssertEqual(report.context.withdrawnSources, 25)
        XCTAssertEqual(report.context.withdrawnSourcesExposed, 0)
        XCTAssertEqual(report.cases.filter { $0.restartReplayStable == true }.count, 150)
        XCTAssertEqual(Set(report.retrieval.keys), [.direct, .hybrid, .vectorOnly])
        XCTAssertTrue(report.retrieval.values.allSatisfy { $0.observedCases == 150 })
        XCTAssertNotNil(report.unmeasured["realProviderAdherence"])
        XCTAssertNotNil(report.unmeasured["humanConversationalQuality"])

        if let path = ProcessInfo.processInfo.environment["BRAIN_EVALUATION_OUTPUT"] {
            let output = URL(fileURLWithPath: path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output, options: .atomic)
            print("TASK17_CORPUS_REPORT \(output.path)")
        }
    }
}
