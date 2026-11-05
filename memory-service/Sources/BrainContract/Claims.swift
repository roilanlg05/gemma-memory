import Foundation

/// A JSON value retains structured claim content without a provider or database type.
public indirect enum BrainValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([BrainValue])
    case object([String: BrainValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([BrainValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: BrainValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
}

public enum BrainClaimModality: String, Codable, Equatable, Sendable {
    case asserted, negated, proposed, hypothetical, inferred
}

public enum BrainClaimStatus: String, Codable, Equatable, Sendable {
    case active, superseded, retracted, forgotten
}

public enum BrainPersistenceState: String, Codable, Equatable, Sendable {
    case committed, pending
}

/// Disposition separates transaction durability from replay or optimistic-concurrency conflict.

public enum BrainCommitDisposition: String, Codable, Equatable, Sendable {
    case committed, idempotent, conflict
}

public struct BrainClaim: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int64
    public let subject: String
    public let predicate: String
    public let value: BrainValue
    public let modality: BrainClaimModality
    public let status: BrainClaimStatus
    public let validFrom: Double
    public let validTo: Double?
    public let recordedAt: Double
    public let evidenceIDs: [String]
    public let supersedesID: String?

    public init(
        id: String,
        revision: Int64,
        subject: String,
        predicate: String,
        value: BrainValue,
        modality: BrainClaimModality,
        status: BrainClaimStatus,
        validFrom: Double,
        validTo: Double? = nil,
        recordedAt: Double,
        evidenceIDs: [String],
        supersedesID: String? = nil
    ) {
        self.id = id
        self.revision = revision
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.modality = modality
        self.status = status
        self.validFrom = validFrom
        self.validTo = validTo
        self.recordedAt = recordedAt
        self.evidenceIDs = evidenceIDs
        self.supersedesID = supersedesID
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision, subject, predicate, value, modality, status, validFrom, validTo, recordedAt, evidenceIDs, supersedesID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            revision: try c.decode(Int64.self, forKey: .revision),
            subject: try c.decode(String.self, forKey: .subject),
            predicate: try c.decode(String.self, forKey: .predicate),
            value: try c.decode(BrainValue.self, forKey: .value),
            modality: try c.decode(BrainClaimModality.self, forKey: .modality),
            status: try c.decode(BrainClaimStatus.self, forKey: .status),
            validFrom: try c.decode(Double.self, forKey: .validFrom),
            validTo: try c.decodeIfPresent(Double.self, forKey: .validTo),
            recordedAt: try c.decode(Double.self, forKey: .recordedAt),
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs),
            supersedesID: try c.decodeIfPresent(String.self, forKey: .supersedesID)
        )
    }
}

public struct BrainClaimUpdate: Codable, Equatable, Sendable {
    public let claim: BrainClaim
    public let expectedRevision: Int64?

    public init(
        claim: BrainClaim,
        expectedRevision: Int64? = nil
    ) {
        self.claim = claim
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case claim, expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            claim: try c.decode(BrainClaim.self, forKey: .claim),
            expectedRevision: try c.decodeIfPresent(Int64.self, forKey: .expectedRevision)
        )
    }
}

public struct BrainCommitRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let clientOperationID: String
    public let evidence: [BrainEvidence]
    public let updates: [BrainClaimUpdate]
    public let expectedRevision: Int64?
    public let tastes: [BrainTasteRecord]?

    public init(
        schemaVersion: Int = 1,
        clientOperationID: String,
        evidence: [BrainEvidence],
        updates: [BrainClaimUpdate],
        expectedRevision: Int64? = nil,
        tastes: [BrainTasteRecord]? = nil
    ) throws {
        try BrainValidation.request(schemaVersion, clientOperationID)
        self.schemaVersion = schemaVersion
        self.clientOperationID = clientOperationID
        self.evidence = evidence
        self.updates = updates
        self.expectedRevision = expectedRevision
        self.tastes = tastes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, clientOperationID, evidence, updates, expectedRevision, tastes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        try BrainValidation.schema(version)
        try self.init(
            schemaVersion: version,
            clientOperationID: try c.decode(String.self, forKey: .clientOperationID),
            evidence: try c.decode([BrainEvidence].self, forKey: .evidence),
            updates: try c.decode([BrainClaimUpdate].self, forKey: .updates),
            expectedRevision: try c.decodeIfPresent(Int64.self, forKey: .expectedRevision),
            tastes: try c.decodeIfPresent([BrainTasteRecord].self, forKey: .tastes)
        )
    }
}

public struct BrainCommitResult: Codable, Equatable, Sendable {
    public let clientOperationID: String
    public let state: BrainPersistenceState
    public let revision: Int64
    public let claimIDs: [String]
    public let disposition: BrainCommitDisposition?

    public init(
        clientOperationID: String,
        state: BrainPersistenceState,
        revision: Int64,
        claimIDs: [String],
        disposition: BrainCommitDisposition? = nil
    ) {
        self.clientOperationID = clientOperationID
        self.state = state
        self.revision = revision
        self.claimIDs = claimIDs
        self.disposition = disposition
    }

    private enum CodingKeys: String, CodingKey {
        case clientOperationID, state, revision, claimIDs, disposition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clientOperationID: try c.decode(String.self, forKey: .clientOperationID),
            state: try c.decode(BrainPersistenceState.self, forKey: .state),
            revision: try c.decode(Int64.self, forKey: .revision),
            claimIDs: try c.decode([String].self, forKey: .claimIDs),
            disposition: try c.decodeIfPresent(BrainCommitDisposition.self, forKey: .disposition)
        )
    }
}

public enum BrainForgetScopeKind: String, Codable, Equatable, Sendable {
    case all, thread, subject, evidence, claim
}

public struct BrainForgetScope: Codable, Equatable, Sendable {
    public let kind: BrainForgetScopeKind
    public let id: String?

    public init(
        kind: BrainForgetScopeKind,
        id: String? = nil
    ) {
        self.kind = kind
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decode(BrainForgetScopeKind.self, forKey: .kind),
            id: try c.decodeIfPresent(String.self, forKey: .id)
        )
    }
}

/// Affected IDs include derived artifacts; source IDs permit exclusions across storage views.

public struct BrainForgetReceipt: Codable, Equatable, Sendable {
    public let clientOperationID: String
    public let scope: BrainForgetScope
    public let state: BrainPersistenceState
    public let revision: Int64
    public let forgottenEvidenceIDs: [String]
    public let forgottenClaimIDs: [String]
    public let affectedIDs: [String]?
    public let sourceEvidenceIDs: [String]?

    public init(
        clientOperationID: String,
        scope: BrainForgetScope,
        state: BrainPersistenceState,
        revision: Int64,
        forgottenEvidenceIDs: [String],
        forgottenClaimIDs: [String],
        affectedIDs: [String]? = nil,
        sourceEvidenceIDs: [String]? = nil
    ) {
        self.clientOperationID = clientOperationID
        self.scope = scope
        self.state = state
        self.revision = revision
        self.forgottenEvidenceIDs = forgottenEvidenceIDs
        self.forgottenClaimIDs = forgottenClaimIDs
        self.affectedIDs = affectedIDs
        self.sourceEvidenceIDs = sourceEvidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case clientOperationID, scope, state, revision, forgottenEvidenceIDs, forgottenClaimIDs, affectedIDs, sourceEvidenceIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clientOperationID: try c.decode(String.self, forKey: .clientOperationID),
            scope: try c.decode(BrainForgetScope.self, forKey: .scope),
            state: try c.decode(BrainPersistenceState.self, forKey: .state),
            revision: try c.decode(Int64.self, forKey: .revision),
            forgottenEvidenceIDs: try c.decode([String].self, forKey: .forgottenEvidenceIDs),
            forgottenClaimIDs: try c.decode([String].self, forKey: .forgottenClaimIDs),
            affectedIDs: try c.decodeIfPresent([String].self, forKey: .affectedIDs),
            sourceEvidenceIDs: try c.decodeIfPresent([String].self, forKey: .sourceEvidenceIDs)
        )
    }
}
