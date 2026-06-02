import Foundation
import GRDB

public enum NodeKind: String, Codable, CaseIterable, Sendable { case person, place, fact, preference, topic, trait, task, plan, summary, insight, day, episode, conversation, followUp = "follow_up", clarification }
public enum MemoryLayer: String, Codable, CaseIterable, Sendable { case live, daily, identity, episodic } // episodic reservado (S11)
public enum Confidence: String, Codable, CaseIterable, Sendable { case sure, probable, maybe }
public enum Origin: String, Codable, CaseIterable, Sendable { case explicit, extracted }
public enum Relation: String, Codable, CaseIterable, Sendable {
    case knows, worksWith, family, likes, dislikes, locatedAt, visited, happenedOn, mentionedIn, partOfEpisode, relatedTo
}

public struct Node: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var body: String
    public var layer: MemoryLayer
    public var createdAt: Double
    public var updatedAt: Double
    public var lastSeenAt: Double
    public var salience: Double
    public var decayRate: Double
    public var confidence: Confidence
    public var mentionCount: Int
    public var ttlExpiresAt: Double?
    public var sourceRef: String?
    public var origin: Origin
    public var serverId: String?
    public var dirty: Bool
    public var deleted: Bool
    public var extra: String?
    public static let databaseTableName = "node"

    public init(id: String, kind: String, label: String, body: String, layer: MemoryLayer,
                createdAt: Double, updatedAt: Double, lastSeenAt: Double, salience: Double,
                decayRate: Double, confidence: Confidence, mentionCount: Int,
                ttlExpiresAt: Double?, sourceRef: String?, origin: Origin, serverId: String?,
                dirty: Bool, deleted: Bool, extra: String?) {
        self.id = id; self.kind = kind; self.label = label; self.body = body; self.layer = layer
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastSeenAt = lastSeenAt
        self.salience = salience; self.decayRate = decayRate; self.confidence = confidence
        self.mentionCount = mentionCount; self.ttlExpiresAt = ttlExpiresAt; self.sourceRef = sourceRef
        self.origin = origin; self.serverId = serverId; self.dirty = dirty; self.deleted = deleted; self.extra = extra
    }
}

public struct Edge: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public var id: String
    public var srcId: String
    public var dstId: String
    public var relation: Relation
    public var weight: Double
    public var confidence: Confidence
    public var createdAt: Double
    public var updatedAt: Double
    public var dirty: Bool
    public var deleted: Bool
    public var extra: String?
    public static let databaseTableName = "edge"

    public init(id: String, srcId: String, dstId: String, relation: Relation, weight: Double,
                confidence: Confidence, createdAt: Double, updatedAt: Double, dirty: Bool,
                deleted: Bool, extra: String?) {
        self.id = id; self.srcId = srcId; self.dstId = dstId; self.relation = relation
        self.weight = weight; self.confidence = confidence; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.dirty = dirty; self.deleted = deleted; self.extra = extra
    }
}
