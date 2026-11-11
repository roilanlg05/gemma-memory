import Foundation

public enum BrainOutcomeStatus: String, Codable, Equatable, Sendable {
    case succeeded, partial, failed, cancelled, unknown
}

/// Closed metadata only; raw tool bodies, headers and free-form parameters are excluded.
public struct BrainToolObservation: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable, Hashable { case httpCheck, resourceCheck }
    public let operation: Operation
    public let httpStatus: Int?
    public init(operation: Operation, httpStatus: Int? = nil) {
        self.operation = operation
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    }
    private enum CodingKeys: String, CodingKey { case operation, httpStatus }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(operation: try c.decode(Operation.self, forKey: .operation), httpStatus: try c.decodeIfPresent(Int.self, forKey: .httpStatus))
    }
}

public struct BrainOutcome: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let status: BrainOutcomeStatus
    public let recordedAt: Double
    public let evidenceIDs: [String]
    public let observation: BrainToolObservation?

    public init(
        id: String,
        description: String,
        status: BrainOutcomeStatus,
        recordedAt: Double,
        evidenceIDs: [String], observation: BrainToolObservation? = nil
    ) {
        self.id = id
        self.description = description
        self.status = status
        self.recordedAt = recordedAt
        self.evidenceIDs = evidenceIDs
        self.observation = observation
    }
}

public struct BrainProcedure: Codable, Equatable, Sendable {
    public let id: String
    public let description: String
    public let steps: [String]
    public let evidenceIDs: [String]
    public let outcomeIDs: [String]
    public let version: Int
    public let preconditions: [String]
    public let failureModes: [String]

    public init(
        id: String,
        description: String,
        steps: [String],
        evidenceIDs: [String],
        outcomeIDs: [String],
        version: Int = 1, preconditions: [String] = [], failureModes: [String] = []
    ) {
        self.id = id
        self.description = description
        self.steps = steps
        self.evidenceIDs = evidenceIDs
        self.outcomeIDs = outcomeIDs
        self.version = version; self.preconditions = preconditions; self.failureModes = failureModes
    }
    private enum CodingKeys: String, CodingKey { case id, description, steps, evidenceIDs, outcomeIDs, version, preconditions, failureModes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), description: try c.decode(String.self, forKey: .description),
                  steps: try c.decode([String].self, forKey: .steps), evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs),
                  outcomeIDs: try c.decode([String].self, forKey: .outcomeIDs), version: try c.decodeIfPresent(Int.self, forKey: .version) ?? 1,
                  preconditions: try c.decodeIfPresent([String].self, forKey: .preconditions) ?? [], failureModes: try c.decodeIfPresent([String].self, forKey: .failureModes) ?? [])
    }

}
