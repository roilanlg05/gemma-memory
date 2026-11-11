import XCTest
import BrainContract
@testable import MemoryCore

final class Task11ContinuityTests: XCTestCase {
    private let data = Task11RecallTests()
    private let now: Double = 100_000

    func testFreshThreadResumesAliasedProjectWithCurrentAttributedEvidence() throws {
        let brain = try data.fixture()
        let project = "project:aurora"
        try data.claim("name", project, "project.name", "Aurora", "The project is Aurora.", 1, brain: brain)
        try data.claim("alias", project, "project.alias", "Northern Lights", "We call it Northern Lights.", 2, brain: brain)
        try data.claim("old", project, "project.checkpoint", "Waiting for a parser.", "We were waiting for a parser.", 3, brain: brain)
        try data.claim("new", project, "project.checkpoint", "Parser landed, import is next.", "Parser landed, import is next.", 15, brain: brain, thread: "side", supersedes: "old")
        try data.claim("decision", project, "project.decision", "Keep SQLite.", "We decided to keep SQLite.", 4, brain: brain)
        try data.claim("progress", project, "project.progress", "Parser tests passed.", "Parser tests passed.", 16, brain: brain, thread: "side", kind: .toolObservation)
        try data.claim("proposal", project, "project.next-step", "Consider a streaming import.", "Maybe use a streaming import.", 17, brain: brain, thread: "side", modality: .proposed)
        try data.claim("erased", project, "project.next-step", "Send retired export.", "Send retired export.", 18, brain: brain)
        _ = try brain.forget(scope: .init(kind: .claim, id: "erased"), expectedRevision: brain.revision(), operationID: "erase-next-step")
        try data.claim("private", project, "project.next-step", "Private detail.", "Private detail.", 19, brain: brain, thread: "side", scope: .thread)
        try data.claim("other", "project:aurora-web", "project.name", "Aurora Web", "That project is Aurora Web.", 20, brain: brain, thread: "side")
        try data.claim("other-step", "project:aurora-web", "project.next-step", "Deploy the site.", "Deploy the site.", 21, brain: brain, thread: "side")
        let recall = AssociativeRetriever(brain: brain)
        let result = try recall.resumeProject(query: "Continue Northern Lights", threadID: "fresh", scope: .user, asOf: now, budget: .init())
        guard case .resolved(let project) = result else { return XCTFail("Expected a single project") }
        XCTAssertEqual(project.name, "Aurora")
        XCTAssertEqual(project.checkpoint?.text, "Parser landed, import is next.")
        XCTAssertEqual(project.checkpoint?.sources.first?.threadID, "side")
        XCTAssertEqual(project.decisions.map(\.text), ["Keep SQLite."])
        XCTAssertEqual(project.progress.map(\.text), ["Parser tests passed."])
        XCTAssertEqual(project.progress.first?.sources.first?.speakerID, "tool:fixture")
        XCTAssertEqual(project.progress.first?.verified, false)
        XCTAssertEqual(project.nextSteps.map(\.text), ["Consider a streaming import."])
        XCTAssertEqual(project.nextSteps.first?.claim.modality, .proposed)
        try data.claim("other-alias", "project:aurora-web", "project.alias", "Northern Lights", "Aurora Web also has that alias.", 22, brain: brain)
        let ambiguous = try recall.resumeProject(query: "Continue Northern Lights", threadID: "fresh", scope: .user, asOf: now, budget: .init())
        guard case .clarify(let names) = ambiguous else { return XCTFail("Expected a clarification") }
        XCTAssertEqual(Set(names), ["Aurora", "Aurora Web"])
    }

    func testStartupOpeningAndClosingStayOutOfFreshRecentAndExactCitation() async throws {
        let brain = try data.fixture()
        try data.claim("opening", "project:aurora", "project.name", "Aurora", "We started by setting up Aurora.", 1, brain: brain)
        try data.claim("old", "project:aurora", "project.checkpoint", "Use the stale port.", "Use the stale port.", 2, brain: brain)
        try data.claim("closing", "project:aurora", "project.checkpoint", "Next, test the import.", "Next, test the import.", 3, brain: brain, supersedes: "old")
        try data.claim("secret", "project:aurora", "project.next-step", "Private side thread.", "Private side thread.", 4, brain: brain, thread: "side", scope: .thread)
        let recall = AssociativeRetriever(brain: brain)
        let orientation = try XCTUnwrap(recall.startupOrientation(threadID: "fresh", scope: .user, asOf: now))
        XCTAssertEqual(orientation.threadID, "past")
        XCTAssertEqual(orientation.opening?.text, "We started by setting up Aurora.")
        XCTAssertEqual(orientation.closing?.text, "Next, test the import.")
        let context = BrainContextAssembler(store: ConversationStateStore(brain: brain), recall: recall)
        let bundle = try await context.context(.init(clientOperationID: "startup", threadID: "fresh", query: "Hello",
            budget: .init(contextTokens: 4096, outputTokens: 100)), recallOptions: .init(asOf: now, includeStartupOrientation: true))
        XCTAssertTrue(bundle.renderedContext.contains("previous exchange"))
        XCTAssertTrue(bundle.renderedContext.contains("setting up Aurora"))
        XCTAssertTrue(bundle.renderedContext.contains("test the import"))
        XCTAssertFalse(bundle.renderedContext.contains("stale port"))
        XCTAssertFalse(bundle.renderedContext.contains("Private side"))
        XCTAssertTrue(bundle.recentMessageUnits.isEmpty)
        XCTAssertTrue(bundle.exactCitationSourceReferences(includingRenderedContext: true, forwardedRecentUnitIDs: []).isEmpty)
    }

    func testCueFinalizationDropsCorrectionCancellationConnectionMismatchAndForgottenSources() async throws {
        let brain = try data.bridgeFixture()
        let recall = AssociativeRetriever(brain: brain)
        let session = recall.makeCueSession(connectionID: "live", threadID: "fresh", scope: .user)
        func cue(_ text: String, turn: String = "t1", connection: String = "live", stable: Bool = true) -> RecallTurnCue {
            .init(connectionID: connection, turnID: turn, text: text, isStable: stable)
        }
        let bridge = cue("Call of Duty crossing the bridge")
        let unstable = try await session.prefetch(cue(bridge.text, stable: false), asOf: now, budget: .init())
        XCTAssertNil(unstable)
        let prefetched = try await session.prefetch(bridge, asOf: now, budget: .init())
        let handle = try XCTUnwrap(prefetched)
        XCTAssertTrue(handle.episodeIDs.contains("episode:robin-wins"))
        let mismatched = try await session.finalize(handle, final: cue(bridge.text, connection: "other"), asOf: now, budget: .init())
        XCTAssertNil(mismatched)
        let corrected = try await session.finalize(handle, final: cue("Actually, how do I export a spreadsheet?"), asOf: now, budget: .init())
        XCTAssertTrue(try XCTUnwrap(corrected).candidates.isEmpty)
        let next = cue(bridge.text, turn: "t2")
        let second = try await session.prefetch(next, asOf: now, budget: .init())
        let cancelled = try XCTUnwrap(second)
        await session.cancel(connectionID: "live", turnID: "t2")
        let dropped = try await session.finalize(cancelled, final: next, asOf: now, budget: .init())
        XCTAssertNil(dropped)
        let last = cue(bridge.text, turn: "t3")
        let third = try await session.prefetch(last, asOf: now, budget: .init())
        let stale = try XCTUnwrap(third)
        _ = try brain.forget(scope: .init(kind: .evidence, id: "source-wins"), expectedRevision: brain.revision(), operationID: "forget-win")
        let final = try await session.finalize(stale, final: last, asOf: now, budget: .init())
        XCTAssertFalse(try XCTUnwrap(final).candidates.contains { $0.episodeID == "episode:robin-wins" })
    }

    func testSlowSemanticProviderFallsBackWithoutWaitingForLoser() async throws {
        let recall = try AssociativeRetriever(brain: data.bridgeFixture(), embedder: Task11SlowEmbedder(), semanticDeadlineMilliseconds: 10)
        let clock = ContinuousClock()
        let began = clock.now
        let result = try await recall.retrieve(query: "Remember crossing the bridge?", threadID: "fresh", scope: .user, asOf: now, budget: .init())
        XCTAssertLessThan(began.duration(to: clock.now), .milliseconds(300))
        XCTAssertEqual(result.candidates.first?.episodeID, "episode:robin-wins")
    }
}

private struct Task11SlowEmbedder: Embedder {
    let dimension = 16
    func embed(_ text: String) throws -> [Float] {
        Thread.sleep(forTimeInterval: 0.75)
        return Array(repeating: 1, count: dimension)
    }
}

extension Task11ContinuityTests {
    func testFinalizedCueMatchesTurnAndConnectionAndIsRevokedOnClose() async throws {
        let brain = try data.bridgeFixture()
        let retriever = AssociativeRetriever(brain: brain)
        let session = retriever.makeCueSession(connectionID: "live", threadID: "fresh", scope: .user)
        let query = "Remember crossing the bridge?"
        let final = RecallTurnCue(connectionID: "live", turnID: "turn", text: query, isStable: true)
        let selected = try await session.finalize(final: final, asOf: now, budget: .init())
        let prepared = try XCTUnwrap(selected)
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain), recall: retriever)
        func bundle(turn: String, connection: String) async throws -> BrainContextBundle {
            try await assembler.context(.init(clientOperationID: turn, threadID: "fresh", query: query,
                budget: .init(contextTokens: 4096, outputTokens: 100)), recallOptions: .init(asOf: now,
                    conversation: .init(connectionID: connection, topic: "games", mode: .taskFocused), finalizedCue: prepared))
        }
        let wrongTurn = try await bundle(turn: "other", connection: "live")
        XCTAssertFalse(wrongTurn.renderedContext.contains("five times"))
        let wrongConnection = try await bundle(turn: "turn", connection: "different")
        XCTAssertFalse(wrongConnection.renderedContext.contains("five times"))
        let correct = try await bundle(turn: "turn", connection: "live")
        XCTAssertTrue(correct.renderedContext.contains("five times"))
        XCTAssertTrue(correct.renderedContext.contains("context only"))
        await session.close()
        let closed = try await bundle(turn: "turn", connection: "live")
        XCTAssertFalse(closed.renderedContext.contains("five times"))
    }

    func testCrossThreadOriginalNeedsExplicitResolutionAndActualWholeDelivery() async throws {
        let brain = try data.bridgeFixture()
        let retriever = AssociativeRetriever(brain: brain)
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain), recall: retriever)
        let request = try BrainContextRequest(clientOperationID: "quotes", threadID: "fresh",
            query: "Remember crossing the bridge?", budget: .init(contextTokens: 4096, outputTokens: 100))
        let gist = try await assembler.context(request, recallOptions: .init(asOf: now))
        XCTAssertTrue(gist.renderedContext.contains("The user won five times against Robin."))
        XCTAssertTrue(gist.exactCitationSourceReferences(includingRenderedContext: true, forwardedRecentUnitIDs: []).isEmpty)
        let quote = try await assembler.context(request, recallOptions: .init(asOf: now, quoteEvidenceIDs: ["source-wins"]))
        XCTAssertTrue(quote.renderedContext.contains("I won five times against Robin."))
        XCTAssertEqual(quote.exactCitationSourceReferences(includingRenderedContext: true, forwardedRecentUnitIDs: []).map(\.id), ["source-wins"])
        XCTAssertTrue(quote.exactCitationSourceReferences(includingRenderedContext: false, forwardedRecentUnitIDs: []).isEmpty)
        _ = try brain.forget(scope: .init(kind: .evidence, id: "source-wins"), expectedRevision: brain.revision(), operationID: "forget-quoted-win")
        do {
            _ = try await assembler.context(request, recallOptions: .init(asOf: now, quoteEvidenceIDs: ["source-wins"]))
            XCTFail("Expected the original request to fail closed")
        } catch BrainStoreError.denied {}
    }
}

extension Task11ContinuityTests {
    func testRecallCanCompeteWithOlderLocalGroupsWithoutEvictingNewest() async throws {
        let brain = try data.fixture()
        try data.claim("opening", "project:aurora", "project.name", "Aurora", "We started by setting up Aurora.", 1, brain: brain)
        try data.claim("closing", "project:aurora", "project.checkpoint", "Next, test the import.", "Next, test the import.", 2, brain: brain)
        for index in 0..<7 {
            let id = "current-\(index)"
            let text = index == 6 ? "Newest local input." : String(repeating: "older local discussion ", count: 90)
            _ = try brain.recordEvidence(.init(id: id, sourceKind: .userMessage, speakerID: "self:user",
                threadID: "fresh", observedAt: Double(10 + index), recordedAt: Double(10 + index), accessScope: .user, text: text),
                idempotencyKey: id)
        }
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain), recall: AssociativeRetriever(brain: brain))
        let bundle = try await assembler.context(.init(clientOperationID: "packing", threadID: "fresh", query: "Hello",
            budget: .init(contextTokens: 2500, outputTokens: 100)), recallOptions: .init(asOf: now, includeStartupOrientation: true))
        XCTAssertEqual(bundle.recentMessageUnits.last?.text, "Newest local input.")
        XCTAssertGreaterThan(bundle.recentMessageUnits.count, 1)
        XCTAssertTrue(bundle.renderedContext.contains("previous exchange"))
        XCTAssertLessThanOrEqual(bundle.accounting?.estimatedInputTokens ?? .max, 2400)
    }

    func testCancellingWhileFinalizationWaitsCannotAdmitRecall() async throws {
        let brain = try data.bridgeFixture()
        let slow = Task11BlockingEmbedder()
        let retriever = AssociativeRetriever(brain: brain, embedder: slow, semanticDeadlineMilliseconds: 500)
        let session = retriever.makeCueSession(connectionID: "live", threadID: "fresh", scope: .user)
        let cue = RecallTurnCue(connectionID: "live", turnID: "cancelled", text: "Remember crossing the bridge?", isStable: true)
        let revision = try brain.revision()
        let final = Task { try await session.finalize(final: cue, asOf: now, budget: .init()) }
        await fulfillment(of: [slow.started], timeout: 2)
        await session.cancel(connectionID: "live", turnID: "cancelled")
        slow.release.signal()
        let result = try await final.value
        XCTAssertNil(result)
        XCTAssertEqual(try brain.revision(), revision)
    }
}

private final class Task11BlockingEmbedder: Embedder, @unchecked Sendable {
    let dimension = 16
    let started = XCTestExpectation(description: "embedder received final query")
    let release = DispatchSemaphore(value: 0)
    func embed(_ text: String) throws -> [Float] {
        started.fulfill()
        _ = release.wait(timeout: .now() + 1)
        return Array(repeating: 1, count: dimension)
    }
}

extension Task11ContinuityTests {
    func testProjectReadsOnlyEvidenceLinkedEpisodes() throws {
        let brain = try data.fixture()
        let project = "project:aurora"
        try data.claim("name", project, "project.name", "Aurora", "The project is Aurora.", 1, brain: brain)
        try data.claim("parser-episode", "episode:recent", "recall.episode", "The parser work happened.", "We worked on the Aurora parser.", 5, brain: brain, thread: "side")
        try data.claim("parser-membership", project, "project.episode", "episode:recent", "That parser work was part of Aurora.", 5, brain: brain, thread: "side")
        try data.claim("parser-checkpoint", "episode:recent", "project.checkpoint", "The parser is implemented.", "Aurora parser implementation is done.", 6, brain: brain, thread: "side")
        try data.claim("other-episode", "episode:casey", "recall.episode", "A demo happened.", "We worked on a different demo.", 7, brain: brain)
        try data.claim("other-association", project, "recall.link", "episode:casey", "That demo used the same tools.", 7, brain: brain)
        try data.claim("other-checkpoint", "episode:casey", "project.checkpoint", "Deploy the demo.", "The other demo is ready for deployment.", 8, brain: brain)
        let result = try AssociativeRetriever(brain: brain).resumeProject(query: "Resume Aurora", threadID: "fresh", scope: .user, asOf: now, budget: .init())
        guard case .resolved(let resolved) = result else { return XCTFail("Expected Aurora") }
        XCTAssertEqual(resolved.checkpoint?.text, "The parser is implemented.")
        XCTAssertEqual(resolved.checkpoint?.sources.first?.id, "source-parser-checkpoint")
        XCTAssertEqual(resolved.checkpoint?.associationSources.map(\.id), ["source-parser-membership"])
    }
}

extension Task11ContinuityTests {
    func testProjectsClarifyDistinctExactMentionsAndSharedPartialNames() throws {
        let brain = try data.fixture()
        try data.claim("cli-name", "project:aurora", "project.name", "Aurora CLI", "That project is Aurora CLI.", 1, brain: brain)
        try data.claim("web-name", "project:aurora-web", "project.name", "Aurora Web Platform", "That project is Aurora Web Platform.", 2, brain: brain)
        let retriever = AssociativeRetriever(brain: brain)
        func resolve(_ query: String) throws -> ProjectRecallResult {
            try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
        }
        for query in ["Continue Aurora", "Continue Aurora CLI or Aurora Web Platform"] {
            guard case .clarify(let names) = try resolve(query) else {
                XCTFail("Expected clarification for \(query)")
                continue
            }
            XCTAssertEqual(Set(names), ["Aurora CLI", "Aurora Web Platform"])
        }
        guard case .resolved(let exact) = try resolve("Continue Aurora CLI") else { return XCTFail("Expected the exact name") }
        XCTAssertEqual(exact.name, "Aurora CLI")
        try data.claim("cli-alias", "project:aurora", "project.alias", "Aurora", "The CLI can be called Aurora.", 3, brain: brain)
        guard case .resolved(let nested) = try resolve("Continue Aurora Web Platform") else { return XCTFail("Expected the full containing label") }
        XCTAssertEqual(nested.name, "Aurora Web Platform")
    }

    func testRecallOriginalReservationsPreserveNewestBaselineOrFailTyped() async throws {
        let brain = try data.bridgeFixture()
        let original = String(repeating: "A long recorded console discussion. ", count: 150)
        try data.claim("long-quote", "device:robin-console", "recall.episode", "A console discussion happened.", original, 20, brain: brain)
        let newest = String(repeating: "Newest local content. ", count: 48)
        _ = try brain.recordEvidence(.init(id: "current-full", sourceKind: .userMessage, speakerID: "self:user",
            threadID: "fresh", observedAt: 30, recordedAt: 30, accessScope: .user, text: newest), idempotencyKey: "current-full")
        let retriever = AssociativeRetriever(brain: brain)
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain), recall: retriever)
        func request(_ window: Int) throws -> BrainContextRequest {
            try .init(clientOperationID: "budget", threadID: "fresh", query: "Robin console",
                budget: .init(contextTokens: window, outputTokens: 100))
        }
        var low = 101, high = 4096
        while low < high {
            let probe = low + (high - low) / 2
            let baseline = try? await assembler.context(request(probe))
            if baseline?.recentMessageUnits.last?.text == newest { high = probe }
            else { low = probe + 1 }
        }
        let baseline = try await assembler.context(request(low))
        XCTAssertEqual(baseline.recentMessageUnits.last?.text, newest)
        let ordinary = try await assembler.context(request(low), recallOptions: .init(asOf: now, includeStartupOrientation: true))
        XCTAssertEqual(ordinary.recentMessageUnits.last?.text, newest)
        do {
            let quoted = try await assembler.context(request(low), recallOptions: .init(asOf: now, quoteEvidenceIDs: ["source-long-quote"]))
            XCTAssertEqual(quoted.recentMessageUnits.last?.text, newest)
            XCTAssertTrue(quoted.truncations?.contains { $0.reason == "recalledQuoteOmittedBudget" } == true)
        } catch BrainContextAssemblyError.insufficientBudget {
            // An explicit request can fail when the mandatory notice cannot fit with newest whole.
        }
    }
}

extension Task11ContinuityTests {
    func testProjectPartialNamesIgnoreConversationalFillerWithoutMatchingUnrelatedCues() throws {
        let brain = try data.fixture()
        try data.claim("cli-name", "project:aurora", "project.name", "Aurora CLI", "That project is Aurora CLI.", 1, brain: brain)
        try data.claim("web-name", "project:aurora-web", "project.name", "Aurora Web Platform", "That project is Aurora Web Platform.", 2, brain: brain)
        let retriever = AssociativeRetriever(brain: brain)
        for query in ["Continue Aurora please", "Oye Gemma, sigamos con Aurora por favor"] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .clarify(let names) = result else { XCTFail("Expected ambiguity for \(query)"); continue }
            XCTAssertEqual(Set(names), ["Aurora CLI", "Aurora Web Platform"])
        }
        for query in ["Continue gardening please", "Oye Gemma, sigamos con recetas por favor", "Oye Gemma, por favor"] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .none = result else { XCTFail("Unrelated/filler-only cue matched a project: \(query)"); continue }
        }
    }

    func testFullProjectNamesRetainIntentAndFillerWords() throws {
        for (name, other, query) in [
            ("Project Aurora Please", "Aurora Please Notes", "Resume Project Aurora Please"),
            ("Please Continue", "Please Continue Manual", "Resume Please Continue")
        ] {
            let brain = try data.fixture()
            try data.claim("name", "project:aurora", "project.name", name, "The first project is called \(name).", 1, brain: brain)
            try data.claim("other", "project:aurora-web", "project.name", other, "The second project is called \(other).", 2, brain: brain)
            let result = try AssociativeRetriever(brain: brain).resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .resolved(let project) = result else { XCTFail("Expected full project label \(name)"); continue }
            XCTAssertEqual(project.name, name)
        }
    }

    func testAmbiguousProjectOptionsRespectByteAndCandidateBudgets() async throws {
        let brain = try data.fixture()
        try data.claim("cli-name", "project:aurora", "project.name", "Aurora CLI", "That project is Aurora CLI.", 1, brain: brain)
        try data.claim("web-name", "project:aurora-web", "project.name", "Aurora Web Platform", "That project is Aurora Web Platform.", 2, brain: brain)
        let retriever = AssociativeRetriever(brain: brain)
        for budget in [BrainRecallBudget(maximumUTF8Bytes: 1), .init(maximumUTF8Bytes: 12),
                       .init(maximumUTF8Bytes: 29), .init(maximumCandidates: 1)] {
            let result = try retriever.resumeProject(query: "Continue Aurora", threadID: "fresh", scope: .user, asOf: now, budget: budget)
            guard case .clarify(let names) = result else { XCTFail("Ambiguity must survive a small options budget"); continue }
            XCTAssertTrue(names.isEmpty, "Use a generic clarification instead of overspending or listing an incomplete choice")
            let internalResult = try await brain.store.dbQueue.read { db in
                let snapshot = try GraphMemoryQuery(brain: brain).snapshot(threadID: "fresh", scope: .user, asOf: self.now, db: db)
                return EpisodeReconstructor.project(query: "Continue Aurora", snapshot: snapshot, budget: budget)
            }
            XCTAssertTrue(internalResult.sources.isEmpty, "Unlisted options must not deliver evidence references")
        }
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain), recall: retriever)
        let context = try await assembler.context(.init(clientOperationID: "generic-project", threadID: "fresh", query: "Continue Aurora",
            budget: .init(contextTokens: 16_000, outputTokens: 100)), recallOptions: .init(asOf: now, budget: .init(maximumUTF8Bytes: 1)))
        XCTAssertTrue(context.renderedContext.contains("Which project did you mean?"))
        XCTAssertFalse(context.renderedContext.contains("Which project did you mean? "))
    }
}

extension Task11ContinuityTests {
    func testProjectCommandAndVocativeDecoysDoNotCaptureMeaningfulRequests() throws {
        let brain = try commandNamedProjectFixture()
        let retriever = AssociativeRetriever(brain: brain)
        for query in ["Continue Aurora please", "Resume project Aurora", "Oye Gemma, sigamos con Aurora por favor",
                      "Gemma, continue Aurora please"] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .clarify(let names) = result else { XCTFail("Expected Aurora ambiguity for \(query)"); continue }
            XCTAssertEqual(Set(names), ["Aurora CLI", "Aurora Web Platform"], "Command/filler/vocative labels are not targets in \(query)")
        }
        for query in ["Continue gardening please", "Resume project recipes", "Oye Gemma, please continue", "Continue", "Please", "Resume project please"] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .none = result else { XCTFail("Generic or unrelated request picked a command-named project: \(query)"); continue }
        }
    }

    func testExplicitCommandNamedProjectsAndMixedLabelsStillResolve() throws {
        let brain = try commandNamedProjectFixture()
        try data.claim("mixed-name", "episode:casey", "project.name", "Project Aurora Please",
            "The mixed project is Project Aurora Please.", 10, brain: brain)
        let retriever = AssociativeRetriever(brain: brain)
        for (query, expected) in [("Resume Continue", "Continue"), ("Resume Please", "Please"),
                                  ("Resume Project", "Project"), ("Resume Please Continue", "Please Continue"),
                                  ("Resume Gemma", "Gemma"), ("Resume Project Aurora Please", "Project Aurora Please")] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .resolved(let project) = result else { XCTFail("Expected explicit project \(expected)"); continue }
            XCTAssertEqual(project.name, expected)
        }
    }

    func testPolitelyWrappedCommandNamedProjectResolvesWithoutStructuralDecoys() throws {
        let brain = try data.fixture()
        for (index, entry) in [("person:robin", "Continue"), ("topic:bridge", "Project"),
                               ("game:call-of-duty", "Please"), ("device:robin-console", "Proyecto")].enumerated() {
            try data.claim("polite-name-\(index)", entry.0, "project.name", entry.1,
                "The registered project is \(entry.1).", Double(index + 1), brain: brain)
        }
        let retriever = AssociativeRetriever(brain: brain)
        for query in ["Resume Continue please", "Resume please Continue", "Resume please Continue please",
                      "rEsUmE cOnTiNuE PLEASE"] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .resolved(let project) = result else { XCTFail("Expected Continue for \(query)"); continue }
            XCTAssertEqual(project.name, "Continue")
        }
        for query in ["Resume project please", "Resume Project Please", "RESUME PROJECT PLEASE",
                      "Resume please proyecto", "Resume please please", "Resume Continue gardening please"] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .none = result else { XCTFail("Politeness must not invent a target for \(query)"); continue }
        }
    }

    func testExactGenericMultiwordProjectBeatsPolitenessStrippedTarget() throws {
        let brain = try commandNamedProjectFixture()
        let retriever = AssociativeRetriever(brain: brain)
        for query in ["Resume Please Continue please", "Resume please Please Continue please"] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .resolved(let project) = result else { XCTFail("Expected wrapped Please Continue for \(query)"); continue }
            XCTAssertEqual(project.name, "Please Continue")
        }
        try data.claim("trailing-please-name", "episode:casey", "project.name", "Continue Please",
            "The other project is Continue Please.", 10, brain: brain)
        for (query, expected) in [("Resume Please Continue", "Please Continue"), ("Resume Continue Please", "Continue Please"),
                                  ("Continue Please Continue", "Please Continue"), ("Continue Continue Please", "Continue Please")] {
            let result = try retriever.resumeProject(query: query, threadID: "fresh", scope: .user, asOf: now, budget: .init())
            guard case .resolved(let project) = result else { XCTFail("Expected full label \(expected)"); continue }
            XCTAssertEqual(project.name, expected)
        }
        let ambiguous = try retriever.resumeProject(query: "Resume Please Continue please", threadID: "fresh", scope: .user, asOf: now, budget: .init())
        guard case .clarify(let names) = ambiguous else { return XCTFail("Overlapping non-contained labels remain ambiguous") }
        XCTAssertEqual(Set(names), ["Please Continue", "Continue Please"])
    }

    private func commandNamedProjectFixture() throws -> BrainStore {
        let brain = try data.fixture()
        let labels = [("project:aurora", "Aurora CLI"), ("project:aurora-web", "Aurora Web Platform"),
                      ("person:robin", "Continue"), ("topic:bridge", "Project"), ("game:call-of-duty", "Please"),
                      ("device:robin-console", "Gemma"), ("episode:recent", "Please Continue")]
        for (index, entry) in labels.enumerated() {
            try data.claim("command-name-\(index)", entry.0, "project.name", entry.1,
                "The registered project is \(entry.1).", Double(index + 1), brain: brain)
        }
        return brain
    }
}
