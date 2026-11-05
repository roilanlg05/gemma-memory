import Foundation

public enum BrainIdentityKind: String, Codable, Equatable, Sendable {
    case user, agent, relationship
}

public struct BrainIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let kind: BrainIdentityKind
    public let displayName: String
    public let claimIDs: [String]

    public init(
        id: String,
        kind: BrainIdentityKind,
        displayName: String,
        claimIDs: [String]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.claimIDs = claimIDs
    }

    public static let userID = "self:user"
    public static let agentID = "self:agent"
    public static let relationshipID = "relationship:user:agent"
}
