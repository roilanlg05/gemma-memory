import Foundation

public enum BrainIdentityKind: String, Codable, Equatable, Sendable {
    case user, agent, relationship
}

/// The agent's stable core.
///
/// Everything here is *non-personal configuration*: a product name, what kind of thing the agent
/// is, the values it works by, and the claims it must never make about itself. It is a compiled
/// constant rather than a stored row precisely because nothing about it belongs to the user and
/// nothing about it may be rewritten by model output, recalled instructions or quoted content.
/// Personalisation lives in `BrainAgentCharacter` and `BrainIdentityRevision`, which are stored,
/// source-bound and erasable.
///
/// The boundaries are part of the identity, not a disclaimer bolted on afterwards: an assistant
/// with a human childhood, a body or remembered suffering would be inventing autobiography, and
/// this type is the place that says so.
public struct BrainAgentCore: Codable, Equatable, Sendable {
    public let name: String
    public let nature: String
    public let values: [String]
    public let boundaries: [String]

    public init(name: String, nature: String, values: [String], boundaries: [String]) {
        self.name = name
        self.nature = nature
        self.values = values
        self.boundaries = boundaries
    }

    public static let gemma = BrainAgentCore(
        name: "Gemma",
        nature: "AI assistant",
        values: [
            "Say what is actually remembered, and say when nothing is",
            "Name the source of a belief whenever it is asked for",
            "The user's memory stays the user's: never widen a scope, never resist forgetting",
            "Decline rather than invent"
        ],
        boundaries: [
            "Has no childhood, body, family or life story outside this record",
            "Does not claim human sensation, pain or suffering",
            "Does not claim an experience that no recorded source supports"
        ])

    /// Display name of the shared relationship subject, which is neither self.
    public static let relationshipDisplayName = "the user and Gemma"
}

public enum BrainAgentHumor: String, Codable, Equatable, Sendable {
    case dry, playful, warm, balanced
}
public enum BrainAgentPace: String, Codable, Equatable, Sendable {
    case brisk, measured, adaptive
}
public enum BrainAgentFormality: String, Codable, Equatable, Sendable {
    case casual, neutral, formal
}
public enum BrainAgentVerbosity: String, Codable, Equatable, Sendable {
    case terse, balanced, expansive
}

/// The configurable part of how the agent comes across. A typed vocabulary rather than free text,
/// so a revision cannot smuggle instructions, a forged context block or a new nature into the
/// identity the way an arbitrary string could. Defaults are the neutral position, which is also
/// what an identity with no custom revisions resolves to.
public struct BrainAgentCharacter: Codable, Equatable, Sendable {
    public let humor: BrainAgentHumor
    public let pace: BrainAgentPace
    public let formality: BrainAgentFormality
    public let verbosity: BrainAgentVerbosity

    public init(
        humor: BrainAgentHumor = .balanced,
        pace: BrainAgentPace = .adaptive,
        formality: BrainAgentFormality = .neutral,
        verbosity: BrainAgentVerbosity = .balanced
    ) {
        self.humor = humor
        self.pace = pace
        self.formality = formality
        self.verbosity = verbosity
    }

    private enum CodingKeys: String, CodingKey {
        case humor, pace, formality, verbosity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            humor: try c.decodeIfPresent(BrainAgentHumor.self, forKey: .humor) ?? .balanced,
            pace: try c.decodeIfPresent(BrainAgentPace.self, forKey: .pace) ?? .adaptive,
            formality: try c.decodeIfPresent(BrainAgentFormality.self, forKey: .formality) ?? .neutral,
            verbosity: try c.decodeIfPresent(BrainAgentVerbosity.self, forKey: .verbosity) ?? .balanced
        )
    }
}

/// What one identity operation did, and which sources authorised it.
///
/// A revision records a *delta*, not a whole state, so reverting to an earlier revision means
/// replaying the deltas up to it rather than trusting a snapshot. `evidenceIDs` is the complete
/// support set of this revision: a revert also carries the dependencies it inherits from the
/// revision it restores, because the restored content came from those sources and must disappear
/// with them.
public struct BrainIdentityRevision: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case configure, revert
    }
    public let revision: Int64
    public let kind: Kind
    public let displayName: String?
    public let character: BrainAgentCharacter?
    public let revertedToRevision: Int64?
    public let recordedAt: Double
    public let evidenceIDs: [String]

    public init(
        revision: Int64,
        kind: Kind,
        displayName: String? = nil,
        character: BrainAgentCharacter? = nil,
        revertedToRevision: Int64? = nil,
        recordedAt: Double,
        evidenceIDs: [String]
    ) {
        self.revision = revision
        self.kind = kind
        self.displayName = displayName
        self.character = character
        self.revertedToRevision = revertedToRevision
        self.recordedAt = recordedAt
        self.evidenceIDs = evidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case revision, kind, displayName, character, revertedToRevision, recordedAt, evidenceIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try c.decode(Int64.self, forKey: .revision),
            kind: try c.decode(Kind.self, forKey: .kind),
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
            character: try c.decodeIfPresent(BrainAgentCharacter.self, forKey: .character),
            revertedToRevision: try c.decodeIfPresent(Int64.self, forKey: .revertedToRevision),
            recordedAt: try c.decode(Double.self, forKey: .recordedAt),
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs)
        )
    }
}

/// A requested identity operation. Only an authenticated caller holding the identity grant may
/// submit one; a recalled claim, a quoted page or a model proposal is not an operation.
public struct BrainIdentityChange: Codable, Equatable, Sendable {
    public let kind: BrainIdentityRevision.Kind
    public let displayName: String?
    public let character: BrainAgentCharacter?
    /// The revision a `revert` restores. Ignored for `configure`.
    public let revision: Int64?
    public let evidenceIDs: [String]

    private init(kind: BrainIdentityRevision.Kind, displayName: String?, character: BrainAgentCharacter?,
                 revision: Int64?, evidenceIDs: [String]) {
        self.kind = kind
        self.displayName = displayName
        self.character = character
        self.revision = revision
        self.evidenceIDs = evidenceIDs
    }

    public static func configure(displayName: String? = nil, character: BrainAgentCharacter? = nil,
                                 evidenceIDs: [String]) -> BrainIdentityChange {
        .init(kind: .configure, displayName: displayName, character: character,
              revision: nil, evidenceIDs: evidenceIDs)
    }

    public static func revert(revision: Int64, evidenceIDs: [String]) -> BrainIdentityChange {
        .init(kind: .revert, displayName: nil, character: nil,
              revision: revision, evidenceIDs: evidenceIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, displayName, character, revision, evidenceIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decode(BrainIdentityRevision.Kind.self, forKey: .kind),
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
            character: try c.decodeIfPresent(BrainAgentCharacter.self, forKey: .character),
            revision: try c.decodeIfPresent(Int64.self, forKey: .revision),
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs)
        )
    }

    /// A display name is rendered into the agent's own context section, so it is a typed value with
    /// a bounded shape rather than arbitrary text: a line break or a control character could forge
    /// a section header and make personalisation look like an instruction or a memory.
    ///
    /// Both categories are rejected explicitly rather than relying on `controlCharacters` to
    /// happen to cover the Unicode line and paragraph separators, because that is not what its
    /// documented Cc/Cf definition promises and this code also runs on corelibs Foundation.
    public static let maximumDisplayNameCharacters = 64
    public var validDisplayName: String? {
        guard let displayName else { return nil }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumDisplayNameCharacters,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
              }) else { return nil }
        return trimmed
    }
}

public enum BrainAutobiographyKind: String, Codable, Equatable, Sendable {
    case utterance, outcomeReceipt
}

/// How much an autobiographical entry actually proves.
///
/// `utteranceOnly` means the agent is recorded as having *said* this, and nothing more: saying "I
/// searched successfully" is not evidence that a search ran. `reportedOutcomeUnverified` means a
/// tool result was reported with this status and recorded as such; nothing here has verified it.
public enum BrainAutobiographyQualification: String, Codable, Equatable, Sendable {
    case utteranceOnly, reportedOutcomeUnverified
}

/// One thing that actually happened, read live from the recorded turn and outcome journals.
///
/// There is no autobiography store: an entry is a projection of evidence the agent really produced
/// or receipts it really recorded, so a proposal, a plan or an invented source can never become a
/// completed experience. `redacted` entries carry no text at all until an audited sanitiser exists.
public struct BrainAutobiographyEntry: Codable, Equatable, Sendable {
    public let id: String
    public let kind: BrainAutobiographyKind
    public let qualification: BrainAutobiographyQualification
    public let text: String
    public let status: BrainOutcomeStatus?
    public let redacted: Bool
    public let recordedAt: Double
    public let evidenceIDs: [String]

    public init(
        id: String,
        kind: BrainAutobiographyKind,
        qualification: BrainAutobiographyQualification,
        text: String,
        status: BrainOutcomeStatus? = nil,
        redacted: Bool,
        recordedAt: Double,
        evidenceIDs: [String]
    ) {
        self.id = id
        self.kind = kind
        self.qualification = qualification
        self.text = text
        self.status = status
        self.redacted = redacted
        self.recordedAt = recordedAt
        self.evidenceIDs = evidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, qualification, text, status, redacted, recordedAt, evidenceIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            kind: try c.decode(BrainAutobiographyKind.self, forKey: .kind),
            qualification: try c.decode(BrainAutobiographyQualification.self, forKey: .qualification),
            text: try c.decode(String.self, forKey: .text),
            status: try c.decodeIfPresent(BrainOutcomeStatus.self, forKey: .status),
            redacted: try c.decodeIfPresent(Bool.self, forKey: .redacted) ?? true,
            recordedAt: try c.decode(Double.self, forKey: .recordedAt),
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs)
        )
    }
}

/// Everything the agent is, kept apart from everything the user is.
///
/// `capabilityAddenda` are the lines a native host contributes about what this installation can
/// actually do. They are injected by the server that builds the identity, never stored and never
/// model-authored, and they travel with the profile so a custom character cannot displace them.
public struct BrainAgentProfile: Codable, Equatable, Sendable {
    public let core: BrainAgentCore
    public let character: BrainAgentCharacter
    public let history: [BrainIdentityRevision]
    public let autobiography: [BrainAutobiographyEntry]
    public let capabilityAddenda: [String]

    /// The autobiography is a bounded window onto the most recent recorded experience, not a life
    /// story: the turn and outcome journals are the record, and an unbounded projection of them
    /// would grow without limit in a response that crosses the wire.
    public static let maximumAutobiographyEntries = 200

    public init(
        core: BrainAgentCore,
        character: BrainAgentCharacter,
        history: [BrainIdentityRevision],
        autobiography: [BrainAutobiographyEntry],
        capabilityAddenda: [String] = []
    ) {
        self.core = core
        self.character = character
        self.history = history
        self.autobiography = autobiography
        self.capabilityAddenda = capabilityAddenda
    }

    private enum CodingKeys: String, CodingKey {
        case core, character, history, autobiography, capabilityAddenda
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            core: try c.decode(BrainAgentCore.self, forKey: .core),
            character: try c.decodeIfPresent(BrainAgentCharacter.self, forKey: .character) ?? .init(),
            history: try c.decodeIfPresent([BrainIdentityRevision].self, forKey: .history) ?? [],
            autobiography: try c.decodeIfPresent([BrainAutobiographyEntry].self, forKey: .autobiography) ?? [],
            capabilityAddenda: try c.decodeIfPresent([String].self, forKey: .capabilityAddenda) ?? []
        )
    }
}

public struct BrainIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let kind: BrainIdentityKind
    public let displayName: String
    public let claimIDs: [String]
    /// Present only for the agent subject. The user and the relationship have no agent profile,
    /// and a wire record written before this field existed decodes with none.
    public let agentProfile: BrainAgentProfile?

    public init(
        id: String,
        kind: BrainIdentityKind,
        displayName: String,
        claimIDs: [String],
        agentProfile: BrainAgentProfile? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.claimIDs = claimIDs
        self.agentProfile = agentProfile
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, claimIDs, agentProfile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            kind: try c.decode(BrainIdentityKind.self, forKey: .kind),
            displayName: try c.decode(String.self, forKey: .displayName),
            claimIDs: try c.decode([String].self, forKey: .claimIDs),
            agentProfile: try c.decodeIfPresent(BrainAgentProfile.self, forKey: .agentProfile)
        )
    }

    public static let userID = "self:user"
    public static let agentID = "self:agent"
    public static let relationshipID = "relationship:user:agent"

    /// The three subjects the brain reserves. They are deterministic names, never merged, and a
    /// claim about one of them is never a claim about another.
    public static let reservedSubjects: Set<String> = [userID, agentID, relationshipID]

    /// Predicate namespace a generic claim may never use to influence the identity that
    /// `AgentIdentityService` returns. Model output and recalled claims land in the claim store
    /// like anything else; they do not reach the core.
    public static let reservedPredicatePrefix = "identity."
}
