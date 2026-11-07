import Foundation

/// An uncertain, session-scoped hypothesis, never a diagnosis or a durable identity claim. Nil label permits abstention.

public struct BrainAffectHypothesis: Codable, Equatable, Sendable {
    public let id: String
    public let subjectID: String
    public let label: String?
    public let confidence: Double?
    public let basis: BrainAffectBasis?
    public let certainty: BrainAffectCertainty?
    public let sessionID: String
    public let observedAt: Double
    public let expiresAt: Double
    public let evidenceIDs: [String]

    public init(
        id: String,
        subjectID: String,
        label: String? = nil,
        confidence: Double? = nil,
        sessionID: String,
        observedAt: Double,
        expiresAt: Double,
        evidenceIDs: [String],
        basis: BrainAffectBasis? = nil,
        certainty: BrainAffectCertainty? = nil
    ) {
        self.id = id
        self.subjectID = subjectID
        self.label = label
        self.confidence = confidence
        self.basis = basis
        self.certainty = certainty
        self.sessionID = sessionID
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.evidenceIDs = evidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, subjectID, label, confidence, sessionID, observedAt, expiresAt, evidenceIDs, basis, certainty
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            subjectID: try c.decode(String.self, forKey: .subjectID),
            label: try c.decodeIfPresent(String.self, forKey: .label),
            confidence: try c.decodeIfPresent(Double.self, forKey: .confidence),
            sessionID: try c.decode(String.self, forKey: .sessionID),
            observedAt: try c.decode(Double.self, forKey: .observedAt),
            expiresAt: try c.decode(Double.self, forKey: .expiresAt),
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs),
            basis: try c.decodeIfPresent(BrainAffectBasis.self, forKey: .basis),
            certainty: try c.decodeIfPresent(BrainAffectCertainty.self, forKey: .certainty)
        )
    }
}

public enum BrainAffectBasis: String, Codable, Equatable, Sendable {
    case selfReported, inferred
}

public enum BrainAffectCertainty: String, Codable, Equatable, Sendable {
    case low, moderate, high
}

/// A bounded vocabulary for conversational signals. It carries no clinical categories.
public enum BrainAffectLabel: String, Codable, Equatable, Sendable {
    case sadness, frustration, anger, worry, fatigue, enthusiasm, relief, joy, confusion
}

/// Functional cues about an exchange, with no score for either participant.
public struct BrainInteractionCues: Codable, Equatable, Sendable {
    public enum Focus: String, Codable, Equatable, Sendable { case stayWithTopic, clarifyGoal }
    public enum Interest: String, Codable, Equatable, Sendable { case exploreTopic, acknowledgeProgress }
    public enum Tension: String, Codable, Equatable, Sendable { case slowDown, respondCalmly }

    public let focus: Focus?
    public let interest: Interest?
    public let tension: Tension?

    public init(focus: Focus? = nil, interest: Interest? = nil, tension: Tension? = nil) {
        self.focus = focus
        self.interest = interest
        self.tension = tension
    }
}

public struct BrainInteractionState: Codable, Equatable, Sendable {
    public let cues: BrainInteractionCues
    public let observedAt: Double
    public let expiresAt: Double
    public let evidenceIDs: [String]

    public init(cues: BrainInteractionCues, observedAt: Double, expiresAt: Double, evidenceIDs: [String]) {
        self.cues = cues
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.evidenceIDs = evidenceIDs
    }
}

public struct BrainAffectiveContext: Equatable, Sendable {
    public let hypotheses: [BrainAffectHypothesis]
    public let interaction: BrainInteractionState?
    public let advice: BrainConversationAdvicePreference?

    public init(hypotheses: [BrainAffectHypothesis] = [], interaction: BrainInteractionState? = nil,
                advice: BrainConversationAdvicePreference? = nil) {
        self.hypotheses = hypotheses
        self.interaction = interaction
        self.advice = advice
    }
}

public enum BrainConversationAdviceMode: String, Codable, Equatable, Sendable {
    case listen, welcome
}

public struct BrainConversationAdvicePreference: Codable, Equatable, Sendable {
    public let mode: BrainConversationAdviceMode
    public let expiresAt: Double?
    public let evidenceIDs: [String]

    public init(mode: BrainConversationAdviceMode, expiresAt: Double?, evidenceIDs: [String]) {
        self.mode = mode
        self.expiresAt = expiresAt
        self.evidenceIDs = evidenceIDs
    }
}

public enum BrainAffectCorrection: String, Codable, Equatable, Sendable {
    case dismiss
}
