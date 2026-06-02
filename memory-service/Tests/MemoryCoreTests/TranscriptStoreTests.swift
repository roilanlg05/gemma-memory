import XCTest
import GRDB
@testable import MemoryCore

final class TranscriptStoreTests: XCTestCase {
    private func makeStore() throws -> TranscriptStore {
        let mem = try MemoryStore(inMemory: true, embeddingDim: 8)
        return TranscriptStore(dbQueue: mem.dbQueue)
    }

    func test_append_and_recent_ordered_oldestFirst() throws {
        let s = try makeStore()
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "hola", now: 1)
        try s.append(threadId: "t", turnIndex: 0, role: "assistant", text: "buenas", now: 2)
        try s.append(threadId: "t", turnIndex: 1, role: "user", text: "que tal", now: 3)
        let rows = try s.recent(threadId: "t", maxTurns: 10, maxChars: 10_000)
        XCTAssertEqual(rows.map { $0.role }, ["user", "assistant", "user"])
        XCTAssertEqual(rows.map { $0.text }, ["hola", "buenas", "que tal"])
    }

    func test_recent_caps_by_turns_keepingNewest() throws {
        let s = try makeStore()
        for i in 0..<5 { try s.append(threadId: "t", turnIndex: i, role: "user", text: "m\(i)", now: Double(i)) }
        let rows = try s.recent(threadId: "t", maxTurns: 2, maxChars: 10_000)
        XCTAssertEqual(rows.map { $0.text }, ["m3", "m4"], "keeps the newest, still oldest-first")
    }

    func test_recent_caps_by_chars_keepingNewest() throws {
        let s = try makeStore()
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "aaaa", now: 1)
        try s.append(threadId: "t", turnIndex: 1, role: "user", text: "bbbb", now: 2)
        let rows = try s.recent(threadId: "t", maxTurns: 10, maxChars: 5)
        XCTAssertEqual(rows.map { $0.text }, ["bbbb"])
    }

    func test_range_returnsInclusiveTurnSlice() throws {
        let s = try makeStore()
        for i in 0..<4 { try s.append(threadId: "t", turnIndex: i, role: "user", text: "m\(i)", now: Double(i)) }
        let rows = try s.range(threadId: "t", fromTurn: 1, toTurn: 2)
        XCTAssertEqual(rows.map { $0.text }, ["m1", "m2"])
    }

    func test_unconsolidated_and_mark() throws {
        let s = try makeStore()
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "x", now: 1)
        try s.append(threadId: "t", turnIndex: 0, role: "assistant", text: "y", now: 2)
        let pending = try s.unconsolidated(limit: 100)
        XCTAssertEqual(pending.count, 2)
        try s.markConsolidated(ids: pending.map { $0.id })
        XCTAssertEqual(try s.unconsolidated(limit: 100).count, 0)
    }

    func test_recent_keeps_user_before_assistant_within_turn_even_on_equal_timestamps() throws {
        let s = try makeStore()
        // same turnIndex AND same createdAt for both rows of the turn
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "q", now: 5)
        try s.append(threadId: "t", turnIndex: 0, role: "assistant", text: "a", now: 5)
        let rows = try s.recent(threadId: "t", maxTurns: 10, maxChars: 10_000)
        XCTAssertEqual(rows.map { $0.role }, ["user", "assistant"], "user must precede assistant within a turn")
    }

    func test_rows_byIds_returnsMatching_orderedOldestFirst() throws {
        let s = try makeStore()
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "a", now: 1)
        try s.append(threadId: "t", turnIndex: 0, role: "assistant", text: "b", now: 2)
        let all = try s.unconsolidated(limit: 100)
        let ids = all.map { $0.id }
        let rows = try s.rows(ids: ids)
        XCTAssertEqual(rows.map { $0.text }, ["a", "b"], "rows(ids:) returns the rows oldest-first")
        XCTAssertEqual(try s.rows(ids: []).count, 0)
    }

    func test_allRecent_returnsNewestFirst_acrossThreads() throws {
        let s = try makeStore()
        try s.append(threadId: "a", turnIndex: 0, role: "user", text: "one", now: 1)
        try s.append(threadId: "b", turnIndex: 0, role: "user", text: "two", now: 2)
        let rows = try s.allRecent(limit: 10)
        XCTAssertEqual(rows.map { $0.text }, ["two", "one"], "newest first across all threads")
    }
}
