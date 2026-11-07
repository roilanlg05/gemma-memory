import Foundation

public struct BrainContextRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let clientOperationID: String
    public let threadID: String
    public let query: String
    public let budget: BrainContextBudget
    /// Explicit original selection within this thread. Quotes take precedence over details for
    /// the same id. Leaving both fields absent lets an installed selector make the selection.
    public let quoteEvidenceIDs: [String]?
    public let detailEvidenceIDs: [String]?

    public init(
        schemaVersion: Int = 1,
        clientOperationID: String,
        threadID: String,
        query: String,
        budget: BrainContextBudget,
        quoteEvidenceIDs: [String]? = nil,
        detailEvidenceIDs: [String]? = nil
    ) throws {
        try BrainValidation.request(schemaVersion, clientOperationID)
        self.schemaVersion = schemaVersion
        self.clientOperationID = clientOperationID
        self.threadID = threadID
        self.query = query
        self.budget = budget
        self.quoteEvidenceIDs = quoteEvidenceIDs
        self.detailEvidenceIDs = detailEvidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, clientOperationID, threadID, query, budget, quoteEvidenceIDs, detailEvidenceIDs
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
            budget: try c.decode(BrainContextBudget.self, forKey: .budget),
            quoteEvidenceIDs: try c.decodeIfPresent([String].self, forKey: .quoteEvidenceIDs),
            detailEvidenceIDs: try c.decodeIfPresent([String].self, forKey: .detailEvidenceIDs)
        )
    }
}

/// How an evidence source contributed to the delivered bundle. One source may have several uses.
public enum BrainContextSourceUse: String, Codable, Equatable, Sendable {
    case renderedQuote
    case renderedDetail
    case recentWhole
    case recentPrefix
    case derivedSupport
}

/// Context belongs to this turn and records the revisions it was built at.
/// sourceReferences supplies metadata for used sources and individually named omissions.
/// sourceUses records actual delivery independently of channel-specific omission notices.
public struct BrainContextBundle: Codable, Equatable, Sendable {
    public let renderedContext: String
    public let recentMessageUnits: [BrainMessageUnit]
    public let sourceReferences: [BrainEvidence]
    public let revision: Int64
    public let policyRevision: Int64
    public let accounting: BrainContextAccounting?
    public let truncations: [BrainContextTruncation]?
    /// Sparse use records keyed by evidence id. An absent record makes no claim of delivery.
    public let sourceUses: [String: [BrainContextSourceUse]]?

    /// Sources whose complete original text was forwarded. Set includingRenderedContext only
    /// when renderedContext was sent in full, and pass the IDs of recent units sent unchanged.
    /// Legacy bundles without explicit use records yield no exact citation sources.
    public func exactCitationSourceReferences(includingRenderedContext: Bool,
                                              forwardedRecentUnitIDs: Set<String>) -> [BrainEvidence] {
        sourceReferences.filter { source in
            guard let uses = sourceUses?[source.id] else { return false }
            let rendered = includingRenderedContext && (uses.contains(.renderedQuote) || uses.contains(.renderedDetail))
            let recent = forwardedRecentUnitIDs.contains(source.id) && uses.contains(.recentWhole)
            return rendered || recent
        }
    }

    public init(
        renderedContext: String,
        recentMessageUnits: [BrainMessageUnit],
        sourceReferences: [BrainEvidence],
        revision: Int64,
        policyRevision: Int64,
        accounting: BrainContextAccounting? = nil,
        truncations: [BrainContextTruncation]? = nil,
        sourceUses: [String: [BrainContextSourceUse]]? = nil
    ) {
        self.renderedContext = renderedContext
        self.recentMessageUnits = recentMessageUnits
        self.sourceReferences = sourceReferences
        self.revision = revision
        self.policyRevision = policyRevision
        self.accounting = accounting
        self.truncations = truncations
        self.sourceUses = sourceUses
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

/// Reports the effect of a budget limit in the section identified by reason.
/// For example, a quote omitted from the rendered section can still have a whole original or
/// prefix in the recent section. Consult BrainContextBundle.sourceUses for delivery.
///
/// A named evidenceID resolves in BrainContextBundle.sourceReferences in an assembled bundle.
/// An id-less notice describes a section or an aggregate. For selected quote and detail aggregates,
/// the original byte count is the sum for the omitted originals and omittedEvidenceCount is the
/// number of originals it covers.
public struct BrainContextTruncation: Codable, Equatable, Sendable {
    public let evidenceID: String?
    public let originalUTF8Bytes: Int
    public let includedUTF8Bytes: Int
    public let reason: String
    public let omittedEvidenceCount: Int?
    public init(evidenceID: String?, originalUTF8Bytes: Int, includedUTF8Bytes: Int, reason: String,
                omittedEvidenceCount: Int? = nil) {
        self.evidenceID = evidenceID
        self.originalUTF8Bytes = originalUTF8Bytes
        self.includedUTF8Bytes = includedUTF8Bytes
        self.reason = reason
        self.omittedEvidenceCount = omittedEvidenceCount
    }

    private enum CodingKeys: String, CodingKey {
        case evidenceID, originalUTF8Bytes, includedUTF8Bytes, reason, omittedEvidenceCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            evidenceID: try c.decodeIfPresent(String.self, forKey: .evidenceID),
            originalUTF8Bytes: try c.decode(Int.self, forKey: .originalUTF8Bytes),
            includedUTF8Bytes: try c.decode(Int.self, forKey: .includedUTF8Bytes),
            reason: try c.decode(String.self, forKey: .reason),
            omittedEvidenceCount: try c.decodeIfPresent(Int.self, forKey: .omittedEvidenceCount)
        )
    }
}
