import Foundation

/// An uncertain, session-scoped hypothesis, never a diagnosis or a durable identity claim. Nil label permits abstention.

public struct BrainAffectHypothesis: Codable, Equatable, Sendable {
    public let id: String
    public let subjectID: String
    public let label: String?
    public let confidence: Double?
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
        evidenceIDs: [String]
    ) {
        self.id = id
        self.subjectID = subjectID
        self.label = label
        self.confidence = confidence
        self.sessionID = sessionID
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.evidenceIDs = evidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, subjectID, label, confidence, sessionID, observedAt, expiresAt, evidenceIDs
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
            evidenceIDs: try c.decode([String].self, forKey: .evidenceIDs)
        )
    }
}
