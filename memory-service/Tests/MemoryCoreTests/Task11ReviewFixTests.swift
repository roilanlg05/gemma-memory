import XCTest
import BrainContract
import GRDB
@testable import MemoryCore

private struct ReviewEmptyExtractor: BrainTurnExtractor {
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal] { [] }
}

private struct ReviewCancellingSelector: ConversationDetailSelector {
    func select(_ input: ConversationSelectionInput) async throws -> ConversationSelection {
        withUnsafeCurrentTask { $0?.cancel() }
        return .init()
    }
}

final class Task11ReviewFixTests: XCTestCase {
    private let data = Task11RecallTests()
    private let now: Double = 100_000

    func testNewUnstableTurnRevokesPendingAndFinalized() async throws {
        let brain = try data.bridgeFixture()
        let recall = AssociativeRetriever(brain: brain)
        func cue(_ id: String, stable: Bool = true) -> RecallTurnCue {
            .init(connectionID: "live", turnID: id, text: stable ? "crossing the bridge" : "", isStable: stable)
        }
        let session = recall.makeCueSession(connectionID: "live", threadID: "fresh", scope: .user)
        let result = try await session.finalize(final: cue("old"), asOf: now, budget: .init())
        let prepared = try XCTUnwrap(result)
        _ = try await session.prefetch(cue("new", stable: false), asOf: now, budget: .init())
        XCTAssertFalse(prepared.matches(brain: brain, connectionID: "live", turnID: "old", threadID: "fresh", scope: .user, query: "crossing the bridge"))
        let other = recall.makeCueSession(connectionID: "live", threadID: "fresh", scope: .user)
        let handle = try await other.prefetch(cue("pending"), asOf: now, budget: .init())
        _ = try await other.prefetch(cue("new", stable: false), asOf: now, budget: .init())
        let stale = try await other.finalize(handle, final: cue("pending"), asOf: now, budget: .init())
        XCTAssertNil(stale)
    }

    func testDirectLabelFindsSameSubjectWithoutGraphHops() async throws {
        let brain = try data.fixture()
        try data.claim("label", "device:robin-console", "recall.label", "Robin", "A name for this device.", 1, brain: brain)
        try data.claim("repaired", "device:robin-console", "recall.state", "The console was repaired.", "The console was repaired.", 2, brain: brain)
        // Use a label unrelated to the opaque subject as well, so the label is the only signal.
        try data.claim("alias", "episode:recent", "recall.label", "Taylor", "An authorized label.", 3, brain: brain)
        try data.claim("visit", "episode:recent", "recall.episode", "The console was repaired.", "The console was repaired.", 4, brain: brain)
        let recall = AssociativeRetriever(brain: brain)
        for (query, id) in [("Robin", "repaired"), ("Taylor", "visit")] {
            let result = try await recall.retrieve(query: query, threadID: "fresh", scope: .user, asOf: now,
                budget: .init(maximumHops: 0))
            XCTAssertTrue(result.candidates.contains { $0.claim.id == id })
        }
    }

    func testForgottenCorrectionKeepsPredecessorHistoricalAcrossReaders() async throws {
        let brain = try data.fixture(project: true)
        let subject = "device:robin-console"
        try data.claim("broken", subject, "recall.state", "The console was broken.", "The old unit failed yesterday.", 5, brain: brain)
        let before = try brain.revision()
        try data.claim("repair", subject, "recall.state", "The console was repaired.", "A technician finished replacing the board.", 20, brain: brain, supersedes: "broken")
        let receipt = try brain.forget(scope: .init(kind: .claim, id: "repair"), expectedRevision: brain.revision(), operationID: "erase-correction")
        XCTAssertFalse(receipt.forgottenClaimIDs.contains("broken"))
        XCTAssertEqual(try brain.claims(subject: subject, asOf: 10, scope: .user).map(\.id), ["broken"])
        XCTAssertEqual(try brain.claims(subject: subject, asOf: now, scope: .user, knownAtRevision: before).map(\.id), ["broken"])
        XCTAssertTrue(try brain.claims(subject: subject, asOf: now, scope: .user).isEmpty)
        XCTAssertFalse(try ConversationStateStore(brain: brain).snapshot(threadID: "fresh").claims.contains { $0.id == "broken" })
        let recall = AssociativeRetriever(brain: brain)
        let current = try await recall.retrieve(query: "console", threadID: "fresh", scope: .user, asOf: now, budget: .init())
        XCTAssertTrue(current.candidates.isEmpty)
        let past = try await recall.retrieve(query: "console", threadID: "fresh", scope: .user, asOf: 10, budget: .init())
        XCTAssertEqual(past.candidates.map(\.claim.id), ["broken"])
        try brain.reconcileProjections(now: now)
        let deleted = try await brain.store.dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT deleted FROM node WHERE id='brain-claim:broken'")
        }
        XCTAssertEqual(deleted, true)
        try brain.applyExclusions([receipt])
        XCTAssertTrue(try brain.claims(subject: subject, asOf: now, scope: .user).isEmpty)
    }

    func testStartupUsesTranscriptSequenceForEqualClockTurns() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 16)
        let auth = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user],
            threads: ["past", "fresh"], sourceSpeakers: [.userMessage: ["self:user"], .assistantMessage: ["self:agent"]],
            mayCommitClaims: true, mayForget: true)
        let brain = BrainStore(store: store, authorization: auth, clock: { 10 })
        let service = BrainTurnService(store: store, authorization: auth, extractor: ReviewEmptyExtractor(), clock: { 10 })
        for index in 0..<8 {
            let turn = try await service.begin(.init(clientOperationID: "turn-\(index)", threadID: "past",
                message: .init(id: "input-\(index)", speakerID: "self:user", text: "Opening \(index)", observedAt: 10, evidenceIDs: []),
                budget: .init(contextTokens: 4096, outputTokens: 100)))
            _ = try service.recordAssistant(turnID: turn.turnID, operationID: "reply-\(index)", text: "Closing \(index)")
        }
        let orientation = try XCTUnwrap(AssociativeRetriever(brain: brain).startupOrientation(threadID: "fresh", scope: .user, asOf: now))
        XCTAssertEqual(orientation.opening?.text, "Opening 0")
        XCTAssertEqual(orientation.closing?.text, "Closing 7")
    }
}

extension Task11ReviewFixTests {
    func testCancellationDuringSelectionNeverPublishesContext() async throws {
        let brain = try data.fixture()
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain), selector: ReviewCancellingSelector())
        let task = Task {
            try await assembler.context(.init(clientOperationID: "cancelled", threadID: "fresh", query: "hello",
                budget: .init(contextTokens: 16_000, outputTokens: 100)))
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled context request must not publish its assembled bundle")
        } catch is CancellationError { }
    }

    func testDispositionSurvivesRestoreAndDoesNotBlockReusedIDs() throws {
        let brain = try data.fixture()
        let subject = "device:robin-console"
        try data.claim("original", subject, "recall.state", "The original report.", "Original source for first report.", 5, brain: brain)
        try data.claim("correction", subject, "recall.state", "A corrected report.", "Distinct correction source statement.", 20, brain: brain, supersedes: "original")
        let saved = try brain.store.dbQueue.read { db in
            try XCTUnwrap(String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id='correction'"))
        }
        let receipt = try brain.forget(scope: .init(kind: .claim, id: "correction"), expectedRevision: brain.revision(), operationID: "forget-first-correction")
        try brain.store.dbQueue.write { db in
            let claim = try BrainStore.decode(BrainClaim.self, saved)
            try db.execute(sql: "INSERT INTO brain_claim(id,subject,predicate,revision,payload) VALUES (?,?,?,?,?)",
                arguments: [claim.id, claim.subject, claim.predicate, claim.revision, saved])
        }
        try brain.applyExclusions([receipt])
        XCTAssertTrue(try brain.claims(subject: subject, asOf: now, scope: .user).isEmpty)
        // A new, evidenced correction is still legal after the earlier correction was erased.
        try data.claim("new-correction", subject, "recall.state", "A later independent correction.", "Later technician evidence is distinct.", 30, brain: brain, supersedes: "original")
        XCTAssertEqual(try brain.claims(subject: subject, asOf: now, scope: .user).map(\.id), ["new-correction"])
        _ = try brain.forget(scope: .init(kind: .claim, id: "new-correction"), expectedRevision: brain.revision(), operationID: "forget-later")
        _ = try brain.forget(scope: .init(kind: .claim, id: "original"), expectedRevision: brain.revision(), operationID: "forget-original")
        try data.claim("original", subject, "recall.state", "A new assertion under the reusable ID.", "Completely new source for another observation.", 40, brain: brain)
        // Replay the old correction into the new predecessor ID: exclusion reapplication must
        // erase it without assigning its old disposition to the new assertion.
        try brain.store.dbQueue.write { db in
            let claim = try BrainStore.decode(BrainClaim.self, saved)
            try db.execute(sql: "INSERT INTO brain_claim(id,subject,predicate,revision,payload) VALUES (?,?,?,?,?)",
                arguments: [claim.id, claim.subject, claim.predicate, claim.revision, saved])
        }
        try brain.applyExclusions([receipt])
        XCTAssertEqual(try brain.claims(subject: subject, asOf: now, scope: .user).map(\.id), ["original"])
        _ = try brain.forget(scope: .init(kind: .all), expectedRevision: brain.revision(), operationID: "forget-everything")
        let count = try brain.store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_supersession_disposition")
        }
        XCTAssertEqual(count, 0)
    }
}

extension Task11ReviewFixTests {
    func testSameCommitCorrectionErasurePreservesHistoricalPredecessor() throws {
        let brain = try data.fixture()
        let subject = "device:robin-console"
        let firstSource = BrainEvidence(id: "batch-first-source", sourceKind: .userMessage, speakerID: "self:user",
            threadID: "past", observedAt: 5, recordedAt: 5, accessScope: .user, text: "First device observation.")
        let secondSource = BrainEvidence(id: "batch-second-source", sourceKind: .userMessage, speakerID: "self:user",
            threadID: "past", observedAt: 20, recordedAt: 20, accessScope: .user, text: "Later repair certificate arrived.")
        let first = BrainClaim(id: "batch-first", revision: 0, subject: subject, predicate: "recall.state",
            value: .string("Broken"), modality: .asserted, status: .active, validFrom: 5, recordedAt: 5,
            evidenceIDs: [firstSource.id])
        let second = BrainClaim(id: "batch-second", revision: 0, subject: subject, predicate: "recall.state",
            value: .string("Repaired"), modality: .asserted, status: .active, validFrom: 20, recordedAt: 20,
            evidenceIDs: [secondSource.id], supersedesID: first.id)
        let committed = try brain.commit(.init(clientOperationID: "batch", evidence: [firstSource, secondSource],
            updates: [.init(claim: first), .init(claim: second)], expectedRevision: 0))
        XCTAssertEqual(committed.disposition, .committed)
        let before = try brain.store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_supersession_disposition")
        }
        XCTAssertEqual(before, 0, "Live correction visibility retains existing reader semantics")
        _ = try brain.forget(scope: .init(kind: .claim, id: second.id), expectedRevision: brain.revision(), operationID: "forget-batch-second")
        XCTAssertTrue(try brain.claims(subject: subject, asOf: now, scope: .user).isEmpty)
        XCTAssertEqual(try brain.claims(subject: subject, asOf: 10, scope: .user).map(\.id), [first.id])
        let row = try brain.store.dbQueue.read { db in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM brain_supersession_disposition"))
        }
        XCTAssertEqual(Set(row.columnNames), Set(["predecessor_id", "assertion_fingerprint", "effective_at", "recorded_at", "revision"]))
        XCTAssertEqual(row["predecessor_id"] as String, first.id)
        XCTAssertEqual(row["revision"] as Int64, committed.revision)
    }
}
