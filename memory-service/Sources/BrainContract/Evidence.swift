import Foundation

/// Validation failures are transport-neutral and contain no source text.
public enum BrainContractError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidClientOperationID
    case invalidBudget(contextTokens: Int, outputTokens: Int)
}

internal enum BrainValidation {
    static func schema(_ version: Int) throws {
        guard version == 1 else { throw BrainContractError.unsupportedSchemaVersion(version) }
    }
    static func request(_ schemaVersion: Int, _ clientOperationID: String) throws {
        try schema(schemaVersion)
        guard !clientOperationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrainContractError.invalidClientOperationID
        }
    }
    static func budget(_ contextTokens: Int, _ outputTokens: Int) throws {
        guard contextTokens >= 0, outputTokens >= 0, outputTokens <= contextTokens else {
            throw BrainContractError.invalidBudget(contextTokens: contextTokens, outputTokens: outputTokens)
        }
    }
}

public enum BrainSourceKind: String, Codable, Equatable, Sendable {
    case userMessage, assistantMessage, toolObservation, imported, system, derived
}

public enum BrainAccessScope: String, Codable, Equatable, Sendable {
    case thread, user, agent, shared
}

/// Half-open UTF-8 offsets into the original source; never a replacement for source evidence.

public struct BrainEvidenceSpan: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(
        start: Int,
        end: Int
    ) {
        self.start = start
        self.end = end
    }
}

/// Times are Unix epoch seconds. Speaker identity remains distinct from the source kind.

public struct BrainEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let sourceKind: BrainSourceKind
    public let speakerID: String
    public let threadID: String
    public let observedAt: Double
    public let recordedAt: Double
    public let span: BrainEvidenceSpan?
    public let accessScope: BrainAccessScope
    /// Sanitized immutable source content, when the original is not held in an external source store.
    public let text: String?
    /// Original evidence roots of a derived observation; presence is not proof that roots are valid.
    public let parentEvidenceIDs: [String]?

    public init(
        id: String,
        sourceKind: BrainSourceKind,
        speakerID: String,
        threadID: String,
        observedAt: Double,
        recordedAt: Double,
        span: BrainEvidenceSpan? = nil,
        accessScope: BrainAccessScope,
        text: String? = nil,
        parentEvidenceIDs: [String]? = nil
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.speakerID = speakerID
        self.threadID = threadID
        self.observedAt = observedAt
        self.recordedAt = recordedAt
        self.span = span
        self.accessScope = accessScope
        self.text = text
        self.parentEvidenceIDs = parentEvidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceKind, speakerID, threadID, observedAt, recordedAt, span, accessScope, text, parentEvidenceIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            sourceKind: try c.decode(BrainSourceKind.self, forKey: .sourceKind),
            speakerID: try c.decode(String.self, forKey: .speakerID),
            threadID: try c.decode(String.self, forKey: .threadID),
            observedAt: try c.decode(Double.self, forKey: .observedAt),
            recordedAt: try c.decode(Double.self, forKey: .recordedAt),
            span: try c.decodeIfPresent(BrainEvidenceSpan.self, forKey: .span),
            accessScope: try c.decode(BrainAccessScope.self, forKey: .accessScope),
            text: try c.decodeIfPresent(String.self, forKey: .text),
            parentEvidenceIDs: try c.decodeIfPresent([String].self, forKey: .parentEvidenceIDs)
        )
    }
}
