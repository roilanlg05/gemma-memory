import XCTest
import GRDB
@testable import MemoryCore

final class MemoryIntegrityTests: XCTestCase {
    private func store() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }
    private func node(_ id: String, body: String = "Original detail", kind: NodeKind = .fact,
                      layer: MemoryLayer = .daily, origin: Origin = .extracted,
                      confidence: Confidence = .maybe, time: Double = 100,
                      source: String? = "synthetic:turn:1", extra: String? = nil) -> Node {
        Node(id: id, kind: kind.rawValue, label: "Shared label", body: body, layer: layer,
             createdAt: time, updatedAt: time, lastSeenAt: time, salience: 3, decayRate: 0,
             confidence: confidence, mentionCount: 1, ttlExpiresAt: nil, sourceRef: source,
             origin: origin, serverId: nil, dirty: true, deleted: false, extra: extra)
    }
    private func conflicts(_ node: Node) throws -> [[String: Any]] {
        let data = try XCTUnwrap(node.extra?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["mergeConflicts"] as? [[String: Any]])
    }

    // Catches silently dropping differing details, or replacing trusted evidence with a proposal.
    func testChangedNonemptyDetailRetainsExplicitObservableConflict() throws {
        let s = try store()
        try s.upsert(node("canonical", origin: .explicit, confidence: .sure))
        let id = try s.upsertMerging(node("proposal", body: "Different detail", time: 200,
                                          source: "synthetic:turn:2"))
        XCTAssertEqual(id, "canonical")
        let saved = try XCTUnwrap(s.node(id: id))
        XCTAssertEqual(saved.body, "Original detail")
        XCTAssertEqual(saved.sourceRef, "synthetic:turn:1")
        XCTAssertEqual(saved.origin, .explicit)
        XCTAssertEqual(saved.confidence, .sure)
        let conflict = try XCTUnwrap(conflicts(saved).first)
        XCTAssertEqual(conflict["body"] as? String, "Different detail")
        XCTAssertEqual(conflict["sourceRef"] as? String, "synthetic:turn:2")
        XCTAssertEqual(conflict["updatedAt"] as? Double, 200)
        XCTAssertEqual(conflict["confidence"] as? String, "maybe")
        let block = MemoryRetriever(store: s, embedder: nil).injectionBlock(for: [saved])
        XCTAssertTrue(block.contains("conflict"))
        XCTAssertTrue(block.contains("unresolved"))
        XCTAssertTrue(block.contains("resolve before asserting"))
        XCTAssertTrue(block.contains("Different detail"))
        XCTAssertTrue(block.contains("synthetic:turn:2"))
    }

    // Catches binding an old gist to a newer segment, including out-of-order arrivals.
    func testSummaryBodyAndSourceRangeSelectOneRevision() throws {
        let s = try store()
        let old = node("summary", body: "Earlier gist", kind: .summary, time: 100,
                       extra: #"{"threadId":"synthetic-thread","turnRange":[1,2]}"#)
        let latest = node("new", body: "Later gist", kind: .summary, confidence: .probable,
                          time: 200, source: "synthetic:turn:4",
                          extra: #"{"threadId":"synthetic-thread","turnRange":[3,4]}"#)
        try s.upsert(old)
        XCTAssertEqual(try s.upsertMerging(latest), "summary")
        var saved = try XCTUnwrap(s.node(id: "summary"))
        XCTAssertEqual(saved.body, "Later gist")
        XCTAssertEqual(saved.extra, latest.extra)
        XCTAssertEqual(saved.sourceRef, "synthetic:turn:4")
        XCTAssertEqual(saved.confidence, .probable)
        _ = try s.upsertMerging(old)
        saved = try XCTUnwrap(s.node(id: "summary"))
        XCTAssertEqual(saved.body, "Later gist")
        XCTAssertEqual(saved.extra, latest.extra)
        XCTAssertEqual(saved.sourceRef, "synthetic:turn:4")
        XCTAssertEqual(saved.updatedAt, 200)
    }

    func testRepeatedInferenceAndExplicitMentionsDoNotDeclareIdentity() throws {
        for origin in [Origin.extracted, .explicit] {
            let s = try store()
            for i in 0..<3 { _ = try s.upsertMerging(node("mention-\(i)", origin: origin)) }
            let saved = try XCTUnwrap(s.allNodes().first)
            XCTAssertEqual(saved.mentionCount, 3)
            XCTAssertEqual(saved.layer, .daily)
            XCTAssertTrue(try s.coreMemories().isEmpty)
        }
    }

    // Catches both exact-label and vector branches collapsing known subjects or owners.
    func testSubjectAndOwnerCollisionsStayDistinctInBothMergePaths() throws {
        let scopes = [
            (#"{"subjectId":"self:user"}"#, #"{"subjectId":"self:agent"}"#),
            (#"{"ownerID":"synthetic:one"}"#, #"{"ownerID":"synthetic:two"}"#),
            (#"{"subjectId":"self:user"}"#, "{}"),
            (#"{"scope":"thread","threadId":"one"}"#, "{}"),
            (#"{"scope":"thread","threadId":"one"}"#, #"{"accessScope":"thread","threadID":"two"}"#)
        ]
        for semantic in [false, true] {
            for (a, b) in scopes {
                let s = try store()
                try s.upsert(node("a", extra: a))
                try s.setEmbedding(nodeId: "a", [1, 0, 0, 0])
                let candidate = node("b", extra: b)
                let id = try semantic
                    ? s.upsertMergingSemantic(candidate, embedding: [1, 0, 0, 0], embedder: nil)
                    : s.upsertMerging(candidate)
                XCTAssertEqual(id, "b")
                XCTAssertEqual(try s.allNodes().count, 2)
            }
        }
    }

    func testAmbiguousIdentityAndReservedIDsStaySeparate() throws {
        for ids in [("chosen:one", "chosen:two"), ("self:user", "self:agent"),
                    ("self:agent", "relationship:user:agent")] {
            let s = try store()
            try s.upsert(node(ids.0, layer: .identity, origin: .explicit))
            XCTAssertEqual(try s.upsertMerging(node(ids.1, layer: .identity)), ids.1)
            XCTAssertEqual(try s.allNodes().count, 2)
        }
    }

    func testDeliberateIdentitySurvivesReinforcementAndSweep() throws {
        let s = try store()
        try s.upsert(node("chosen", layer: .identity, origin: .explicit))
        _ = try s.upsertMerging(node("chosen", layer: .identity, time: 200))
        try s.sweep(now: 999999)
        XCTAssertEqual(try s.node(id: "chosen")?.layer, .identity)
        XCTAssertEqual(try s.node(id: "chosen")?.deleted, false)
    }

    // Catches only filtering deleted hits after top-k, and stale vectors restored after deletion.
    func testDeletedVectorsCannotCrowdLiveTopK() throws {
        let s = try store()
        for i in 0..<5 {
            let id = "deleted-\(i)"
            try s.upsert(node(id))
            try s.setEmbedding(nodeId: id, [1, 0, 0, 0])
            try s.softDelete(nodeId: id)
        }
        XCTAssertTrue(try s.allEmbeddings().isEmpty)
        let storedCount = try s.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM node_embedding") }
        XCTAssertEqual(storedCount, 0, "Deletion must remove the stored vectors, not only hide them")
        // Emulates stale persisted indexes from older versions or an asynchronous embedding write.
        try s.setEmbedding(nodeId: "deleted-0", [1, 0, 0, 0])
        try s.setEmbedding(nodeId: "missing", [1, 0, 0, 0])
        try s.upsert(node("live", body: "Available evidence"))
        try s.setEmbedding(nodeId: "live", [1, 0.1, 0, 0])
        XCTAssertEqual(try s.nearest(to: [1, 0, 0, 0], k: 1).map(\.id), ["live"])
        let got = try MemoryRetriever(store: s, embedder: nil)
            .retrieve(query: "unmatched", k: 1, now: 200, queryVector: [1, 0, 0, 0])
        XCTAssertEqual(got.map(\.id), ["live"])
    }

    func testRenderingRetainsConfidenceOriginDateAndSource() throws {
        let s = try store()
        let n = node("uncertain", time: 1735689600, source: "synthetic:turn:9")
        let text = MemoryRetriever(store: s, embedder: nil).injectionBlock(for: [n])
        for marker in ["maybe", "extracted", "2025-01-01", "synthetic:turn:9"] {
            XCTAssertTrue(text.contains(marker), "Missing evidence label: \(marker)")
        }
    }

    func testCompressionPreservesConflictingDetailsAndSubjectBoundaries() throws {
        let s = try store()
        for (id, subject, body) in [("a", "self:user", "First detail"),
                                    ("b", "self:user", "Second detail"),
                                    ("c", "self:agent", "Agent detail")] {
            try s.upsert(node(id, body: body, kind: .insight,
                              extra: "{\"subjectId\":\"\(subject)\"}"))
            try s.setEmbedding(nodeId: id, [1, 0, 0, 0])
        }
        XCTAssertEqual(try s.compressInsights(embedder: nil), 1)
        let live = try s.allNodes()
        XCTAssertEqual(live.count, 2)
        let user = try XCTUnwrap(live.first { $0.id == "a" || $0.id == "b" })
        let details = Set([user.body] + (try conflicts(user)).compactMap { $0["body"] as? String })
        XCTAssertEqual(details, ["First detail", "Second detail"])
        XCTAssertFalse(try XCTUnwrap(s.node(id: "c")).deleted)
    }

    func testLaterConsolidationTimeDoesNotOverrideOlderSummaryEvidence() throws {
        let s = try store()
        let latest = node("summary", body: "Later evidence", kind: .summary, time: 200,
                          source: "synthetic:turn:4",
                          extra: #"{"threadId":"synthetic-thread","turnRange":[3,4]}"#)
        try s.upsert(latest)
        _ = try s.upsertMerging(node("late-job", body: "Older evidence", kind: .summary,
                                    time: 900, source: "synthetic:turn:2",
                                    extra: #"{"threadId":"synthetic-thread","turnRange":[1,2]}"#))
        let saved = try XCTUnwrap(s.node(id: "summary"))
        XCTAssertEqual(saved.body, "Later evidence")
        XCTAssertEqual(saved.extra, latest.extra)
        XCTAssertEqual(saved.sourceRef, "synthetic:turn:4")
    }

    func testUnorderedSummaryRevisionRetainsWholeAlternativeAsConflict() throws {
        let s = try store()
        try s.upsert(node("summary", body: "First gist", kind: .summary, time: 100,
                          extra: #"{"threadId":"synthetic-one","turnRange":[1,2]}"#))
        let alternate = node("other", body: "Other gist", kind: .summary, time: 900,
                             source: "synthetic:turn:8",
                             extra: #"{"threadId":"synthetic-two","turnRange":[7,8]}"#)
        _ = try s.upsertMerging(alternate)
        let saved = try XCTUnwrap(s.node(id: "summary"))
        XCTAssertEqual(saved.body, "First gist")
        let json = try XCTUnwrap(saved.extra?.data(using: .utf8))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(metadata["threadId"] as? String, "synthetic-one")
        let conflict = try XCTUnwrap(conflicts(saved).first)
        XCTAssertEqual(conflict["body"] as? String, "Other gist")
        XCTAssertEqual(conflict["extra"] as? String, alternate.extra)
        XCTAssertEqual(conflict["sourceRef"] as? String, "synthetic:turn:8")
    }
    func testCanonicalSummaryReplayDoesNotBecomeAnAlternative() throws {
        let s = try store()
        let canonical = node("summary", body: "First gist", kind: .summary, time: 100,
                             extra: #"{"threadId":"synthetic-one","turnRange":[1,2]}"#)
        try s.upsert(canonical)
        _ = try s.upsertMerging(node("other", body: "Other gist", kind: .summary, time: 900,
                                    source: "synthetic:turn:8",
                                    extra: #"{"threadId":"synthetic-two","turnRange":[7,8]}"#))
        _ = try s.upsertMerging(canonical)
        let alternatives = try conflicts(XCTUnwrap(s.node(id: "summary")))
        XCTAssertEqual(alternatives.count, 1)
        XCTAssertEqual(alternatives.first?["body"] as? String, "Other gist")
    }

    func testSameIDCannotSilentlyReassignKnownSubject() throws {
        let s = try store()
        try s.upsert(node("canonical", extra: #"{"subjectId":"self:user"}"#))
        XCTAssertThrowsError(try s.upsertMerging(node("canonical", body: "Agent detail",
                                                    extra: #"{"subjectId":"self:agent"}"#)))
        XCTAssertEqual(try s.node(id: "canonical")?.body, "Original detail")
    }


    func testRenderingKeepsKnownSubjectsAndOwnersDistinct() throws {
        let s = try store()
        let user = node("user-fact", extra: #"{"subjectId":"self:user","ownerId":"synthetic:owner"}"#)
        let agent = node("agent-fact", extra: #"{"subjectID":"self:agent"}"#)
        let reserved = node("relationship:user:agent", layer: .identity)
        let text = MemoryRetriever(store: s, embedder: nil).injectionBlock(for: [user, agent, reserved])
        for marker in ["subject=self:user", "subject=self:agent", "owner=synthetic:owner", "subject=relationship:user:agent"] {
            XCTAssertTrue(text.contains(marker), "Missing scope: \(marker)")
        }
        XCTAssertFalse(text.contains("about the user"), "The heading cannot assign every subject to the user")
    }


    func testDeletedIDCannotReassignKnownSubjectOnResurrection() throws {
        for semantic in [false, true] {
            let s = try store()
            try s.upsert(node("canonical", extra: #"{"subjectId":"self:user"}"#))
            try s.softDelete(nodeId: "canonical")
            let other = node("canonical", body: "Agent detail", extra: #"{"subjectId":"self:agent"}"#)
            if semantic {
                XCTAssertThrowsError(try s.upsertMergingSemantic(other, embedding: [1, 0, 0, 0], embedder: nil))
            } else {
                XCTAssertThrowsError(try s.upsertMerging(other))
            }
            let saved = try XCTUnwrap(s.node(id: "canonical"))
            XCTAssertTrue(saved.deleted)
            XCTAssertEqual(saved.body, "Original detail")
        }
    }

}
