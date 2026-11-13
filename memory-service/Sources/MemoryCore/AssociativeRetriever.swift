import Foundation
import BrainContract
import GRDB

public struct BrainRecallBudget: Equatable, Sendable {
    public let maximumCandidates: Int
    public let maximumHops: Int
    public let maximumVisited: Int
    public let maximumUTF8Bytes: Int

    public init(maximumCandidates: Int = 6, maximumHops: Int = 3, maximumVisited: Int = 64, maximumUTF8Bytes: Int = 2_048) {
        self.maximumCandidates = min(16, max(0, maximumCandidates))
        self.maximumHops = min(4, max(0, maximumHops))
        self.maximumVisited = min(128, max(0, maximumVisited))
        self.maximumUTF8Bytes = min(8_192, max(0, maximumUTF8Bytes))
    }
}

public enum BrainRecallStrategy: Equatable, Sendable { case hybrid, direct, vectorOnly }

/// Short-lived acceleration for a single service and embedder. It holds query vectors, never
/// input text, evidence, candidate IDs, or authorization decisions.
public final class RecallQueryPrefetch: @unchecked Sendable {
    public enum Mode: Sendable { case prepare, consume }

    fileprivate struct Key: Equatable {
        let threadID: String
        let operationID: String
        let digest: String
    }

    private struct Entry {
        let key: Key
        let vector: [Float]
        let expiry: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var entries: [Entry] = []
    private var evictionScheduled = false

    public init() {}

    fileprivate func take(_ key: Key) -> [Float]? {
        lock.withLock {
            entries.removeAll { $0.expiry <= clock.now }
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            return entries.remove(at: index).vector
        }
    }

    fileprivate func store(_ vector: [Float], for key: Key) {
        lock.withLock {
            let now = clock.now
            entries.removeAll { $0.expiry <= now || $0.key == key }
            if entries.count == 16 { entries.removeFirst() }
            entries.append(.init(key: key, vector: vector, expiry: now.advanced(by: .seconds(15))))
            scheduleEviction()
        }
    }

    /// Called with the lock held. One timer covers both quiet periods and frequent reads.
    private func scheduleEviction() {
        guard !evictionScheduled, let expiry = entries.first?.expiry else { return }
        evictionScheduled = true
        Task { [weak self, clock] in
            try? await clock.sleep(until: expiry)
            guard let self else { return }
            self.lock.withLock {
                self.entries.removeAll { $0.expiry <= clock.now }
                self.evictionScheduled = false
                self.scheduleEviction()
            }
        }
    }
}

public struct BrainRecallCandidate: Sendable {
    public let episodeID: String
    public let gist: String
    public let claim: BrainClaim
    /// Evidence for the claim itself, with original text withheld.
    public let sources: [BrainEvidence]
    /// The retrieval path, separate from truth support.
    public let associationClaimIDs: [String]
    public let relevance: Double
}

public struct BrainRecallResult: Sendable {
    public let candidates: [BrainRecallCandidate]
    public let visitedSubjects: Int
}

struct RecallCue {
    private static let stop: Set<String> = ["a", "an", "and", "about", "can", "do", "for", "from", "i", "in", "is", "it", "me", "of", "on", "remember", "that", "the", "to", "we", "what", "when", "where", "with", "you", "al", "con", "cual", "de", "del", "el", "en", "era", "la", "las", "los", "me", "por", "que", "recuerdas", "se", "te", "un", "una", "y"]
    let words: [String]
    let terms: Set<String>
    let year: Int?

    init(_ text: String) {
        let words = Self.tokens(text)
        year = words.compactMap(Int.init).first { (1900...2099).contains($0) }
        let date = year.map(String.init)
        self.words = words.filter { $0 != date }
        terms = Set(self.words)
    }

    static func tokens(_ text: String) -> [String] {
        text.prefix(4096).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { !stop.contains($0) }
    }

    func overlap(_ text: String) -> Double {
        let match = Self.tokens(text)
        guard !terms.isEmpty, !match.isEmpty else { return 0 }
        let unique = Set(match)
        let count = Double(terms.intersection(unique).count)
        guard count > 0 else { return 0 }
        let coverage = count / Double(terms.count)
        let precision = count / Double(unique.count)
        return 0.62 * coverage + 0.16 * precision + (coverage == 1 ? 0.16 : 0)
    }

    func allows(_ time: Double) -> Bool {
        guard let year else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.year, from: Date(timeIntervalSince1970: time)) == year
    }
}

/// One authorized SQLite snapshot per selection. Optional query embedding has a real deadline.
public final class AssociativeRetriever {
    let brain: BrainStore
    private let semantic: RecallSemanticLane?
    private let queryPrefetch: (cache: RecallQueryPrefetch, mode: RecallQueryPrefetch.Mode)?

    public init(brain: BrainStore, embedder: (any Embedder)? = nil, semanticDeadlineMilliseconds: Int = 60,
                queryPrefetch: (cache: RecallQueryPrefetch, mode: RecallQueryPrefetch.Mode)? = nil) {
        self.brain = brain
        semantic = embedder.map { RecallSemanticLane(embedder: $0, deadlineMilliseconds: semanticDeadlineMilliseconds) }
        self.queryPrefetch = queryPrefetch
    }

    public func retrieve(query: String, threadID: String, scope: BrainAccessScope, asOf: Double,
                         budget: BrainRecallBudget, strategy: BrainRecallStrategy = .hybrid) async throws -> BrainRecallResult {
        let vector = try await queryVector(query, threadID: threadID, scope: scope, strategy: strategy)
        try Task.checkCancellation()
        let result = try await brain.store.dbQueue.read { db in
            try self.retrieve(query: query, threadID: threadID, scope: scope, asOf: asOf,
                         budget: budget, strategy: strategy, vector: vector, db: db)
        }
        try Task.checkCancellation()
        return result
    }

    func queryVector(_ query: String, threadID: String, scope: BrainAccessScope,
                     strategy: BrainRecallStrategy = .hybrid, operationID: String? = nil) async throws -> [Float]? {
        try brain.requirePrincipal()
        guard brain.authorization.threads.contains(threadID), brain.authorization.scopes.contains(scope) else {
            throw BrainStoreError.denied
        }
        guard strategy != .direct, let semantic, !RecallCue(query).terms.isEmpty else { return nil }
        _ = try brain.revision()
        let input = String(query.prefix(4096))
        guard let queryPrefetch, let operationID, scope == .user else { return await semantic.vector(for: input) }
        let key = RecallQueryPrefetch.Key(threadID: threadID, operationID: operationID, digest: BrainStore.digest(query))
        if queryPrefetch.mode == .consume, let vector = queryPrefetch.cache.take(key) { return vector }
        let vector = await semantic.vector(for: input)
        try Task.checkCancellation()
        if queryPrefetch.mode == .prepare, let vector { queryPrefetch.cache.store(vector, for: key) }
        return vector
    }

    func retrieve(query: String, threadID: String, scope: BrainAccessScope, asOf: Double,
                  budget: BrainRecallBudget, strategy: BrainRecallStrategy = .hybrid,
                  vector: [Float]? = nil, db: Database) throws -> BrainRecallResult {
        let snapshot = try GraphMemoryQuery(brain: brain).snapshot(threadID: threadID, scope: scope, asOf: asOf, db: db)
        return try rank(query: query, asOf: asOf, budget: budget, strategy: strategy, vector: vector, snapshot: snapshot, db: db)
    }

    private struct Activation {
        let relevance: Double
        let path: [String]
    }

    func rank(query: String, asOf: Double, budget: BrainRecallBudget, strategy: BrainRecallStrategy,
              vector: [Float]?, snapshot: GraphRecallSnapshot, db: Database) throws -> BrainRecallResult {
        let cue = RecallCue(query)
        guard !cue.terms.isEmpty || cue.year != nil, budget.maximumCandidates > 0 else {
            return .init(candidates: [], visitedSubjects: 0)
        }
        let all = snapshot.claims
        let latestStates = Dictionary(grouping: all.filter {
            $0.claim.predicate == RecallClaimPredicate.state.rawValue && ($0.claim.modality == .asserted || $0.claim.modality == .negated)
        }, by: { $0.claim.subject }).values.compactMap { group in
            group.max { left, right in
                let l = left.claim, r = right.claim
                return (l.validFrom, l.recordedAt, l.revision, l.id) < (r.validFrom, r.recordedAt, r.revision, r.id)
            }?.claim.id
        }
        let currentStates = Set(latestStates)
        let eligible = all.filter {
            guard $0.text != nil, !BrainStore.requiresTurnSource($0.claim.predicate), cue.allows($0.claim.validFrom) else { return false }
            if $0.claim.subject == BrainIdentity.userID && $0.claim.predicate == ConsolidationIdentityClaim.namePredicate { return false }
            switch RecallClaimPredicate(rawValue: $0.claim.predicate) {
            case .link, .label, .detail: return false
            case .state: return currentStates.contains($0.claim.id)
            default: return !$0.claim.predicate.hasPrefix("project.")
            }
        }
        let vectors = try vector.map { try MemoryRetriever.sourceBoundVectorScores($0, supported: Set(all.map { $0.claim.id }), db: db) } ?? [:]
        var seeds = [String: Double]()
        var adjacency = [String: [(target: String, claimID: String)]]()
        let conflicted = Set(all.flatMap { $0.claim.contradictsIDs })
        if strategy != .vectorOnly {
            let activeSubjects = Set(all.map { $0.claim.subject })
            for entry in all where entry.claim.modality == .asserted && entry.claim.contradictsIDs.isEmpty
                && !conflicted.contains(entry.claim.id) {
                let claim = entry.claim
                let local = cue.overlap(String(claim.subject.split(separator: ":", maxSplits: 1).last ?? ""))
                let label = claim.predicate == RecallClaimPredicate.label.rawValue ? cue.overlap(entry.text ?? "") : 0
                let signal = max(local, label, (vectors[claim.id] ?? 0) * 0.65)
                if signal >= 0.24 { seeds[claim.subject] = max(seeds[claim.subject] ?? 0, signal) }
                if strategy == .hybrid, budget.maximumHops > 0,
                   claim.predicate == RecallClaimPredicate.link.rawValue, case .string(let target) = claim.value,
                   target != claim.subject, activeSubjects.contains(target) {
                    adjacency[claim.subject, default: []].append((target, claim.id))
                    adjacency[target, default: []].append((claim.subject, claim.id))
                }
            }
        }
        let activation = Self.expand(seeds, adjacency: adjacency, budget: budget)
        var ranked = [(candidate: BrainRecallCandidate, score: Double)]()
        for entry in eligible {
            let claim = entry.claim
            guard let text = entry.text else { continue }
            let lexical = strategy == .vectorOnly ? 0 : max(cue.overlap(text), cue.overlap(claim.predicate) * 0.65,
                entry.roots.map { cue.overlap($0.text ?? "") * 0.8 }.max() ?? 0)
            let semantic = (vectors[claim.id] ?? 0) * 0.75
            let graph = activation[claim.subject]
            let localScore = strategy == .vectorOnly ? 0 : seeds[claim.subject] ?? 0
            let graphScore = graph.map { $0.path.isEmpty ? 0 : $0.relevance } ?? 0
            let temporal = cue.year != nil && cue.terms.isEmpty ? 0.25 : 0
            let relevance = min(1, max(lexical, semantic, localScore, graphScore, temporal) + min(lexical, semantic) * 0.12)
            guard relevance >= 0.24, strategy != .vectorOnly || semantic >= 0.24 else { continue }
            let recency = 0.025 / (1 + max(0, asOf - claim.validFrom) / 86_400)
            let sources = entry.roots.map(Self.metadata)
            ranked.append((.init(episodeID: claim.predicate == RecallClaimPredicate.episode.rawValue ? claim.subject : claim.id,
                gist: text, claim: claim, sources: sources, associationClaimIDs: graphScore > max(lexical, semantic, localScore) ? graph?.path ?? [] : [],
                relevance: relevance), relevance + recency))
        }
        ranked.sort { ($0.score, $0.candidate.claim.validFrom, $0.candidate.claim.id) > ($1.score, $1.candidate.claim.validFrom, $1.candidate.claim.id) }
        var result = [BrainRecallCandidate]()
        var episodeIDs = Set<String>()
        var spent = 0
        for item in ranked where result.count < budget.maximumCandidates {
            let bytes = item.candidate.gist.utf8.count
            guard bytes <= budget.maximumUTF8Bytes - spent, episodeIDs.insert(item.candidate.episodeID).inserted else { continue }
            spent += bytes
            result.append(item.candidate)
        }
        return .init(candidates: result, visitedSubjects: activation.count)
    }

    private static func expand(_ seeds: [String: Double], adjacency: [String: [(target: String, claimID: String)]],
                               budget: BrainRecallBudget) -> [String: Activation] {
        let starts = seeds.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(budget.maximumVisited)
        var visited = Dictionary(uniqueKeysWithValues: starts.map { ($0.key, Activation(relevance: $0.value, path: [])) })
        var frontier = Array(starts.map(\.key))
        for _ in 0..<budget.maximumHops {
            guard !frontier.isEmpty else { break }
            var next = [String]()
            for id in frontier {
                guard let source = visited[id], source.path.count < budget.maximumHops else { continue }
                let edges = (adjacency[id] ?? []).sorted { ($0.target, $0.claimID) < ($1.target, $1.claimID) }
                for edge in edges.prefix(budget.maximumVisited) {
                    let score = source.relevance * 0.89
                    guard score > (visited[edge.target]?.relevance ?? 0),
                          visited[edge.target] != nil || visited.count < budget.maximumVisited else { continue }
                    visited[edge.target] = .init(relevance: score, path: source.path + [edge.claimID])
                    next.append(edge.target)
                }
            }
            frontier = next
        }
        return visited
    }

    static func metadata(_ evidence: BrainEvidence) -> BrainEvidence {
        .init(id: evidence.id, sourceKind: evidence.sourceKind, speakerID: evidence.speakerID,
              threadID: evidence.threadID, observedAt: evidence.observedAt, recordedAt: evidence.recordedAt,
              span: evidence.span, accessScope: evidence.accessScope, text: nil)
    }
}

/// A slow synchronous provider can occupy one lane, while a caller independently reaches its deadline.
private final class RecallSemanticLane: @unchecked Sendable {
    private let embedder: any Embedder
    private let deadline: UInt64
    private let lock = NSLock()
    private var inFlight = false

    init(embedder: any Embedder, deadlineMilliseconds: Int) {
        self.embedder = embedder
        deadline = UInt64(min(500, max(1, deadlineMilliseconds))) * 1_000_000
    }

    func vector(for query: String) async -> [Float]? {
        guard lock.withLock({
            guard !inFlight else { return false }
            inFlight = true
            return true
        }) else { return nil }
        let (stream, output) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let vector = try? embedder.embed(query)
            lock.withLock { inFlight = false }
            if let vector { output.yield(vector) }
            output.finish()
        }
        let timer = Task.detached { [deadline] in
            try? await Task.sleep(nanoseconds: deadline)
            if !Task.isCancelled { output.finish() }
        }
        defer { timer.cancel(); output.finish() }
        for await vector in stream { return vector }
        return nil
    }
}
