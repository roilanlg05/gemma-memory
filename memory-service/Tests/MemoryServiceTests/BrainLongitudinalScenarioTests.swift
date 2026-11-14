import Foundation
import GRDB
import XCTest
import BrainContract
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import MemoryCore
@testable import MemoryService

final class BrainLongitudinalScenarioTests: XCTestCase {
    private static let auth: HTTPFields = [.authorization: "Bearer test-token", .contentType: "application/json"]
    private static let reply = "Synthetic provider reply."

    private struct Result: Encodable {
        let id: String
        let checks: [String: Bool]
        let metricsMilliseconds: [String: Double]
        let unmeasured: [String: String]
    }

    private static func report(_ id: String, _ checks: [String: Bool], timings: [String: Double] = [:],
                               unmeasured: [String: String] = [:]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let result = Result(id: id, checks: checks, metricsMilliseconds: timings, unmeasured: unmeasured)
        print("TASK17_LONGITUDINAL " + String(decoding: try encoder.encode(result), as: UTF8.self))
        for (name, passed) in checks.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(passed, "\(id).\(name)")
        }
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant = .now) -> Double {
        let parts = start.duration(to: end).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    private actor RecordingProvider: AgentModelClient {
        struct Call: Sendable {
            let system: String
            let user: String
            let offeredTools: [String]
            let time: ContinuousClock.Instant
        }

        let unavailableTools: [String]
        private(set) var calls: [Call] = []

        init(unavailableTools: [String] = []) {
            self.unavailableTools = unavailableTools
        }

        func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
            let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            calls.append(.init(system: systemPrompt, user: userPrompt, offeredTools: names, time: .now))
            let attempts = calls.count == 1 ? unavailableTools.map { AgentToolCall(name: $0, args: "{}") } : []
            return .init(text: attempts.isEmpty ? BrainLongitudinalScenarioTests.reply : "", toolCalls: attempts)
        }
    }

    private static func makeApp(_ store: MemoryStore, provider: RecordingProvider = RecordingProvider(),
                                model: any ModelTextClient = DefaultNoOpModelClient()) async throws
        -> (some ApplicationProtocol, Services) {
        let services = await Services(store: store, transcript: TranscriptStore(dbQueue: store.dbQueue),
            embedder: FakeEmbedder(dimension: store.embeddingDim), bearerToken: "test-token", modelClient: model,
            agentClient: provider)
        return (try await buildApp(services: services, port: 0), services)
    }

    private static func post<T: Encodable>(_ body: T, to uri: String, using client: any TestClientProtocol) async throws -> TestResponse {
        try await client.execute(uri: uri, method: .post, headers: auth,
                                 body: ByteBuffer(bytes: try JSONEncoder().encode(body)))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        XCTAssertEqual(response.status, .ok, String(buffer: response.body))
        return try JSONDecoder().decode(type, from: Data(response.body.readableBytesView))
    }

    private static func budget() throws -> BrainContextBudget {
        try .init(contextTokens: 4096, outputTokens: 396, systemTokens: 900, toolTokens: 800)
    }

    private static func turn(_ id: String, thread: String, text: String,
                             budget explicitBudget: BrainContextBudget? = nil) throws -> BrainTurnRequest {
        try .init(clientOperationID: id, threadID: thread,
                  message: .init(id: "message-\(id)", speakerID: BrainIdentity.userID, text: text,
                                 observedAt: 0, evidenceIDs: []), budget: explicitBudget ?? budget())
    }

    private struct GatewayTurn: Encodable {
        let clientOperationID: String
        let threadId: String
        let text: String
        let language: String
    }

    @discardableResult
    private static func gateway(_ id: String, thread: String, text: String, language: String = "en",
                                using client: any TestClientProtocol) async throws -> String {
        let body = GatewayTurn(clientOperationID: id, threadId: thread, text: text, language: language)
        let response = try await post(body, to: "/v1/agent/turn", using: client)
        return try XCTUnwrap(decode([String: String].self, response)["reply"])
    }

    private static func evidence(_ id: String, thread: String, text: String, time: Double,
                                 scope: BrainAccessScope = .user, kind: BrainSourceKind = .userMessage) -> BrainEvidence {
        .init(id: id, sourceKind: kind, speakerID: kind == .assistantMessage ? BrainIdentity.agentID : BrainIdentity.userID,
              threadID: thread, observedAt: time, recordedAt: time, accessScope: scope, text: text)
    }

    private static func seedProject(_ store: MemoryStore) throws -> BrainStore {
        let owner = ConsolidationEvidenceAdapter.ownerID
        let lights = "project:harbor-lights"
        let ledger = "project:harbor-ledger"
        let brain = BrainStore(store: store, authorization: .init(principal: owner, owner: owner,
            subjects: [lights, ledger], scopes: [.user, .thread], threads: ["first-session", "later-session", "private-session"],
            sourceSpeakers: [.userMessage: [BrainIdentity.userID], .assistantMessage: [BrainIdentity.agentID]],
            mayCommitClaims: true))
        let items: [(String, String, RecallClaimPredicate, String, BrainEvidence, String?)] = [
            ("lights-name", lights, .projectName, "Harbor Lights",
             evidence("lights-name-source", thread: "first-session", text: "We opened Harbor Lights.", time: 1), nil),
            ("lights-alias", lights, .projectAlias, "dock lanterns",
             evidence("lights-alias-source", thread: "first-session", text: "Call Harbor Lights the dock lanterns.", time: 2), nil),
            ("lights-old", lights, .checkpoint, "Order copper housings",
             evidence("lights-old-source", thread: "first-session", text: "Next is the copper housing order.", time: 3), nil),
            ("ledger-name", ledger, .projectName, "Harbor Ledger",
             evidence("ledger-name-source", thread: "first-session", text: "There is also Harbor Ledger.", time: 4), nil),
            ("ledger-private", ledger, .progress, "Private cobalt entry",
             evidence("ledger-private-source", thread: "private-session", text: "Private cobalt entry", time: 5, scope: .thread), nil),
            ("lights-current", lights, .checkpoint, "Test the brass sockets",
             evidence("lights-current-source", thread: "later-session", text: "Correction: the next step is testing brass sockets.", time: 7),
             "lights-old"),
        ]
        _ = try brain.recordEvidence(evidence("opening-source", thread: "later-session", text: "Reopening the dock lanterns.", time: 6),
                                     idempotencyKey: "opening")
        _ = try brain.recordEvidence(evidence("closing-source", thread: "later-session", text: "We stopped at the workbench.",
                                              time: 8, kind: .assistantMessage), idempotencyKey: "closing")
        for (id, subject, predicate, value, source, predecessor) in items {
            let claim = BrainClaim(id: id, revision: 0, subject: subject, predicate: predicate.rawValue, value: .string(value),
                modality: .asserted, status: .active, validFrom: source.observedAt, recordedAt: source.recordedAt,
                evidenceIDs: [source.id], supersedesID: predecessor)
            let result = try brain.commit(.init(clientOperationID: "seed-\(id)", evidence: [source],
                updates: [.init(claim: claim)], expectedRevision: brain.revision()))
            XCTAssertEqual(result.state, .committed)
        }
        return brain
    }

    func testProjectResumptionAcrossSessionsAndForgetInvalidatesPrefetch() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let brain = try Self.seedProject(store)
        let provider = RecordingProvider()
        let (app, services) = try await Self.makeApp(store, provider: provider)
        try await app.test(.router) { client in
            let named = "Resume Harbor Lights."
            let indirect = "Sigamos con dock lanterns."
            let cue = try BrainContextRequest(clientOperationID: "indirect-cue", threadID: "cue-chat", query: indirect,
                                             budget: Self.budget(), quoteEvidenceIDs: [], detailEvidenceIDs: [])
            let cueStart = ContinuousClock.now
            let cueResponse = try await Self.post(cue, to: "/v1/brain/context?mode=cue", using: client)
            let cueLatency = Self.milliseconds(from: cueStart)
            let candidate = try Self.decode(BrainContextBundle.self, cueResponse)
            let cueReadOnly = try services.transcript.range(threadId: "cue-chat", from: 1, to: 2).isEmpty
            let choice = try BrainContextRequest(clientOperationID: "ambiguous", threadID: "cue-chat", query: "Resume Harbor.",
                                                budget: Self.budget())
            let ambiguous = try await Self.decode(BrainContextBundle.self,
                Self.post(choice, to: "/v1/brain/context?mode=cue", using: client))

            let started = ContinuousClock.now
            let reply = try await Self.gateway("named-turn", thread: "fresh-generation", text: named, using: client)
            let calls = await provider.calls
            let first = try XCTUnwrap(calls.first)

            let unknown = try Self.turn("unknown", thread: "fresh-unknown", text: "Resume Harbor Ledger.")
            let unknownResult = try await Self.decode(BrainTurnResult.self, Self.post(unknown, to: "/v1/brain/turns/begin", using: client))
            let unknownContext = try XCTUnwrap(unknownResult.context)
            let original = try BrainContextRequest(clientOperationID: "foreign-quote", threadID: "fresh-unknown", query: "Quote it.",
                budget: Self.budget(), quoteEvidenceIDs: ["lights-current-source"])
            let denied = try await Self.post(original, to: "/v1/brain/context", using: client)

            let draft = try BrainContextRequest(clientOperationID: "after-forget", threadID: "fresh-prefetch", query: named,
                                                budget: Self.budget(), quoteEvidenceIDs: [], detailEvidenceIDs: [])
            let prepared = try await Self.decode(BrainContextBundle.self, Self.post(draft, to: "/v1/brain/context?mode=prefetch", using: client))
            let forget = BrainForgetRequest(clientOperationID: "forget-checkpoint", expectedRevision: try brain.revision(),
                scope: .init(kind: .evidence, id: "lights-current-source"), threadID: "later-session")
            let receipt = try await Self.decode(BrainForgetReceipt.self, Self.post(forget, to: "/v1/brain/forget", using: client))
            let finalized = try Self.turn("after-forget", thread: "fresh-prefetch", text: named)
            let final = try await Self.decode(BrainTurnResult.self, Self.post(finalized, to: "/v1/brain/turns/begin", using: client))
            let rechecked = try XCTUnwrap(final.context)
            let checkpoint = "Test the brass sockets"
            try Self.report("project-resumption", [
                "namedProjectSelection": first.user.contains("[recalled project sources=lights-name-source]"),
                "indirectAliasProjectSelection": candidate.renderedContext.contains("Harbor Lights")
                    && candidate.sourceUses?["lights-alias-source"]?.contains(.recalledSupport) == true,
                "ambiguousSimilarNamesClarify": ambiguous.renderedContext.contains("Which project did you mean?")
                    && ambiguous.renderedContext.contains("Harbor Ledger / Harbor Lights"),
                "correctedCheckpointAccuracy": candidate.renderedContext.contains(checkpoint)
                    && !candidate.renderedContext.contains("Order copper housings"),
                "checkpointProvenance": candidate.sourceUses?["lights-current-source"] == [.recalledSupport]
                    && candidate.sourceReferences.contains { $0.id == "lights-current-source" && $0.threadID == "later-session" },
                "unknownProgressOmitted": unknownContext.renderedContext.contains("Harbor Ledger")
                    && !unknownContext.renderedContext.contains("reported progress")
                    && !unknownContext.renderedContext.contains("reported checkpoint"),
                "inaccessibleSupportOmitted": denied.status == .forbidden
                    && !unknownContext.renderedContext.contains("Private cobalt entry")
                    && !unknownContext.sourceReferences.contains { $0.id == "ledger-private-source" },
                "startupOrientationRelevance": first.user.contains("previous exchange opening orientation")
                    && first.user.contains("Reopening the dock lanterns.")
                    && first.user.contains("previous exchange closing orientation")
                    && first.user.contains("We stopped at the workbench."),
                "contextAtFirstGeneration": calls.count == 1 && reply == Self.reply && first.user.contains(checkpoint),
                "cueReadOnly": cueReadOnly,
                "stalePrefetchRejectedAfterErasure": prepared.renderedContext.contains(checkpoint)
                    && receipt.forgottenEvidenceIDs.contains("lights-current-source")
                    && rechecked.revision > prepared.revision
                    && !rechecked.renderedContext.contains(checkpoint)
                    && !rechecked.renderedContext.contains("Order copper housings")
                    && !rechecked.sourceReferences.contains { $0.id == "lights-current-source" },
            ], timings: ["cueToCandidate": cueLatency, "turnToFirstGeneration": Self.milliseconds(from: started, to: first.time)])
        }
    }
}

extension BrainLongitudinalScenarioTests {
    private struct TasteCandidate: Encodable, Sendable {
        let kind = "taste"
        let qualification = "firstPerson"
        let quote: String
        let taste: BrainTasteKind
        let target: String
        let domain: String
        let alternatives: [String]?
        let criterion: String?
        let intensity: BrainTasteIntensity?
        let enduring: Bool

        init(_ quote: String, _ taste: BrainTasteKind, _ target: String, _ domain: String,
             alternatives: [String]? = nil, criterion: String? = nil, intensity: BrainTasteIntensity? = nil,
             enduring: Bool = true) {
            self.quote = quote
            self.taste = taste
            self.target = target
            self.domain = domain
            self.alternatives = alternatives
            self.criterion = criterion
            self.intensity = intensity
            self.enduring = enduring
        }
    }

    private struct TasteProvider: ModelTextClient {
        let candidates: [TasteCandidate]

        func generate(prompt: String, options: ModelTextOptions) async throws -> String {
            guard prompt.hasPrefix("BRAIN_TURN_LEARNING") else { return "{}" }
            for candidate in candidates {
                let userText = String(decoding: try JSONEncoder().encode(candidate.quote), as: UTF8.self)
                if prompt.hasSuffix("User text as JSON: " + userText) {
                    return String(decoding: try JSONEncoder().encode(["updates": [candidate]]), as: UTF8.self)
                }
            }
            return "{}"
        }
    }

    private static func profile(_ domain: String, thread: String, using client: any TestClientProtocol) async throws -> BrainTasteProfile {
        try await decode(BrainTasteProfile.self, client.execute(
            uri: "/v1/brain/tastes/profile?domain=\(domain)&threadID=\(thread)", method: .get, headers: auth))
    }

    func testTastePreferenceOverTimeAcrossMusicAndFood() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let candidates: [TasteCandidate] = [
            .init("I like jazz.", .liking, "jazz", "music"),
            .init("I prefer folk over ambient.", .comparativePreference, "folk", "music", alternatives: ["ambient"]),
            .init("I want to play jazz today.", .selection, "jazz", "music", enduring: false),
            .init("I love dumplings.", .liking, "dumplings", "food"),
            .init("Mi favorito es el ramen.", .comparativePreference, "ramen", "food", criterion: "favorite"),
            .init("I hate licorice.", .disliking, "licorice", "food", intensity: .strong),
            .init("Nora said I like olives.", .liking, "olives", "food"),
            .init("Nora said I want to play a march.", .selection, "march", "music", enduring: false),
            .init("I dislike lentils.", .disliking, "lentils", "food"),
            .init("Today I like lentils.", .liking, "lentils", "food"),
            .init("Actually, I don't like dumplings.", .disliking, "dumplings", "food"),
        ]
        let (app, services) = try await Self.makeApp(store, model: TasteProvider(candidates: candidates))
        try await app.test(.router) { client in
            let threads = ["music-home", "music-home", "music-home", "food-home", "food-home", "food-home", "food-home",
                           "third-party-selection", "food-home", "food-home", "food-correction"]
            var admitted = [BrainTurnResult]()
            for (index, fixture) in candidates.enumerated() {
                let turn = try Self.turn("taste-\(index)", thread: threads[index], text: fixture.quote)
                admitted.append(try await Self.decode(BrainTurnResult.self,
                    Self.post(turn, to: "/v1/brain/turns/begin", using: client)))
            }

            let music = try await Self.profile("music", thread: "fresh-music", using: client)
            let originalMusic = try await Self.profile("music", thread: "music-home", using: client)
            let food = try await Self.profile("food", thread: "fresh-food", using: client)
            let originalFood = try await Self.profile("food", thread: "food-home", using: client)
            let thirdPartyMusic = try await Self.profile("music", thread: "third-party-selection", using: client)
            let read = BrainStore(store: store, authorization: services.brain.grant(threadID: "food-home"))
            let future = try TastePreferenceService(brain: read).profile(subject: BrainIdentity.userID, domain: "food",
                context: .init(threadID: "food-home"), now: Date().timeIntervalSince1970 + 901)
            let correctionSource = try XCTUnwrap(admitted.last?.completion.evidenceIDs.first)
            let forget = BrainForgetRequest(clientOperationID: "forget-food-correction", expectedRevision: try read.revision(),
                scope: .init(kind: .evidence, id: correctionSource), threadID: "food-correction")
            let receipt = try await Self.decode(BrainForgetReceipt.self, Self.post(forget, to: "/v1/brain/forget", using: client))
            let retractedFood = try await Self.profile("food", thread: "fresh-food", using: client)
            let unrelatedMusic = try await Self.profile("music", thread: "fresh-music", using: client)

            try Self.report("taste-preference", [
                "musicLikingAndComparativePreferenceSeparate": music.records.contains { $0.target == "jazz" && $0.kind == .liking }
                    && music.records.contains { $0.target == "folk" && $0.kind == .comparativePreference && $0.alternatives == ["ambient"] },
                "oneTimeSelectionScopedToIntent": originalMusic.currentIntent?.first?.target == "jazz"
                    && originalMusic.currentIntent?.first?.kind == .selection && music.currentIntent?.isEmpty == true
                    && originalMusic.records.count == 2,
                "foodFavoriteAndStrongDislikeSeparate": food.records.contains {
                    $0.target == "ramen" && $0.kind == .comparativePreference && $0.criterion == "favorite" && $0.alternatives == nil
                } && food.records.contains { $0.target == "licorice" && $0.kind == .disliking && $0.intensity == .strong },
                "thirdPartyTasteAndSelectionRejected": !originalFood.records.contains { $0.target == "olives" }
                    && thirdPartyMusic.currentIntent?.isEmpty == true && thirdPartyMusic.records == music.records,
                "temporaryChangeExpiresWithoutReplacingStableTaste": originalFood.records.contains {
                    $0.target == "lentils" && $0.kind == .liking && $0.durability == .contextual && $0.validTo != nil
                } && food.records.filter { $0.target == "lentils" }.map(\.kind) == [.disliking]
                    && future.records.filter { $0.target == "lentils" }.map(\.kind) == [.disliking],
                "correctionReplacesLikingWithGroundedDislike": food.records.filter { $0.target == "dumplings" }.map(\.kind) == [.disliking]
                    && food.records.first { $0.target == "dumplings" }?.evidenceIDs == [correctionSource],
                "forgetClosesCurrentStanceWithoutRevivingPrevious": receipt.forgottenEvidenceIDs.contains(correctionSource)
                    && !retractedFood.records.contains { $0.target == "dumplings" }
                    && retractedFood.records.contains { $0.target == "ramen" } && unrelatedMusic.records == music.records,
            ], unmeasured: ["providerTasteExtraction": "Fixture proposals exercise grounding and storage only."])
        }
    }

    func testIndependentJudgmentPolicyTransportAndUnavailablePlayback() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let names = ["search_music_catalog", "play_music"]
        let provider = RecordingProvider(unavailableTools: names)
        let (app, _) = try await Self.makeApp(store, provider: provider)
        try await app.test(.router) { client in
            let thread = "judgment"
            let cases = [
                "Since the Moon produces its own visible light, can you explain how it does that?",
                "Our survey gathered 42 responses.",
                "I remember that our survey gathered 24 responses. Is that right?",
                "Water freezes at 0 degrees Celsius at standard pressure.",
                "I dislike licorice.",
                "I can't tell whether our supplier shipped the replacement part yet.",
            ]
            let playReply = try await Self.gateway("playback", thread: thread, text: "Find my favorite in the catalog and play it.", using: client)
            for (index, text) in cases.enumerated() {
                _ = try await Self.gateway("judgment-\(index)", thread: thread, text: text, using: client)
            }
            let calls = await provider.calls
            let generation = Array(calls.dropFirst(2))
            let transported = zip(generation, cases).allSatisfy { $0.user.contains($1) }
            let policy = generation.allSatisfy {
                $0.system.contains("Correct factual errors promptly with reasons and evidence, and admit uncertainty.")
                    && $0.system.contains("Do not agree automatically or manufacture disagreement.")
                    && $0.system.contains("Do not treat personal tastes as false factual claims.")
                    && $0.system.contains("questions are optional")
            }
            let first = try XCTUnwrap(calls.first)
            let afterTools = try XCTUnwrap(calls.dropFirst().first)
            try Self.report("independent-judgment-and-playback", [
                "allFiveJudgmentCasesReachProvider": generation.count == cases.count && transported
                    && generation[2].user.contains(cases[1]),
                "independentJudgmentAndOptionalCuriosityPolicyTransported": !generation.isEmpty && policy,
                "catalogAndPlaybackToolsUnavailable": !first.offeredTools.isEmpty
                    && Set(first.offeredTools).isDisjoint(with: names)
                    && names.allSatisfy { afterTools.user.contains($0) }
                    && afterTools.user.components(separatedBy: "ERROR: tool is unavailable for this turn").count == 3
                    && playReply == Self.reply,
                "availabilityAndExecutionEvidencePolicyTransported": first.system.contains(
                    "Check live tool evidence before claiming availability or execution."),
            ], unmeasured: [
                "independentJudgmentModelAdherence": "Recording provider returns canned replies for false, contradictory, correct, subjective and uncertain inputs.",
                "reasonedDisagreementAndOptionalCuriosity": "Requires a configured model and human conversational review.",
                "catalogAvailabilityAndPlayback": "No catalog or playback integration was installed or contacted.",
            ])
        }
    }
}

extension BrainLongitudinalScenarioTests {
    private struct SummaryProvider: ConversationSummaryModel {
        let source: String
        let text: String

        func summarize(sources: [BrainEvidence]) async throws -> ConversationStateCandidate {
            XCTAssertEqual(sources.map(\.id), [source])
            return .init(gist: [.init(text: text, evidenceIDs: [source], modality: .asserted)])
        }
    }

    func testCompactedConversationReopensAndStaleRowsAreScrubbedBeforeRestoredReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("task17-restore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("memory.sqlite")
        let thread = "restore"
        let original = "I inspected the cedar bridge and found a vermilion token beneath it."
        let summary = "Inspected the cedar bridge."
        let bridgeNote = "The next inspection is scheduled."
        let largerWindow = try BrainContextBudget(contextTokens: 8192, outputTokens: 396, systemTokens: 900, toolTokens: 800)
        let current = try Self.turn("reopen-current", thread: thread, text: "What did I inspect?", budget: largerWindow)
        let sourceID: String
        let rawEvidence: String
        let rawTranscript: TranscriptRow

        do {
            let store = try MemoryStore(url: database, embeddingDim: 8)
            let (app, services) = try await Self.makeApp(store)
            sourceID = try await app.test(.router) { client in
                let originalTurn = try Self.turn("original", thread: thread, text: original)
                let result = try await Self.decode(BrainTurnResult.self,
                    Self.post(originalTurn, to: "/v1/brain/turns/begin", using: client))
                let followup = try Self.turn("followup", thread: thread, text: bridgeNote)
                let next = try await Self.post(followup, to: "/v1/brain/turns/begin", using: client)
                XCTAssertEqual(next.status, .ok)
                return try XCTUnwrap(result.completion.evidenceIDs.first)
            }
            let grant = services.brain.grant(threadID: thread, write: true)
            let state = ConversationStateStore(brain: BrainStore(store: store, authorization: grant))
            let compactor = ConversationCompactor(store: state, model: SummaryProvider(source: sourceID, text: summary))
            try await compactor.update(threadID: thread, throughEvidenceID: sourceID)
            rawEvidence = try await store.dbQueue.read { db in
                try XCTUnwrap(String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [sourceID]))
            }
            rawTranscript = try XCTUnwrap(services.transcript.range(threadId: thread, from: 1, to: 1).first)
            try store.dbQueue.close()
        }

        let reopened = try MemoryStore(url: database, embeddingDim: 8)
        let (app, services) = try await Self.makeApp(reopened)
        try await app.test(.router) { client in
            let response = try await Self.decode(BrainTurnResult.self,
                Self.post(current, to: "/v1/brain/turns/begin", using: client))
            let context = try XCTUnwrap(response.context)
            let replay = try await Self.decode(BrainTurnResult.self,
                Self.post(current, to: "/v1/brain/turns/begin", using: client))
            let exactlyOnce = try services.transcript.range(threadId: thread, from: 1, to: 20)
                .filter { $0.text == current.message.text }.count == 1
            let grant = services.brain.grant(threadID: thread, forget: true)
            let brain = BrainStore(store: reopened, authorization: grant)
            let forget = BrainForgetRequest(clientOperationID: "forget-restore", expectedRevision: try brain.revision(),
                scope: .init(kind: .evidence, id: sourceID), threadID: thread)
            let receipt = try await Self.decode(BrainForgetReceipt.self, Self.post(forget, to: "/v1/brain/forget", using: client))
            let request = try BrainContextRequest(clientOperationID: "restored-context", threadID: thread, query: current.message.text,
                                                  budget: Self.budget(), quoteEvidenceIDs: [], detailEvidenceIDs: [])
            let afterForget = try await Self.decode(BrainContextBundle.self, Self.post(request, to: "/v1/brain/context", using: client))

            // Simulate a stale row restore while retaining the authoritative erasure ledger.
            try await reopened.dbQueue.write { db in
                try rawTranscript.insert(db)
                try db.execute(sql: "INSERT INTO brain_evidence(id, payload) VALUES (?, ?)", arguments: [sourceID, rawEvidence])
            }
            let restoredRowsPresent = try services.transcript.range(threadId: thread, from: 1, to: 20).contains(rawTranscript)
            let retraction = BrainRetractionService(brain: brain)
            try retraction.applyExclusions([receipt])
            try retraction.applyExclusions([receipt])
            let restored = try await Self.decode(BrainContextBundle.self, Self.post(request, to: "/v1/brain/context", using: client))
            let transcript = try services.transcript.range(threadId: thread, from: 1, to: 20)
            let evidenceCount = try await reopened.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_evidence WHERE id=?", arguments: [sourceID])
            }
            let unchangedRevision = try brain.revision() == receipt.revision

            try Self.report("restart-compaction-restoration", [
                "compactedGistSurvivesSQLiteReopen": context.renderedContext.contains(summary)
                    && context.sourceUses?[sourceID]?.contains(.derivedSupport) == true,
                "compactedOriginalOmittedByDefault": !context.renderedContext.contains("vermilion token")
                    && !context.recentMessageUnits.contains { $0.evidenceIDs.contains(sourceID) },
                "turnReceiptReplayCapturesOnce": replay.turnID == response.turnID && replay.completion == response.completion && exactlyOnce,
                "forgetRemovesOriginalAndGist": receipt.forgottenEvidenceIDs.contains(sourceID)
                    && !afterForget.sourceReferences.contains { $0.id == sourceID }
                    && !afterForget.renderedContext.contains(summary),
                "restoredEvidenceAndTranscriptPhysicallyScrubbed": restoredRowsPresent && evidenceCount == 0
                    && transcript.map(\.text) == [bridgeNote, current.message.text],
                "restoredContextExcludesForgottenSupport": !restored.sourceReferences.contains { $0.id == sourceID }
                    && !restored.renderedContext.contains(summary) && !restored.renderedContext.contains("vermilion token"),
                "exclusionReplayIdempotent": unchangedRevision,
            ], unmeasured: [
                "wholeBackupReplacement": "The scenario restores stale rows while retaining the erasure ledger and explicitly reapplies exclusions.",
            ])
        }
        try reopened.dbQueue.close()
    }
}

extension BrainLongitudinalScenarioTests {
    private struct ProcedureAuthority: ExperienceAuthority {
        let sourceID: String

        func attribution(for outcome: BrainOutcome, evidence: [BrainEvidence]) -> ExperienceAttribution {
            outcome.id == "fixture-check" && outcome.observation?.httpStatus == 200
                && evidence.map(\.id) == [sourceID] ? .independentlyVerified : .reported
        }

        func approves(procedure: BrainProcedure, outcomes: [BrainOutcome], evidence: [BrainEvidence], environment: String) -> Bool {
            procedure.outcomeIDs == ["fixture-check"] && outcomes.map(\.id) == procedure.outcomeIDs
                && evidence.map(\.id) == [sourceID] && environment == "staging-a"
        }
    }

    func testProcedureRequiresRevalidationInChangedEnvironmentAndDisappearsAfterForget() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let (app, services) = try await Self.makeApp(store)
        try await app.test(.router) { client in
            let thread = "procedure"
            let turn = try Self.turn("check-service", thread: thread, text: "Check the staging status.")
            let admitted = try await Self.decode(BrainTurnResult.self,
                Self.post(turn, to: "/v1/brain/turns/begin", using: client))
            let source = try XCTUnwrap(admitted.completion.evidenceIDs.first)
            let observation = BrainToolObservation(operation: .httpCheck, httpStatus: 200)
            let now = Date().timeIntervalSince1970
            let forged = BrainOutcome(id: "wire-check", description: "", status: .succeeded, recordedAt: now,
                evidenceIDs: [source], observation: observation)
            struct WireOutcome: Encodable { let turnID: String; let outcome: BrainOutcome }
            let rejected = try await Self.post(WireOutcome(turnID: admitted.turnID, outcome: forged),
                                               to: "/v1/brain/outcomes", using: client)
            _ = try services.brain.turnService(threadID: thread).recordToolOutcome(id: "fixture-check", status: .succeeded,
                recordedAt: now, evidenceIDs: [source], observation: observation)
            let grant = services.brain.grant(threadID: thread, forget: true)
            let library = ProcedureLibrary(experience: ExperienceStore(store: store, authorization: grant,
                                                                        authority: ProcedureAuthority(sourceID: source)))
            let procedure = try await library.proposeProcedure(sourceOutcomeIDs: ["fixture-check"])
            try library.validateProcedure(id: procedure.id, version: procedure.version,
                                          verificationEvidenceIDs: [source], environment: "staging-a")
            let asOf = Date().timeIntervalSince1970
            let original = try library.procedures(for: "HTTP check", environment: "staging-a", asOf: asOf)
            let moved = try library.procedures(for: "HTTP check", environment: "staging-b", asOf: asOf)
            let revision = try BrainStore(store: store, authorization: grant).revision()
            let forget = BrainForgetRequest(clientOperationID: "forget-procedure-proof", expectedRevision: revision,
                scope: .init(kind: .evidence, id: source), threadID: thread)
            let receipt = try await Self.decode(BrainForgetReceipt.self, Self.post(forget, to: "/v1/brain/forget", using: client))
            let erased = try library.procedures(for: "HTTP check", environment: "staging-a", asOf: asOf)
            try Self.report("procedure-environment", [
                "wireCannotForgeHostObservation": rejected.status == .forbidden,
                "exactEnvironmentValidated": original.first?.procedure.id == procedure.id && original.first?.state == .validated,
                "changedEnvironmentNeedsRevalidation": moved.first?.procedure.id == procedure.id && moved.first?.state == .needsRevalidation,
                "withdrawnSupportRemovesProcedure": receipt.forgottenEvidenceIDs.contains(source) && erased.isEmpty,
            ], unmeasured: ["realProcedureExecution": "Fixture attestation exercises the host authority interface without executing a procedure."])
        }
    }
}
