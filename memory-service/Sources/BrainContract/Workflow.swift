import Foundation

public struct BrainUpdateProposalRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let turnID: String

    public init(turnID: String, schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.turnID = turnID
    }
}

public struct BrainUpdateProposalResult: Codable, Sendable {
    public let turnID: String
    public let revision: Int64
    public let updates: [BrainClaimUpdate]

    public init(turnID: String, revision: Int64, updates: [BrainClaimUpdate]) {
        self.turnID = turnID
        self.revision = revision
        self.updates = updates
    }
}

public struct BrainStagedCommitRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let turnID: String
    public let expectedRevision: Int64
    public let updates: [BrainClaimUpdate]

    public init(turnID: String, expectedRevision: Int64, updates: [BrainClaimUpdate], schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.turnID = turnID
        self.expectedRevision = expectedRevision
        self.updates = updates
    }
}

public struct BrainReportedOutcomeRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let turnID: String
    public let outcome: BrainOutcome

    public init(turnID: String, outcome: BrainOutcome, schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.turnID = turnID
        self.outcome = outcome
    }
}

public struct BrainIdentityRevisionRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let clientOperationID: String
    public let expectedRevision: Int64
    public let change: BrainIdentityChange
    public let threadID: String

    public init(clientOperationID: String, expectedRevision: Int64, change: BrainIdentityChange,
                threadID: String, schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.clientOperationID = clientOperationID
        self.expectedRevision = expectedRevision
        self.change = change
        self.threadID = threadID
    }
}

public struct BrainForgetRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let clientOperationID: String
    public let expectedRevision: Int64
    public let scope: BrainForgetScope
    public let threadID: String?

    public init(clientOperationID: String, expectedRevision: Int64, scope: BrainForgetScope,
                threadID: String? = nil, schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.clientOperationID = clientOperationID
        self.expectedRevision = expectedRevision
        self.scope = scope
        self.threadID = threadID
    }
}

public enum BrainConsolidationKind: String, Codable, Sendable { case reflection, full }

public struct BrainConsolidationRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let kind: BrainConsolidationKind
    public let timezone: String?

    public init(kind: BrainConsolidationKind, timezone: String? = nil, schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.timezone = timezone
    }
}

public struct BrainConsolidationJob: Codable, Sendable {
    public enum State: String, Codable, Sendable { case running, finished, cancelled }
    public let jobID: String
    public let kind: BrainConsolidationKind
    public let state: State

    public init(jobID: String, kind: BrainConsolidationKind, state: State) {
        self.jobID = jobID
        self.kind = kind
        self.state = state
    }
}

public struct BrainProspectiveResult: Codable, Sendable {
    public let revision: Int64
    public let candidates: [BrainProspectiveCandidate]

    public init(revision: Int64, candidates: [BrainProspectiveCandidate]) {
        self.revision = revision
        self.candidates = candidates
    }
}

public struct BrainProspectiveDeferRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let candidateID: String
    public let expectedRevision: Int64
    public let until: Double

    public init(candidateID: String, expectedRevision: Int64, until: Double, schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.candidateID = candidateID
        self.expectedRevision = expectedRevision
        self.until = until
    }
}

public struct BrainProspectiveResolutionRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let candidateID: String
    public let turnID: String
    public let evidenceID: String
    public let expectedRevision: Int64

    public init(candidateID: String, turnID: String, evidenceID: String, expectedRevision: Int64, schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.candidateID = candidateID
        self.turnID = turnID
        self.evidenceID = evidenceID
        self.expectedRevision = expectedRevision
    }
}

public struct BrainProspectiveReceiptRequest: Codable, Sendable {
    public let schemaVersion: Int?
    public let candidateID: String
    public let deliveryID: String

    public init(candidateID: String, deliveryID: String, schemaVersion: Int? = 1) {
        self.schemaVersion = schemaVersion
        self.candidateID = candidateID
        self.deliveryID = deliveryID
    }
}
