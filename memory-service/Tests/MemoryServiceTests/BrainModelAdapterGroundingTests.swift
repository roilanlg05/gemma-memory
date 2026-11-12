import BrainContract
import MemoryCore
import XCTest
@testable import MemoryService

final class BrainModelAdapterGroundingTests: XCTestCase {
    private struct FixedOutput: ModelTextClient {
        let response: String

        func generate(prompt: String, options: ModelTextOptions) async throws -> String { response }
    }

    private func proposals(for text: String, modelOutput: String) async throws -> [BrainTurnProposal] {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let grant = ConsolidationEvidenceAdapter.authorization(threads: ["grounding"])
        let brain = BrainStore(store: store, authorization: grant)
        let extractor = GatewayTurnExtractor(model: FixedOutput(response: modelOutput), brain: brain)
        let source = BrainEvidence(id: "grounding-source", sourceKind: .userMessage, speakerID: BrainIdentity.userID,
            threadID: "grounding", observedAt: 20, recordedAt: 20, span: nil, accessScope: .user, text: text)
        return try await extractor.extract(source: source)
    }

    func testVerbatimNegativeAdviceCannotBecomePermissionToAdvise() async throws {
        let updates = try await proposals(for: "No quiero que me aconsejes.", modelOutput: #"{"updates":[{"kind":"advice","quote":"No quiero que me aconsejes.","mode":"welcome","qualification":"firstPerson","enduring":true}]}"#)
        XCTAssertFalse(updates.contains { $0.update.claim.value == .string("welcome") })
    }

    func testVerbatimLikingCannotBecomeDisliking() async throws {
        let updates = try await proposals(for: "Me gusta Jhay Wheeler.", modelOutput: #"{"updates":[{"kind":"taste","taste":"disliking","quote":"Me gusta Jhay Wheeler.","target":"Jhay Wheeler","domain":"music","qualification":"firstPerson","enduring":true}]}"#)
        XCTAssertTrue(updates.isEmpty)
    }

    func testTimeLimitedTasteCannotBecomeEnduring() async throws {
        let updates = try await proposals(for: "Hoy me gusta escuchar reguetón.", modelOutput: #"{"updates":[{"kind":"taste","taste":"liking","quote":"me gusta escuchar reguetón.","target":"reguetón","domain":"music","qualification":"firstPerson","enduring":true}]}"#)
        XCTAssertTrue(updates.allSatisfy { $0.update.claim.validTo != nil })
    }

    func testFirstPersonStanceCannotBindToAnotherPersonsTarget() async throws {
        let updates = try await proposals(for: "Me gusta el cine, pero Mateo odia el sushi.", modelOutput: #"{"updates":[{"kind":"taste","taste":"liking","quote":"Me gusta el cine, pero Mateo odia el sushi.","target":"sushi","domain":"food","qualification":"firstPerson","enduring":true}]}"#)
        XCTAssertTrue(updates.isEmpty)
    }

    func testPartialVerbatimExcerptInsideAQuoteCannotBecomeAPersonalTaste() async throws {
        let updates = try await proposals(for: "Leí «A veces me gusta el sushi de aquí».", modelOutput: #"{"updates":[{"kind":"taste","taste":"liking","quote":"me gusta el sushi","target":"sushi","domain":"food","qualification":"firstPerson","enduring":true}]}"#)
        XCTAssertTrue(updates.isEmpty)
    }

    func testQuestionOrSubordinateTargetCannotBecomeAnEnduringTaste() async throws {
        let fixtures = [("¿Me gusta el sushi?", "Me gusta el sushi"),
                        ("No sé si me gusta el sushi.", "me gusta el sushi"),
                        ("Me gusta que Mateo odie el sushi.", "Me gusta que Mateo odie el sushi.")]
        for (text, quote) in fixtures {
            let updates = try await proposals(for: text, modelOutput: #"{"updates":[{"kind":"taste","taste":"liking","quote":"\#(quote)","target":"sushi","domain":"food","enduring":true}]}"#)
            XCTAssertTrue(updates.isEmpty)
        }
    }

    func testExplicitCorrectionRetiresEarlierEnduringTaste() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let grant = ConsolidationEvidenceAdapter.authorization(threads: ["tastes"])
        let brain = BrainStore(store: store, authorization: grant)

        let initial = "Me gusta el sushi."
        let correction = "Ya no me gusta el sushi."
        let fixtures = [(initial, "liking", "mild", false), (initial, "liking", "strong", false),
                        (correction, "disliking", "strong", true),
                        ("En realidad, me gusta el sushi.", "liking", "mild", true)]
        for (index, fixture) in fixtures.enumerated() {
            let (text, kind, intensity, corrects) = fixture
            let timestamp = Double(20 + index)
            let output = #"{"updates":[{"kind":"taste","taste":"\#(kind)","quote":"\#(text)","target":"sushi","domain":"food","intensity":"\#(intensity)","enduring":true,"correction":\#(corrects)}]}"#
            let extractor = GatewayTurnExtractor(model: FixedOutput(response: output), brain: brain)
            let turns = BrainTurnService(store: store, authorization: grant, extractor: extractor)
            let request = try BrainTurnRequest(clientOperationID: "taste-\(index)", threadID: "tastes",
                message: .init(id: "taste-message-\(index)", speakerID: BrainIdentity.userID, text: text,
                    observedAt: timestamp, evidenceIDs: []), budget: .init(contextTokens: 4_096, outputTokens: 128))
            let result = try await turns.begin(request)
            XCTAssertEqual(result.completion.state, .committed)
            let profile = try TastePreferenceService(brain: brain).profile(subject: BrainIdentity.userID, domain: "food",
                                                                           context: nil, now: timestamp)
            XCTAssertEqual(profile.records.map { $0.kind.rawValue }, [kind])
            XCTAssertEqual(profile.records.map { $0.intensity?.rawValue }, [intensity])
        }
    }
}
