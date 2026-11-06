import XCTest
import Foundation
import BrainContract
import GRDB
@testable import MemoryCore

/// Consolidation's output is not only a legacy node — an asserted identity is recorded as a
/// versioned, source-bound claim that cites the raw turn which established it. These tests pin the
/// claim side, and pin that it stays out of the legacy projection so the `self:user` node keeps
/// being writable exactly as before.
final class ConsolidationIdentityClaimTests: XCTestCase {

    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }

    private func reader(_ store: MemoryStore, threads: Set<String> = ["T"], now: Double = 9_000) -> BrainStore {
        BrainStore(store: store,
                   authorization: ConsolidationEvidenceAdapter.authorization(threads: threads),
                   clock: { now })
    }

    private func identityClaims(_ store: MemoryStore, asOf: Double = 9_000,
                                threads: Set<String> = ["T"]) throws -> [BrainClaim] {
        try reader(store, threads: threads)
            .claims(subject: selfUserID, asOf: asOf, scope: .user)
            .filter { $0.predicate == ConsolidationIdentityClaim.namePredicate }
    }

    private func engine(_ store: MemoryStore, _ ts: TranscriptStore, _ name: String,
                        now: Double) -> MemoryConsolidationEngine {
        let json = #"{"entities":[{"entity":"\#(name)","kind":"self","detail":"el usuario"}]}"#
        return MemoryConsolidationEngine(store: store, embedder: nil,
                                         runtime: SchemaAwareRuntime(["entities": json]),
                                         transcriptStore: ts, now: { now })
    }

    func test_acceptedIdentityCommitsSourceBoundClaim() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me llamo Roilan", now: 1_000)
        _ = await engine(store, ts, "Roilan", now: 2_000).runCycleReporting(isCancelled: { false })

        let claims = try identityClaims(store)
        XCTAssertEqual(claims.count, 1)
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(claim.subject, selfUserID)
        XCTAssertEqual(claim.predicate, "name")
        XCTAssertEqual(claim.value, .string("Roilan"))
        XCTAssertEqual(claim.modality, .asserted)
        XCTAssertEqual(claim.status, .active)
        XCTAssertEqual(claim.validFrom, 1_000, "valid from when the user said it, not when the cycle ran")
        XCTAssertEqual(claim.revision, 1)
        XCTAssertEqual(claim.evidenceIDs,
                       [ConsolidationEvidenceAdapter.evidenceID(threadID: "T", seq: 1, text: "me llamo Roilan")],
                       "the claim cites the turn that asserted it")
        XCTAssertNil(claim.supersedesID)
        // The legacy node still points at the same evidence, so the two views agree.
        XCTAssertEqual(try store.selfNode()?.sourceRef, claim.evidenceIDs.first)
    }

    func test_claimCitesARawTurnRootNotADerivedSummary() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me llamo Roilan", now: 1_000)
        _ = await engine(store, ts, "Roilan", now: 2_000).runCycleReporting(isCancelled: { false })

        let evidenceID = try XCTUnwrap(try identityClaims(store).first?.evidenceIDs.first)
        let stored = try await store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id = ?", arguments: [evidenceID])
        }
        let payload = try XCTUnwrap(stored)
        let evidence = try BrainStore.decode(BrainEvidence.self, payload)
        XCTAssertEqual(evidence.sourceKind, .userMessage, "the root is the user's own turn")
        XCTAssertEqual(evidence.speakerID, selfUserID)
        XCTAssertNil(evidence.parentEvidenceIDs, "a root of support, not a summary of roots")
        XCTAssertEqual(evidence.text, "me llamo Roilan")
    }

    func test_identityClaimDoesNotProjectAndLeavesTheLegacyNodeWritable() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me llamo Roilan", now: 1_000)
        _ = await engine(store, ts, "Roilan", now: 2_000).runCycleReporting(isCancelled: { false })

        let projections = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_projection") ?? 0
        }
        let bindings = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM brain_legacy_binding") ?? 0
        }
        XCTAssertEqual(projections, 0, "a consolidation claim never enters the legacy projection")
        XCTAssertEqual(bindings, 0)
        let claimID = try XCTUnwrap(try identityClaims(store).first).id
        XCTAssertNil(try store.node(id: "brain-claim:" + claimID), "no projected claim node is published")
        // The decisive property: `self:user` was never captured as a managed node, so the legacy
        // identity path still works.
        XCTAssertNoThrow(try store.upsertSelf(name: "Roilan", detail: "el usuario", now: 5_000))
        XCTAssertEqual(try store.selfNode()?.label, "Roilan")
    }

    func test_replayedExtractionCommitsNoSecondClaim() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me llamo Roilan", now: 1_000)
        let rows = try ts.unconsolidated(limit: 10)
        let segment = ConsolidationSegment(threadID: "T", rows: rows)
        let json = #"{"entities":[{"entity":"Roilan","kind":"self","detail":"el usuario"}]}"#
        // Two direct runs with no job between them: nothing but the claim's own idempotency and
        // the already-active value can prevent a second commit.
        let first = MemoryConsolidationEngine(store: store, embedder: nil, runtime: CannedRuntime([json]),
                                              transcriptStore: ts, now: { 2_000 })
        let firstOutcome = await first.consolidate(segment: segment).outcome
        XCTAssertEqual(firstOutcome, .committed)
        let second = MemoryConsolidationEngine(store: store, embedder: nil, runtime: CannedRuntime([json]),
                                               transcriptStore: ts, now: { 3_000 })
        let secondOutcome = await second.consolidate(segment: segment).outcome
        XCTAssertNotEqual(secondOutcome, .failed)

        XCTAssertEqual(try identityClaims(store).count, 1)
        XCTAssertEqual(try reader(store).revision(), 1, "a replay does not advance the revision")
    }

    func test_correctedIdentitySupersedesTheEarlierClaim() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "me llamo Roilan", now: 1_000)
        _ = await engine(store, ts, "Roilan", now: 2_000).runCycleReporting(isCancelled: { false })
        try ts.append(threadId: "T", turnIndex: 1, role: "user", text: "me llamo Juan", now: 4_000)
        _ = await engine(store, ts, "Juan", now: 5_000).runCycleReporting(isCancelled: { false })

        let current = try identityClaims(store)
        XCTAssertEqual(current.map { $0.value }, [.string("Juan")], "only the correction is active now")
        let juan = try XCTUnwrap(current.first)
        XCTAssertEqual(juan.validFrom, 4_000)
        XCTAssertNotNil(juan.supersedesID, "the earlier name is superseded, not overwritten")
        XCTAssertEqual(juan.revision, 2)

        // The history is still readable: as of before the correction, the earlier name holds.
        let earlier = try identityClaims(store, asOf: 2_000)
        XCTAssertEqual(earlier.map { $0.value }, [.string("Roilan")])
    }

    func test_rejectedIdentityCommitsNoClaim() async throws {
        let store = try makeStore()
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user",
                      text: "mi esposa dice que soy terco", now: 1_000)
        let json = #"{"entities":[{"entity":"terco","kind":"self","detail":"el usuario es terco"}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                               runtime: SchemaAwareRuntime(["entities": json]),
                                               transcriptStore: ts, now: { 2_000 })
        _ = await engine.runCycleReporting(isCancelled: { false })

        XCTAssertNil(try store.selfNode())
        XCTAssertTrue(try identityClaims(store).isEmpty,
                      "an unsubstantiated identity reaches neither the node nor the claim store")
        XCTAssertEqual(try reader(store).revision(), 0)
    }

    func test_consolidationNeverGrantsItselfProjectionOrErasure() {
        let auth = ConsolidationEvidenceAdapter.authorization(threads: ["T"])
        XCTAssertTrue(auth.mayCommitClaims, "claims are what consolidation is allowed to write")
        XCTAssertFalse(auth.mayProject)
        XCTAssertFalse(auth.mayForget)
    }
}
