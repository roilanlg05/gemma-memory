import Foundation

/// Same shape as the app's ChatMessage but lives inside MemoryCore so the package
/// doesn't depend on the app target. The HTTP layer (handlers in MemoryService)
/// decodes the client's wire format into this type before passing to retriever
/// and consolidation prompts.
public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }
    public var role: Role
    public var content: String
    public var name: String?

    public init(role: Role, content: String, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }
}
