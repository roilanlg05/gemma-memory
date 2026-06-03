import Foundation
import GRDB

public enum NodeKind: String, Codable, CaseIterable, Sendable { case person, place, fact, preference, topic, trait, task, plan, event, summary, insight, day, episode, conversation, followUp = "follow_up", clarification }
public enum MemoryLayer: String, Codable, CaseIterable, Sendable { case live, daily, identity, episodic } // episodic reservado (S11)
public enum Confidence: String, Codable, CaseIterable, Sendable { case sure, probable, maybe }
public enum Origin: String, Codable, CaseIterable, Sendable { case explicit, extracted }
public enum Relation: String, Codable, CaseIterable, Sendable {
    // Domain (model-emitted via associate phase)
    case knows, worksWith, family, likes, dislikes, locatedAt, visited, happenedOn, mentionedIn, partOfEpisode, relatedTo
    // Structural (engine-managed, never model-emitted)
    case belongsToHub   // src = kind-hub, dst = item of that kind
    case derivesFrom    // src = insight/summary, dst = source (task / transcript ref)
    case clarifies      // src = clarification, dst = ambiguous node it's about
    case sameAs         // src/dst are dedup-equivalent (kept when merge is non-destructive)
}

/// Reserved label for synthetic "kind hub" nodes — one per `NodeKind`. Holds `belongsToHub`
/// edges into every live node of that kind, so queries like "all pending tasks ordered by
/// date" or "all summaries" can navigate from a single anchor instead of full-table scan.
public enum HubKind: String, CaseIterable, Sendable {
    case hub = "hub"
}

public extension NodeKind {
    /// Canonical label for the kind hub. e.g. `.task` → "Tasks", `.followUp` → "Follow-ups".
    var hubLabel: String {
        switch self {
        case .person: return "People"
        case .place: return "Places"
        case .fact: return "Facts"
        case .preference: return "Preferences"
        case .topic: return "Topics"
        case .trait: return "Traits"
        case .task: return "Tasks"
        case .plan: return "Plans"
        case .event: return "Events"
        case .summary: return "Summaries"
        case .insight: return "Insights"
        case .day: return "Days"
        case .episode: return "Episodes"
        case .conversation: return "Conversations"
        case .followUp: return "Follow-ups"
        case .clarification: return "Clarifications"
        }
    }
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
