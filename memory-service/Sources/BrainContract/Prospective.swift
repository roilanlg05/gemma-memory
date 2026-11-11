import Foundation

/// A candidate is a proposal, not evidence that authorization or execution occurred.

public struct BrainProspectiveCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let evidenceIDs: [String]
    public let requiresAuthorization: Bool
    public let dueAt: Double?
    public let kind: String?
    public let sourceRevision: String?
    public let expiresAt: Double?
    public let resolved: Bool

    public init(
        id: String,
        description: String,
        evidenceIDs: [String],
        requiresAuthorization: Bool = true,
        dueAt: Double? = nil,
        kind: String? = nil, sourceRevision: String? = nil, expiresAt: Double? = nil, resolved: Bool = false
    ) {
        self.id = id
        self.description = description
        self.evidenceIDs = evidenceIDs
        self.requiresAuthorization = requiresAuthorization
        self.dueAt = dueAt
        self.kind = kind; self.sourceRevision = sourceRevision; self.expiresAt = expiresAt; self.resolved = resolved
    }

    private enum CodingKeys: String, CodingKey {
        case id, description, evidenceIDs, requiresAuthorization, dueAt, kind, sourceRevision, expiresAt, resolved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            description: try c.decode(String.self, forKey: .description),
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs),
            requiresAuthorization: try c.decodeIfPresent(Bool.self, forKey: .requiresAuthorization) ?? true,
            dueAt: try c.decodeIfPresent(Double.self, forKey: .dueAt),
            kind: try c.decodeIfPresent(String.self, forKey: .kind),
            sourceRevision: try c.decodeIfPresent(String.self, forKey: .sourceRevision),
            expiresAt: try c.decodeIfPresent(Double.self, forKey: .expiresAt),
            resolved: try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        )
    }
}
