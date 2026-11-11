import Foundation

public enum RecallOpportunity: String, Sendable {
    case mention, contextOnly, `defer`, discard
}

public struct RecallConversation: Sendable {
    public enum Mode: Equatable, Sendable { case social, taskFocused, serious }
    public let connectionID: String
    public let topic: String
    public let mode: Mode
    public let explicitlyRequested: Bool
    public let topicChanged: Bool
    public let sensitive: Bool

    public init(connectionID: String, topic: String, mode: Mode, explicitlyRequested: Bool = false,
                topicChanged: Bool = false, sensitive: Bool = false) {
        self.connectionID = connectionID
        self.topic = topic
        self.mode = mode
        self.explicitlyRequested = explicitlyRequested
        self.topicChanged = topicChanged
        self.sensitive = sensitive
    }
}

/// Process-local history for one authorized brain owner. The caller records actual delivery.
public final class RecallOpportunityGate: @unchecked Sendable {
    private struct Key: Hashable { let connection: String; let value: String }
    private let lock = NSLock()
    private let episodeCooldown: Double
    private let topicCooldown: Double
    private var episodes = [Key: Double]()
    private var topics = [Key: Double]()

    public init(episodeCooldown: Double = 900, topicCooldown: Double = 120) {
        self.episodeCooldown = episodeCooldown.isFinite ? max(0, episodeCooldown) : 900
        self.topicCooldown = topicCooldown.isFinite ? max(0, topicCooldown) : 120
    }

    public func opportunity(candidate: BrainRecallCandidate, conversation: RecallConversation, now: Double) -> RecallOpportunity {
        guard now.isFinite, !conversation.topicChanged, candidate.relevance >= 0.24 else { return .discard }
        if conversation.sensitive { return .contextOnly }
        if conversation.explicitlyRequested { return .mention }
        if candidate.claim.modality != .asserted || conversation.mode != .social || candidate.relevance < 0.55 { return .contextOnly }
        return lock.withLock {
            let episode = Key(connection: conversation.connectionID, value: candidate.episodeID)
            let topic = Key(connection: conversation.connectionID, value: conversation.topic)
            if let last = episodes[episode], now - last < episodeCooldown { return .defer }
            if !conversation.topic.isEmpty, let last = topics[topic], now - last < topicCooldown { return .defer }
            return .mention
        }
    }

    public func recordSurfaced(episodeID: String, conversation: RecallConversation, now: Double) {
        guard now.isFinite, !episodeID.isEmpty, !conversation.connectionID.isEmpty else { return }
        lock.withLock {
            let episode = Key(connection: conversation.connectionID, value: episodeID)
            let topic = Key(connection: conversation.connectionID, value: conversation.topic)
            episodes[episode] = max(episodes[episode] ?? now, now)
            if !conversation.topic.isEmpty { topics[topic] = max(topics[topic] ?? now, now) }
            episodes = bounded(episodes, at: now, cooldown: episodeCooldown)
            topics = bounded(topics, at: now, cooldown: topicCooldown)
        }
    }

    private func bounded(_ records: [Key: Double], at now: Double, cooldown: Double) -> [Key: Double] {
        let recent = records.filter { now - $0.value < cooldown }
        guard recent.count > 256 else { return recent }
        return Dictionary(uniqueKeysWithValues: recent.sorted {
            ($0.value, $0.key.connection, $0.key.value) > ($1.value, $1.key.connection, $1.key.value)
        }.prefix(256).map { ($0.key, $0.value) })
    }
}
