import Foundation

/// A conversational unit retains source identity and source references, not a flattened role string.

public struct BrainMessageUnit: Codable, Equatable, Sendable {
    public let id: String
    public let speakerID: String
    public let text: String
    public let observedAt: Double
    public let evidenceIDs: [String]

    public init(
        id: String,
        speakerID: String,
        text: String,
        observedAt: Double,
        evidenceIDs: [String]
    ) {
        self.id = id
        self.speakerID = speakerID
        self.text = text
        self.observedAt = observedAt
        self.evidenceIDs = evidenceIDs
    }
}

public struct BrainTurnRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let clientOperationID: String
    public let threadID: String
    public let message: BrainMessageUnit
    public let budget: BrainContextBudget

    public init(
        schemaVersion: Int = 1,
        clientOperationID: String,
        threadID: String,
        message: BrainMessageUnit,
        budget: BrainContextBudget
    ) throws {
        try BrainValidation.request(schemaVersion, clientOperationID)
        self.schemaVersion = schemaVersion
        self.clientOperationID = clientOperationID
        self.threadID = threadID
        self.message = message
        self.budget = budget
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, clientOperationID, threadID, message, budget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        try BrainValidation.schema(version)
        try self.init(
            schemaVersion: version,
            clientOperationID: try c.decode(String.self, forKey: .clientOperationID),
            threadID: try c.decode(String.self, forKey: .threadID),
            message: try c.decode(BrainMessageUnit.self, forKey: .message),
            budget: try c.decode(BrainContextBudget.self, forKey: .budget)
        )
    }
}

public struct BrainTurnCompletion: Codable, Equatable, Sendable {
    public let state: BrainPersistenceState
    public let revision: Int64
    public let evidenceIDs: [String]

    public init(
        state: BrainPersistenceState,
        revision: Int64,
        evidenceIDs: [String]
    ) {
        self.state = state
        self.revision = revision
        self.evidenceIDs = evidenceIDs
    }
}

/// Completing a previously issued turn supplies the actual assistant text under its own stable operation ID.

public struct BrainTurnCompletionRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let clientOperationID: String
    public let turnID: String
    public let assistantText: String
    public let evidenceIDs: [String]

    public init(
        schemaVersion: Int = 1,
        clientOperationID: String,
        turnID: String,
        assistantText: String,
        evidenceIDs: [String]
    ) throws {
        try BrainValidation.request(schemaVersion, clientOperationID)
        self.schemaVersion = schemaVersion
        self.clientOperationID = clientOperationID
        self.turnID = turnID
        self.assistantText = assistantText
        self.evidenceIDs = evidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, clientOperationID, turnID, assistantText, evidenceIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        try BrainValidation.schema(version)
        try self.init(
            schemaVersion: version,
            clientOperationID: try c.decode(String.self, forKey: .clientOperationID),
            turnID: try c.decode(String.self, forKey: .turnID),
            assistantText: try c.decode(String.self, forKey: .assistantText),
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs)
        )
    }
}

public struct BrainTurnResult: Codable, Equatable, Sendable {
    public let clientOperationID: String
    public let turnID: String
    public let reply: String
    public let completion: BrainTurnCompletion
    public let context: BrainContextBundle?

    public init(
        clientOperationID: String,
        turnID: String,
        reply: String,
        completion: BrainTurnCompletion,
        context: BrainContextBundle? = nil
    ) {
        self.clientOperationID = clientOperationID
        self.turnID = turnID
        self.reply = reply
        self.completion = completion
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case clientOperationID, turnID, reply, completion, context
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clientOperationID: try c.decode(String.self, forKey: .clientOperationID),
            turnID: try c.decode(String.self, forKey: .turnID),
            reply: try c.decode(String.self, forKey: .reply),
            completion: try c.decode(BrainTurnCompletion.self, forKey: .completion),
            context: try c.decodeIfPresent(BrainContextBundle.self, forKey: .context)
        )
    }
}
