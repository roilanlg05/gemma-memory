import XCTest
import BrainContract
@testable import MemoryCore

final class Task11RecallTests: XCTestCase {
    let now: Double = 100_000
    func fixture(project: Bool = false) throws -> BrainStore {
        let store = try MemoryStore(inMemory: true, embeddingDim: 16)
        return BrainStore(store: store, authorization: .init(principal: ConsolidationEvidenceAdapter.ownerID, owner: ConsolidationEvidenceAdapter.ownerID,
            subjects: ["self:user", "topic:bridge", "game:call-of-duty", "person:robin", "episode:robin-wins", "episode:casey", "episode:recent", "device:robin-console", "project:aurora", "project:aurora-web"],
            scopes: [.user, .thread], threads: ["past", "fresh", "side"], sourceSpeakers: [.userMessage: ["self:user"], .toolObservation: ["tool:fixture"]], mayProject: project, mayCommitClaims: true, mayForget: true))
    }

    func claim(_ id: String, _ subject: String, _ predicate: String, _ value: String, _ text: String,
               _ time: Double, brain: BrainStore, thread: String = "past", scope: BrainAccessScope = .user,
               validTo: Double? = nil, supersedes: String? = nil, modality: BrainClaimModality = .asserted,
               kind: BrainSourceKind = .userMessage) throws {
        let source = BrainEvidence(id: "source-" + id, sourceKind: kind,
            speakerID: kind == .toolObservation ? "tool:fixture" : "self:user",
            threadID: thread, observedAt: time, recordedAt: time, accessScope: scope, text: kind == .toolObservation ? SafeToolObservation(result: .succeeded, httpStatus: 200).rendered : text)
        let claim = BrainClaim(id: id, revision: 0, subject: subject, predicate: predicate, value: .string(value),
            modality: modality, status: .active, validFrom: time, validTo: validTo, recordedAt: time,
            evidenceIDs: [source.id], supersedesID: supersedes)
        let result = try brain.commit(.init(clientOperationID: "put-" + id, evidence: [source],
            updates: [.init(claim: claim)], expectedRevision: try brain.revision()))
        XCTAssertEqual(result.disposition, .committed)
    }

    func bridgeFixture(project: Bool = false) throws -> BrainStore {
        let brain = try fixture(project: project)
        try claim("bridge-label", "topic:bridge", "recall.label", "crossing the bridge", "We talked about crossing the bridge.", 1, brain: brain)
        try claim("bridge-game", "topic:bridge", "recall.link", "game:call-of-duty", "That bridge mission is from Call of Duty.", 2, brain: brain)
        try claim("game-robin", "game:call-of-duty", "recall.link", "person:robin", "Robin played that mission with me.", 3, brain: brain)
        try claim("robin-episode", "person:robin", "recall.link", "episode:robin-wins", "That was the match I told you about with Robin.", 4, brain: brain)
        try claim("wins", "episode:robin-wins", "recall.episode", "The user won five times against Robin.", "I won five times against Robin.", 5, brain: brain)
        try claim("casey", "episode:casey", "recall.episode", "Casey plays Call of Duty.", "Casey plays Call of Duty.", 90_000, brain: brain)
        try claim("recent", "episode:recent", "recall.episode", "The user crossed a bridge downtown.", "I crossed a bridge downtown.", 99_999, brain: brain)
        return brain
    }

    func testIndirectBridgeRetrievesTheRightEpisodeWithItsActualSpeaker() async throws {
        let result = try await AssociativeRetriever(brain: bridgeFixture()).retrieve(query: "Remember crossing the bridge?",
            threadID: "fresh", scope: .user, asOf: now, budget: .init(maximumCandidates: 4))
        let first = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(first.episodeID, "episode:robin-wins")
        XCTAssertEqual(first.gist, "The user won five times against Robin.")
        XCTAssertEqual(first.sources.map(\.speakerID), ["self:user"])
        XCTAssertFalse(first.gist.contains("5-0"))
        XCTAssertFalse(first.gist.contains("Gemma"))
    }

    func testRepairReplacesOldStateAndThreadScopeDoesNotCrossThreads() async throws {
        let brain = try fixture()
        let device = "device:robin-console"
        try claim("broken", device, "recall.state", "Robin's console was broken.", "Robin said the console broke.", 5, brain: brain)
        try claim("repair", device, "recall.state", "Robin's console was repaired.", "Robin told me he repaired his console.", 20, brain: brain, supersedes: "broken")
        try claim("stale", device, "recall.episode", "Robin console stale.", "Old console detail.", 7, brain: brain, validTo: 8)
        try claim("private", device, "recall.episode", "Robin console private.", "Private console detail.", 10, brain: brain, thread: "side", scope: .thread)
        try claim("erased", device, "recall.episode", "Robin console erased.", "Forgotten console detail.", 11, brain: brain)
        _ = try brain.forget(scope: .init(kind: .claim, id: "erased"), expectedRevision: brain.revision(), operationID: "erase-console")
        let result = try await AssociativeRetriever(brain: brain).retrieve(query: "Robin console", threadID: "fresh",
            scope: .user, asOf: now, budget: .init(maximumCandidates: 5))
        XCTAssertEqual(result.candidates.map(\.gist), ["Robin's console was repaired."])
    }

    func testOpportunityOnlyCoolsDownAfterSurfaceAndKeepsTaskContextSilent() async throws {
        let brain = try bridgeFixture()
        let result = try await AssociativeRetriever(brain: brain).retrieve(query: "Robin won five times",
            threadID: "fresh", scope: .user, asOf: now, budget: .init(maximumCandidates: 2))
        let candidate = try XCTUnwrap(result.candidates.first)
        let gate = RecallOpportunityGate(episodeCooldown: 60, topicCooldown: 10)
        let chat = RecallConversation(connectionID: "connection", topic: "games", mode: .social)
        let task = RecallConversation(connectionID: "connection", topic: "games", mode: .taskFocused)
        XCTAssertEqual(gate.opportunity(candidate: candidate, conversation: chat, now: now), .mention)
        XCTAssertEqual(gate.opportunity(candidate: candidate, conversation: chat, now: now), .mention)
        XCTAssertEqual(gate.opportunity(candidate: candidate, conversation: task, now: now), .contextOnly)
        gate.recordSurfaced(episodeID: candidate.episodeID, conversation: chat, now: now)
        XCTAssertEqual(gate.opportunity(candidate: candidate, conversation: chat, now: now + 1), .defer)
        XCTAssertEqual(gate.opportunity(candidate: candidate, conversation: chat, now: now + 61), .mention)
    }
}

extension Task11RecallTests {
    func testScopedSemanticRecallRequiresMatchingActiveModelAndAuthorizedClaims() async throws {
        let brain = try fixture(project: true)
        let store = brain.store
        let active = EmbeddingIndexVersion(modelID: "fixture/scoped", dimension: 16, revision: "r1")
        let other = EmbeddingIndexVersion(modelID: "fixture/other", dimension: 16, revision: "r1")
        try store.bootstrapEmbeddingIndex(version: active)
        try claim("public", "episode:casey", "recall.episode", "Casey visited Reykjavik.", "Casey visited Reykjavik.", 5,
                  brain: brain)
        try claim("private", "episode:recent", "recall.episode", "Secret destination.", "Secret destination.", 6,
                  brain: brain, thread: "side", scope: .thread)
        let vector: [Float] = [1] + Array(repeating: 0, count: 15)
        let projected = try XCTUnwrap(try store.node(id: "brain-claim:public"))
        try store.setEmbedding(nodeId: projected.id, vector, version: active,
                               sourceText: MemoryStore.nodeEmbeddingText(projected))
        try store.setEmbedding(nodeId: projected.id, vector)

        let matching = AssociativeRetriever(brain: brain, embedder: Task11FixedEmbedder(vector: vector, indexVersion: active))
        let match = try await matching.retrieve(query: "destination", threadID: "fresh", scope: .user, asOf: now,
                                                budget: .init(), strategy: .vectorOnly)
        XCTAssertEqual(match.candidates.map(\.episodeID), ["episode:casey"])
        let mismatching = AssociativeRetriever(brain: brain, embedder: Task11FixedEmbedder(vector: vector, indexVersion: other))
        let mismatch = try await mismatching.retrieve(query: "destination", threadID: "fresh", scope: .user, asOf: now,
                                                      budget: .init(), strategy: .vectorOnly)
        XCTAssertTrue(mismatch.candidates.isEmpty)
        let lexical = try await mismatching.retrieve(query: "Reykjavik", threadID: "fresh", scope: .user, asOf: now,
                                                     budget: .init())
        XCTAssertEqual(lexical.candidates.map(\.episodeID), ["episode:casey"])
    }

    func testBridgeFixtureComparesHybridVectorOnlyAndExistingOneHop() async throws {
        let brain = try bridgeFixture(project: true)
        let store = brain.store
        let query = "crossing bridge"
        let winID = "episode:robin-wins"
        let vector: [Float] = [1] + Array(repeating: 0, count: 15)
        let orthogonal: [Float] = [0, 1] + Array(repeating: 0, count: 14)
        try store.setEmbedding(nodeId: "brain-claim:casey", vector)
        try store.setEmbedding(nodeId: "brain-claim:wins", orthogonal)
        for (id, label) in [("legacy-bridge", "crossing bridge"), ("legacy-game", "Call of Duty"),
                            ("legacy-robin", "Robin"), ("legacy-wins", "The user won five times against Robin.")] {
            try store.upsert(Node(id: id, kind: NodeKind.fact.rawValue, label: label, body: label, layer: .daily,
                createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 5, decayRate: 0,
                confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        for (source, target) in [("legacy-bridge", "legacy-game"), ("legacy-game", "legacy-robin"), ("legacy-robin", "legacy-wins")] {
            try store.upsert(Edge(id: source + target, srcId: source, dstId: target, relation: .worksWith,
                weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
        }
        let legacy = try MemoryRetriever(store: store, embedder: nil).retrieve(query: query, k: 8, now: now)
        XCTAssertTrue(legacy.contains { $0.id == "legacy-game" })
        XCTAssertFalse(legacy.contains { $0.id == "legacy-wins" || $0.id == "brain-claim:wins" })
        let retriever = AssociativeRetriever(brain: brain, embedder: Task11FixedEmbedder(vector: vector))
        let vectorOnly = try await retriever.retrieve(query: query, threadID: "fresh", scope: .user, asOf: now,
            budget: .init(), strategy: .vectorOnly)
        XCTAssertEqual(vectorOnly.candidates.first?.episodeID, "episode:casey")
        let direct = try await retriever.retrieve(query: query, threadID: "fresh", scope: .user, asOf: now,
            budget: .init(), strategy: .direct)
        XCTAssertFalse(direct.candidates.contains { $0.episodeID == winID })
        let oneHop = try await AssociativeRetriever(brain: brain).retrieve(query: query, threadID: "fresh", scope: .user,
            asOf: now, budget: .init(maximumHops: 1, maximumVisited: 8))
        XCTAssertLessThanOrEqual(oneHop.visitedSubjects, 8)
        XCTAssertFalse(oneHop.candidates.contains { $0.episodeID == winID })
        let hybrid = try await AssociativeRetriever(brain: brain).retrieve(query: query, threadID: "fresh", scope: .user,
            asOf: now, budget: .init())
        XCTAssertEqual(hybrid.candidates.first?.episodeID, winID)
    }
}

private struct Task11FixedEmbedder: Embedder {
    let vector: [Float]
    var indexVersion: EmbeddingIndexVersion? = nil
    var dimension: Int { vector.count }
    func embed(_ text: String) throws -> [Float] { vector }
}

extension Task11RecallTests {
    func testYearFiltersTopicInsteadOfAdmittingUnrelatedSameYearEpisodes() async throws {
        let retriever = try AssociativeRetriever(brain: bridgeFixture())
        let result = try await retriever.retrieve(query: "Change mailing address in 1970", threadID: "fresh", scope: .user,
            asOf: now, budget: .init())
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testNewestStateReportWinsWhileBrokenEpisodeRemainsHistorical() async throws {
        let brain = try fixture()
        let device = "device:robin-console"
        try claim("break-report", device, "recall.state", "Robin's console is broken.", "Robin's console is broken.", 5, brain: brain)
        try claim("repair-report", device, "recall.state", "Robin's console was repaired.", "Robin repaired the console.", 20, brain: brain)
        try claim("break-history", device, "recall.episode", "Robin's console broke during a tournament.", "Robin's console broke during a tournament.", 5, brain: brain)
        let result = try await AssociativeRetriever(brain: brain).retrieve(query: "Robin console", threadID: "fresh",
            scope: .user, asOf: now, budget: .init())
        XCTAssertEqual(result.candidates.filter { $0.claim.predicate == "recall.state" }.map(\.claim.id), ["repair-report"])
        XCTAssertTrue(result.candidates.contains { $0.claim.id == "break-history" })
    }

    func testIntermediateEpisodeDetailsKeepReportedCountAndWithholdOriginals() throws {
        let brain = try bridgeFixture()
        try claim("score-fact", "episode:robin-wins", "recall.detail", "Five wins were reported.", "I remember five wins, no score.", 30, brain: brain)
        let reconstructor = EpisodeReconstructor(brain: brain)
        let details = try reconstructor.facts(episodeID: "episode:robin-wins", threadID: "fresh", scope: .user, asOf: now, budget: .init())
        XCTAssertEqual(details.map(\.text), ["Five wins were reported."])
        XCTAssertEqual(details.first?.sources.first?.id, "source-score-fact")
        XCTAssertNil(details.first?.sources.first?.text)
        let originals = try reconstructor.originals(evidenceIDs: ["source-score-fact"], threadID: "fresh", scope: .user, asOf: now, budget: .init())
        XCTAssertEqual(originals.first?.text, "I remember five wins, no score.")
    }
}
