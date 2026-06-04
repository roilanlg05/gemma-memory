import XCTest
import GRDB
@testable import MemoryCore

final class TranscriptEmbeddingTests: XCTestCase {
    private func vec(_ i: Int) -> [Float] { var v = [Float](repeating: 0, count: 1024); v[i] = 1; return v }

    func test_set_nearest_delete_roundTrip() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        try store.setTranscriptEmbedding(turnId: "a", vec(0))
        try store.setTranscriptEmbedding(turnId: "b", vec(500))
        let hits = try store.nearestTranscript(to: vec(0), k: 2)
        XCTAssertEqual(hits.first?.turnId, "a")
        try store.deleteTranscriptEmbeddings(turnIds: ["a"])
        XCTAssertEqual(try store.nearestTranscript(to: vec(0), k: 2).first?.turnId, "b")
    }

    func test_append_returns_id_and_markConsolidated_deletes_embedding() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let t = TranscriptStore(dbQueue: store.dbQueue)
        let id = try t.append(threadId: "x", turnIndex: 0, role: "user", text: "hola")
        try store.setTranscriptEmbedding(turnId: id, vec(1))
        XCTAssertEqual(try store.nearestTranscript(to: vec(1), k: 1).first?.turnId, id)
        try t.markConsolidated(ids: [id])
        XCTAssertTrue(try store.nearestTranscript(to: vec(1), k: 1).isEmpty)
    }
}
