import Foundation

public enum BrainOutcomeStatus: String, Codable, Equatable, Sendable {
    case succeeded, failed, cancelled, unknown
}

public struct BrainOutcome: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let status: BrainOutcomeStatus
    public let recordedAt: Double
    public let evidenceIDs: [String]

    public init(
        id: String,
        description: String,
        status: BrainOutcomeStatus,
        recordedAt: Double,
        evidenceIDs: [String]
    ) {
        self.id = id
        self.description = description
        self.status = status
        self.recordedAt = recordedAt
        self.evidenceIDs = evidenceIDs
    }
}

public struct BrainProcedure: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let steps: [String]
    public let evidenceIDs: [String]
    public let outcomeIDs: [String]

    public init(
        id: String,
        description: String,
        steps: [String],
        evidenceIDs: [String],
        outcomeIDs: [String]
    ) {
        self.id = id
        self.description = description
        self.steps = steps
        self.evidenceIDs = evidenceIDs
        self.outcomeIDs = outcomeIDs
    }
}
