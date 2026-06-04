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
}
