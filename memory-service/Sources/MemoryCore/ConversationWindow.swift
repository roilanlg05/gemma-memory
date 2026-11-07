import Foundation
import BrainContract

/// Pure mapping from persisted transcript rows to the chat history (`[ChatMessage]`) the model
/// receives as short-term context. Rows are assumed oldest-first (as `TranscriptStore.recent`
/// returns them). Caps are applied by the store; this is just the role/text mapping.
public enum ConversationWindow {
    /// Default short-term window bounds (see spec §2): ~12 turns or ~1500 chars, newest kept.
    public static let defaultMaxTurns = 12
    public static let defaultMaxChars = 1500

    public static func messages(from rows: [TranscriptRow]) -> [ChatMessage] {
        rows.map { row in
            let role: ChatMessage.Role = (row.role == "assistant") ? .assistant : .user
            return ChatMessage(role: role, content: row.text)
        }
    }
}


extension ConversationWindow {
    static func groupID(for row: TranscriptRow) -> String {
        "transcript-group:" + ConsolidationDigest.hex(row.threadId + "\u{1}" + String(row.turnIndex))
    }
    /// Strict adaptive rendering. The legacy rows overload and endpoint retain their contract.
    /// Source kinds, rather than an unknown role default, determine attribution here.
    public static func messages(from bundle: BrainContextBundle) -> [ChatMessage] {
        let sources = Dictionary(bundle.sourceReferences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return bundle.recentMessageUnits.compactMap { unit in
            guard let id = unit.evidenceIDs.first, let source = sources[id],
                  source.speakerID == unit.speakerID else { return nil }
            let role: ChatMessage.Role
            switch source.sourceKind {
            case .userMessage: role = .user
            case .assistantMessage: role = .assistant
            case .toolObservation: role = .tool
            default: return nil
            }
            return ChatMessage(role: role, content: unit.text)
        }
    }
}
