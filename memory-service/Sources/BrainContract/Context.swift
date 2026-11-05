import Foundation

public struct BrainContextRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let clientOperationID: String
    public let threadID: String
    public let query: String
    public let budget: BrainContextBudget

    public init(
        schemaVersion: Int = 1,
        clientOperationID: String,
        threadID: String,
        query: String,
        budget: BrainContextBudget
    ) throws {
        try BrainValidation.request(schemaVersion, clientOperationID)
        self.schemaVersion = schemaVersion
        self.clientOperationID = clientOperationID
        self.threadID = threadID
        self.query = query
        self.budget = budget
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, clientOperationID, threadID, query, budget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        try BrainValidation.schema(version)
        try self.init(
            schemaVersion: version,
            clientOperationID: try c.decode(String.self, forKey: .clientOperationID),
            threadID: try c.decode(String.self, forKey: .threadID),
            query: try c.decode(String.self, forKey: .query),
            budget: try c.decode(BrainContextBudget.self, forKey: .budget)
        )
    }
}

/// Rendered context belongs to this turn and records the revisions and original sources used to build it.

public struct BrainContextBundle: Codable, Equatable, Sendable {
    public let renderedContext: String
    public let recentMessageUnits: [BrainMessageUnit]
    public let sourceReferences: [BrainEvidence]
    public let revision: Int64
    public let policyRevision: Int64

    public init(
        renderedContext: String,
        recentMessageUnits: [BrainMessageUnit],
        sourceReferences: [BrainEvidence],
        revision: Int64,
        policyRevision: Int64
    ) {
        self.renderedContext = renderedContext
        self.recentMessageUnits = recentMessageUnits
        self.sourceReferences = sourceReferences
        self.revision = revision
        self.policyRevision = policyRevision
    }
}
