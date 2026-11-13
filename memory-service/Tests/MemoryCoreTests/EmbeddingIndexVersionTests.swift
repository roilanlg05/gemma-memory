import XCTest
import BrainContract
import GRDB
@testable import MemoryCore

final class EmbeddingIndexVersionTests: XCTestCase {
    private let first = EmbeddingIndexVersion(modelID: "fixture/first", dimension: 2, revision: "r1")
    private let second = EmbeddingIndexVersion(modelID: "fixture/second", dimension: 2, revision: "r1")

    func testSameDimensionModelsOnlyRecallFromTheirActiveVersion() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 2)
        try store.bootstrapEmbeddingIndex(version: first)
        let oldState = try store.embeddingIndexState()
        let alpha = try insert("alpha", in: store)
        let beta = try insert("beta", in: store)
        try store.setEmbedding(nodeId: alpha.id, [1, 0], version: first, sourceText: alpha.label)
        try store.setEmbedding(nodeId: beta.id, [0, 1], version: first, sourceText: beta.label)

        try await store.rebuildIndex(version: second) { texts in
            texts.map { $0 == "beta" ? [1, 0] : [0, 1] }
        }
        XCTAssertEqual(try store.nearest(to: [1, 0], k: 1, version: first).first?.id, alpha.id)
        XCTAssertTrue(try store.nearest(to: [1, 0], k: 1, version: second).isEmpty)

        try store.activateIndex(version: second, expectedRevision: oldState.revision)
        XCTAssertEqual(try store.nearest(to: [1, 0], k: 1, version: second).first?.id, beta.id)
        XCTAssertTrue(try store.nearest(to: [1, 0], k: 1, version: first).isEmpty)
    }

    func testFailedRebuildKeepsOldIndexActiveAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("memory.sqlite").path
        let original = try MemoryStore(path: path, embeddingDim: 2)
        try original.bootstrapEmbeddingIndex(version: first)
        let oldState = try original.embeddingIndexState()
        let node = try insert("alpha", in: original)
        try original.setEmbedding(nodeId: node.id, [1, 0], version: first, sourceText: node.label)

        do {
            try await original.rebuildIndex(version: second) { texts in texts.map { _ in [1, .infinity] } }
            XCTFail("Nonfinite rebuild unexpectedly succeeded")
        } catch let error as EmbeddingIndexError {
            XCTAssertEqual(error, .invalidVector)
        }

        let reopened = try MemoryStore(path: path, embeddingDim: 7)
        XCTAssertThrowsError(try reopened.activateIndex(version: second, expectedRevision: oldState.revision))
        XCTAssertEqual(try reopened.embeddingIndexState(), oldState)
        XCTAssertEqual(try reopened.embeddingIndexState().version, first)
        XCTAssertEqual(try reopened.nearest(to: [1, 0], k: 1, version: first).first?.id, node.id)
        try await reopened.rebuildIndex(version: second) { texts in texts.map { _ in [0, 1] } }
        try reopened.activateIndex(version: second, expectedRevision: oldState.revision)
        XCTAssertEqual(try reopened.embeddingIndexState().version, second)
    }

    func testChangedSourceMakesStagedIndexUnfitForActivation() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 2)
        try store.bootstrapEmbeddingIndex(version: first)
        let oldState = try store.embeddingIndexState()
        var node = try insert("alpha", in: store)
        try store.setEmbedding(nodeId: node.id, [1, 0], version: first, sourceText: node.label)
        try await store.rebuildIndex(version: second) { texts in texts.map { _ in [0, 1] } }
        node.label = "edited label"
        try store.upsert(node)

        XCTAssertThrowsError(try store.activateIndex(version: second, expectedRevision: oldState.revision))
        XCTAssertEqual(try store.embeddingIndexState(), oldState)
        XCTAssertTrue(try store.nearest(to: [1, 0], k: 1, version: first).isEmpty)
    }

    func testLegacyMigrationPreservesRecallWithoutAssigningProviderIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let nodeID: String
        do {
            let old = try MemoryStore(url: url, embeddingDim: 2)
            nodeID = try insert("almanac", in: old).id
            try old.setEmbedding(nodeId: nodeID, [1, 0])
            // Reproduce the v23 on-disk schema and migration history while keeping legacy data.
            try await old.dbQueue.write { db in
                for trigger in ["insert", "delete", "change"] {
                    try db.execute(sql: "DROP TRIGGER embedding_node_\(trigger)")
                    try db.execute(sql: "DROP TRIGGER embedding_transcript_\(trigger)")
                }
                try db.execute(sql: """
                    DROP VIEW embedding_node_source;
                    DROP VIEW embedding_transcript_source;
                    DROP TABLE indexed_node_embedding;
                    DROP TABLE indexed_transcript_embedding;
                    DROP TABLE embedding_index_pointer;
                    DROP TABLE embedding_index;
                    DELETE FROM grdb_migrations WHERE identifier = 'v24-embedding-index';
                    """)
            }
        }
        let store = try MemoryStore(url: url, embeddingDim: 2)
        let retriever = MemoryRetriever(store: store, embedder: FixtureEmbedder(version: first))
        try store.bootstrapEmbeddingIndex(version: first)
        XCTAssertNil(try store.embeddingIndexState().version)
        XCTAssertEqual(try store.nearest(to: [1, 0], k: 1).first?.id, nodeID)
        XCTAssertTrue(try retriever.retrieve(query: "unrelatedword").isEmpty)
        XCTAssertEqual(try retriever.retrieve(query: "almanac").map(\.id), [nodeID])

        try await store.rebuildIndex(version: first) { texts in texts.map { _ in [1, 0] } }
        try store.activateIndex(version: first, expectedRevision: 0)
        XCTAssertEqual(try retriever.retrieve(query: "unrelatedword").map(\.id), [nodeID])
        let otherRetriever = MemoryRetriever(store: store, embedder: FixtureEmbedder(version: second))
        XCTAssertTrue(try otherRetriever.retrieve(query: "unrelatedword").isEmpty)
        XCTAssertEqual(try otherRetriever.retrieve(query: "almanac").map(\.id), [nodeID])
    }

    func testAuthorizedForgetPurgesRetiredAndActiveTranscriptVectorsAndFencesLateWrites() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 2)
        try store.bootstrapEmbeddingIndex(version: first)
        let transcript = TranscriptStore(dbQueue: store.dbQueue)
        let source = "distinct withdrawn phrase"
        let id = try transcript.append(threadId: "private", turnIndex: 0, role: "user", text: source)
        try store.setTranscriptEmbedding(turnId: id, [1, 0], version: first, sourceText: source)
        try store.setTranscriptEmbedding(turnId: id, [1, 0])
        try await store.rebuildIndex(version: second) { texts in texts.map { _ in [1, 0] } }
        try store.activateIndex(version: second, expectedRevision: store.embeddingIndexState().revision)
        XCTAssertEqual(try store.nearestTranscript(to: [1, 0], k: 1, version: second).first?.turnId, id)

        let brain = BrainStore(store: store, authorization: .init(
            principal: "owner", owner: "owner", subjects: ["self:user"], scopes: [.user], threads: ["private"],
            sourceSpeakers: [.userMessage: ["self:user"]], mayCommitClaims: true, mayForget: true))
        let third = EmbeddingIndexVersion(modelID: "fixture/third", dimension: 2, revision: "r1")
        do {
            try await store.rebuildIndex(version: third) { texts in
                _ = try brain.forget(scope: .init(kind: .thread, id: "private"),
                                     expectedRevision: brain.revision(), operationID: "forget-private")
                return texts.map { _ in [1, 0] }
            }
            XCTFail("A rebuild whose transcript was forgotten during embedding succeeded")
        } catch let error as EmbeddingIndexError {
            XCTAssertEqual(error, .sourceChanged)
        }
        XCTAssertEqual(try store.embeddingIndexState().version, second)
        XCTAssertTrue(try store.nearestTranscript(to: [1, 0], k: 1).isEmpty)
        XCTAssertTrue(try store.nearestTranscript(to: [1, 0], k: 1, version: second).isEmpty)
        for version in [nil, second] {
            let delayed = IndexEmbedding(values: [1, 0], version: version)
            XCTAssertThrowsError(try store.setTranscriptEmbedding(turnId: id, delayed, sourceText: source)) {
                XCTAssertEqual($0 as? EmbeddingIndexError, .sourceChanged)
            }
        }
        let remaining = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_transcript_embedding WHERE turn_id = ?", arguments: [id])
        }
        XCTAssertEqual(remaining, 0)
    }

    func testSupersedingAnInFlightRebuildKeepsItsReplacementReady() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 2)
        try store.bootstrapEmbeddingIndex(version: first)
        let oldRevision = try store.embeddingIndexState().revision
        let node = try insert("alpha", in: store)
        let version = second
        do {
            try await store.rebuildIndex(version: version) { texts in
                try await store.rebuildIndex(version: version) { replacement in replacement.map { _ in [0, 1] } }
                return texts.map { _ in [1, 0] }
            }
            XCTFail("A superseded build unexpectedly reached readiness")
        } catch let error as EmbeddingIndexError {
            XCTAssertEqual(error, .buildSuperseded)
        }
        try store.activateIndex(version: second, expectedRevision: oldRevision)
        let hit = try XCTUnwrap(try store.nearest(to: [0, 1], k: 1, version: second).first)
        XCTAssertEqual(hit.id, node.id)
        XCTAssertEqual(hit.distance, 0)
        XCTAssertThrowsError(try store.activateIndex(version: second, expectedRevision: oldRevision)) {
            XCTAssertEqual($0 as? EmbeddingIndexError, .staleRevision)
        }
    }

    func testCompressionLeavesBothSourcesIntactIfIndexChangesDuringEmbedding() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 2)
        try store.bootstrapEmbeddingIndex(version: first)
        let oldRevision = try store.embeddingIndexState().revision
        let alpha = try insert("alpha", in: store, kind: .insight, salience: 4)
        let beta = try insert("beta", in: store, kind: .insight)
        try store.setEmbedding(nodeId: alpha.id, [1, 0], version: first, sourceText: alpha.label)
        try await store.rebuildIndex(version: second) { texts in
            texts.map { $0 == "beta" ? [0, 1] : [1, 0] }
        }
        let replacement = second
        let embedder = FixtureEmbedder(version: first) { text in
            if text == "beta" { try store.activateIndex(version: replacement, expectedRevision: oldRevision) }
            return [1, 0]
        }
        XCTAssertEqual(try store.compressInsights(embedder: embedder), 0)
        XCTAssertEqual(try store.embeddingIndexState().version, second)
        XCTAssertEqual(try store.node(id: alpha.id), alpha)
        XCTAssertEqual(try store.node(id: beta.id), beta)
        XCTAssertTrue(try store.edges(from: beta.id).isEmpty)
    }

    private func insert(_ label: String, in store: MemoryStore, kind: NodeKind = .preference,
                        salience: Double = 3) throws -> Node {
        let node = Node(id: UUID().uuidString, kind: kind.rawValue, label: label, body: label,
                        layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: salience, decayRate: 0.001,
                        confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                        origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(node)
        return node
    }
}

private struct FixtureEmbedder: Embedder {
    let version: EmbeddingIndexVersion
    var values: @Sendable (String) throws -> [Float] = { _ in [1, 0] }
    var dimension: Int { version.dimension }
    var indexVersion: EmbeddingIndexVersion? { version }
    func embed(_ text: String) throws -> [Float] { try values(text) }
}
