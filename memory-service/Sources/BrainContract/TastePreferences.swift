import Foundation

public enum BrainTasteKind: String, Codable, Equatable, Sendable {
    case liking, disliking, comparativePreference
    case selection, variety

    public var isCurrentIntent: Bool { self == .selection || self == .variety }
}

public enum BrainTasteProvenance: String, Codable, Equatable, Sendable {
    case explicit, inferred
}

public enum BrainTasteDurability: String, Codable, Equatable, Sendable {
    case contextual, enduring
}

/// Strength describes expressed liking or disliking; absence does not invent intensity.
public enum BrainTasteIntensity: String, Codable, Equatable, Sendable {
    case mild, moderate, strong
}

/// Attribution preserves quotation and reports about another subject without assigning them to the user.
public enum BrainTasteAttribution: String, Codable, Equatable, Sendable {
    case direct, quoted, thirdParty
}

/// A selection defaults to contextual evidence. Repetition never promotes it automatically to an enduring taste.

public struct BrainTasteRecord: Codable, Equatable, Sendable {
    public let id: String
    public let subjectID: String
    public let kind: BrainTasteKind
    public let target: String
    public let alternatives: [String]?
    public let criterion: String?
    public let domain: String?
    public let context: String?
    public let provenance: BrainTasteProvenance
    public let durability: BrainTasteDurability
    public let recordedAt: Double
    public let evidenceIDs: [String]
    public let intensity: BrainTasteIntensity?
    public let modality: BrainClaimModality?
    public let attribution: BrainTasteAttribution?
    public let validFrom: Double?
    public let validTo: Double?

    public init(
        id: String,
        subjectID: String,
        kind: BrainTasteKind,
        target: String,
        alternatives: [String]? = nil,
        criterion: String? = nil,
        domain: String? = nil,
        context: String? = nil,
        provenance: BrainTasteProvenance,
        durability: BrainTasteDurability = .contextual,
        recordedAt: Double,
        evidenceIDs: [String],
        intensity: BrainTasteIntensity? = nil,
        modality: BrainClaimModality? = nil,
        attribution: BrainTasteAttribution? = nil,
        validFrom: Double? = nil,
        validTo: Double? = nil
    ) {
        self.id = id
        self.subjectID = subjectID
        self.kind = kind
        self.target = target
        self.alternatives = alternatives
        self.criterion = criterion
        self.domain = domain
        self.context = context
        self.provenance = provenance
        self.durability = durability
        self.recordedAt = recordedAt
        self.evidenceIDs = evidenceIDs
        self.intensity = intensity
        self.modality = modality
        self.attribution = attribution
        self.validFrom = validFrom
        self.validTo = validTo
    }

    private enum CodingKeys: String, CodingKey {
        case id, subjectID, kind, target, alternatives, criterion, domain, context, provenance, durability, recordedAt, evidenceIDs, intensity, modality, attribution
        case validFrom, validTo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            subjectID: try c.decode(String.self, forKey: .subjectID),
            kind: try c.decode(BrainTasteKind.self, forKey: .kind),
            target: try c.decode(String.self, forKey: .target),
            alternatives: try c.decodeIfPresent([String].self, forKey: .alternatives),
            criterion: try c.decodeIfPresent(String.self, forKey: .criterion),
            domain: try c.decodeIfPresent(String.self, forKey: .domain),
            context: try c.decodeIfPresent(String.self, forKey: .context),
            provenance: try c.decode(BrainTasteProvenance.self, forKey: .provenance),
            durability: try c.decodeIfPresent(BrainTasteDurability.self, forKey: .durability) ?? .contextual,
            recordedAt: try c.decode(Double.self, forKey: .recordedAt),
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs),
            intensity: try c.decodeIfPresent(BrainTasteIntensity.self, forKey: .intensity),
            modality: try c.decodeIfPresent(BrainClaimModality.self, forKey: .modality),
            attribution: try c.decodeIfPresent(BrainTasteAttribution.self, forKey: .attribution),
            validFrom: try c.decodeIfPresent(Double.self, forKey: .validFrom),
            validTo: try c.decodeIfPresent(Double.self, forKey: .validTo)
        )
    }

    /// A known non-assertion or quotation cannot establish an enduring taste.
    /// Third-party records retain their actual subjectID; they are never user tastes by label.
    public var isEnduringTaste: Bool {
        durability == .enduring && provenance == .explicit && !kind.isCurrentIntent
            && (modality == nil || modality == .asserted)
            && attribution != .quoted
            && !(subjectID == BrainIdentity.userID && attribution == .thirdParty)
    }
}

public struct BrainTasteContext: Codable, Equatable, Sendable {
    public let threadID: String?
    public let situation: String?

    public init(threadID: String? = nil, situation: String? = nil) {
        self.threadID = threadID
        self.situation = situation
    }
}

public enum BrainTasteInformationGap: String, Codable, Equatable, Sendable {
    case taste, comparativePreference
}

public struct BrainTasteProfile: Codable, Equatable, Sendable {
    public let subjectID: String
    public let revision: Int64
    public let records: [BrainTasteRecord]
    public let currentIntent: [BrainTasteRecord]?
    public let missingInformation: [BrainTasteInformationGap]?

    public init(
        subjectID: String,
        revision: Int64,
        records: [BrainTasteRecord],
        currentIntent: [BrainTasteRecord]? = nil,
        missingInformation: [BrainTasteInformationGap]? = nil
    ) {
        self.subjectID = subjectID
        self.revision = revision
        self.records = records
        self.currentIntent = currentIntent
        self.missingInformation = missingInformation
    }
}
