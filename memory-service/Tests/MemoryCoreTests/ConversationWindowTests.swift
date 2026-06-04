import XCTest
@testable import MemoryCore

final class ConversationWindowTests: XCTestCase {
    private func row(_ role: String, _ text: String, _ t: Double) -> TranscriptRow {
        TranscriptRow(id: "\(t)", threadId: "x", turnIndex: Int(t), seq: Int(t), role: role, text: text, createdAt: t, consolidated: false)
    }

    func test_maps_rows_to_chat_messages_in_order() {
        let rows = [row("user", "hola", 1), row("assistant", "buenas", 2)]
        let msgs = ConversationWindow.messages(from: rows)
        XCTAssertEqual(msgs, [ChatMessage(role: .user, content: "hola"),
                              ChatMessage(role: .assistant, content: "buenas")])
    }

    func test_unknown_role_is_treated_as_user() {
        let msgs = ConversationWindow.messages(from: [row("system", "x", 1)])
        XCTAssertEqual(msgs, [ChatMessage(role: .user, content: "x")])
    }

    func test_empty_rows_empty_messages() {
        XCTAssertTrue(ConversationWindow.messages(from: []).isEmpty)
    }
}
