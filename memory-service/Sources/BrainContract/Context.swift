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
    public let accounting: BrainContextAccounting?
    public let truncations: [BrainContextTruncation]?

    public init(
        renderedContext: String,
        recentMessageUnits: [BrainMessageUnit],
        sourceReferences: [BrainEvidence],
        revision: Int64,
        policyRevision: Int64,
        accounting: BrainContextAccounting? = nil,
        truncations: [BrainContextTruncation]? = nil
    ) {
        self.renderedContext = renderedContext
        self.recentMessageUnits = recentMessageUnits
        self.sourceReferences = sourceReferences
        self.revision = revision
        self.policyRevision = policyRevision
        self.accounting = accounting
        self.truncations = truncations
    }
}

/// Conservative input estimate includes the serialized bundle, query and framing. Provider
/// integrations must reserve their actual system/tool capacity and output separately.
public struct BrainContextAccounting: Codable, Equatable, Sendable {
    public let estimatedInputTokens: Int
    public let reservedOutputTokens: Int
    public let reservedSystemTokens: Int
    public let reservedToolTokens: Int
    public let totalWindowTokens: Int
    public init(estimatedInputTokens: Int, reservedOutputTokens: Int, reservedSystemTokens: Int,
                reservedToolTokens: Int, totalWindowTokens: Int) {
        self.estimatedInputTokens = estimatedInputTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.reservedSystemTokens = reservedSystemTokens
        self.reservedToolTokens = reservedToolTokens
        self.totalWindowTokens = totalWindowTokens
    }
}

/// Byte counts refer to an original source. A partial recent unit is never a full exact quote.
///
/// `evidenceID` is absent when the entry does not describe one original: a rendered section that
/// did not fit, or an aggregate notice standing for several omissions at a budget too small to
/// carry one entry each. The byte counts then describe that section or that aggregate.
///
/// A present `evidenceID` always resolves in `BrainContextBundle.sourceReferences`. The assembler
/// reserves an original's metadata entry together with the notice that may name it, so an
/// advertised id is followable and is a valid forget target whether or not the original itself was
/// delivered. A subject, a predicate or any other kind of identifier is never put here, because an
/// id that does not resolve is worse than no id at all.
///
/// Resolving is therefore not evidence of delivery, and the two are told apart from this type, not
/// from `sourceReferences`: `includedUTF8Bytes == 0` means the original was wholly omitted, a value
/// between zero and `originalUTF8Bytes` means a marked prefix of it was rendered, and an original
/// with no entry at all was delivered whole. A `sourceReferences` entry is metadata about an
/// original this bundle accounted for; it never carries text, for a delivered original or an
/// omitted one.
public struct BrainContextTruncation: Codable, Equatable, Sendable {
    public let evidenceID: String?
    public let originalUTF8Bytes: Int
    public let includedUTF8Bytes: Int
    public let reason: String
    public init(evidenceID: String?, originalUTF8Bytes: Int, includedUTF8Bytes: Int, reason: String) {
        self.evidenceID = evidenceID
        self.originalUTF8Bytes = originalUTF8Bytes
        self.includedUTF8Bytes = includedUTF8Bytes
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case evidenceID, originalUTF8Bytes, includedUTF8Bytes, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            evidenceID: try c.decodeIfPresent(String.self, forKey: .evidenceID),
            originalUTF8Bytes: try c.decode(Int.self, forKey: .originalUTF8Bytes),
            includedUTF8Bytes: try c.decode(Int.self, forKey: .includedUTF8Bytes),
            reason: try c.decode(String.self, forKey: .reason)
        )
    }
}
