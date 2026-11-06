import XCTest
import GRDB
@testable import MemoryCore

final class TranscriptSeqTests: XCTestCase {
    func test_append_assigns_monotonic_seq_per_thread() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        _ = try ts.append(threadId: "A", turnIndex: 0, role: "user", text: "a1")
        _ = try ts.append(threadId: "A", turnIndex: 0, role: "assistant", text: "a2")
        _ = try ts.append(threadId: "B", turnIndex: 0, role: "user", text: "b1")
        _ = try ts.append(threadId: "A", turnIndex: 1, role: "user", text: "a3")
        let aRows = try ts.range(threadId: "A", from: 1, to: 99)
        XCTAssertEqual(aRows.map { $0.seq }, [1, 2, 3])       // per-thread 1..N
        XCTAssertEqual(aRows.map { $0.text }, ["a1", "a2", "a3"])
        let bRows = try ts.range(threadId: "B", from: 1, to: 99)
        XCTAssertEqual(bRows.map { $0.seq }, [1])             // independent thread restarts at 1
        let mid = try ts.range(threadId: "A", from: 2, to: 2) // single-message range
        XCTAssertEqual(mid.map { $0.text }, ["a2"])
    }

    func test_purged_tail_sequence_is_never_reused_in_range() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        _ = try ts.append(threadId: "A", turnIndex: 0, role: "user", text: "first")
        let tail = try ts.append(threadId: "A", turnIndex: 1, role: "user", text: "forgotten")
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcript WHERE id = ?", arguments: [tail])
        }
        _ = try ts.append(threadId: "A", turnIndex: 2, role: "user", text: "later")
        XCTAssertTrue(try ts.range(threadId: "A", from: 2, to: 2).isEmpty)
        XCTAssertEqual(try ts.range(threadId: "A", from: 3, to: 3).map(\.text), ["later"])
    }
}
