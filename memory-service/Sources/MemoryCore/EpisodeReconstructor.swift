import Foundation
import BrainContract
import GRDB

public struct EpisodeRecallFact: Sendable {
    public let text: String
    public let claim: BrainClaim
    public let sources: [BrainEvidence]
}

public struct ProjectRecallItem: Sendable {
    public let text: String
    public let claim: BrainClaim
    public let sources: [BrainEvidence]
    /// Evidence that this episode belongs to the project. Separate from support for the item.
    public let associationSources: [BrainEvidence]
    /// Task 11 has report provenance. Independent outcome verification requires a trusted receipt.
    public var verified: Bool { false }
}

public struct ProjectRecall: Sendable {
    public let projectID: String
    public let name: String
    public let checkpoint: ProjectRecallItem?
    public let decisions: [ProjectRecallItem]
    public let progress: [ProjectRecallItem]
    public let nextSteps: [ProjectRecallItem]
}

public enum ProjectRecallResult: Sendable {
    case none
    case clarify([String])
    case resolved(ProjectRecall)
}

public struct StartupOrientationFragment: Sendable {
    public let text: String
    public let source: BrainEvidence
}

public struct StartupOrientation: Sendable {
    public let threadID: String
    public let opening: StartupOrientationFragment?
    public let closing: StartupOrientationFragment?
}

/// Reconstructs from live canonical claims or authorized original evidence, at the requested detail.
public struct EpisodeReconstructor {
    private let brain: BrainStore

    public init(brain: BrainStore) { self.brain = brain }

    public func facts(episodeID: String, threadID: String, scope: BrainAccessScope, asOf: Double,
                      budget: BrainRecallBudget) throws -> [EpisodeRecallFact] {
        try brain.store.dbQueue.read { db in
            let snapshot = try GraphMemoryQuery(brain: brain).snapshot(threadID: threadID, scope: scope, asOf: asOf, db: db)
            let entries = snapshot.claims.filter { $0.claim.subject == episodeID }
            guard entries.contains(where: { $0.claim.predicate == RecallClaimPredicate.episode.rawValue }) else { return [] }
            var bytes = budget.maximumUTF8Bytes
            var facts = [EpisodeRecallFact]()
            for entry in entries.sorted(by: Self.newer) where entry.claim.predicate == RecallClaimPredicate.detail.rawValue {
                guard facts.count < budget.maximumCandidates else { break }
                guard let text = entry.text, text.utf8.count <= bytes else { continue }
                facts.append(.init(text: text, claim: entry.claim, sources: entry.roots.map(AssociativeRetriever.metadata)))
                bytes -= text.utf8.count
            }
            return facts
        }
    }

    public func originals(evidenceIDs: [String], threadID: String, scope: BrainAccessScope,
                          asOf: Double, budget: BrainRecallBudget) throws -> [BrainEvidence] {
        try brain.store.dbQueue.read { db in
            let snapshot = try GraphMemoryQuery(brain: brain).snapshot(threadID: threadID, scope: scope, asOf: asOf, db: db)
            var remaining = budget.maximumUTF8Bytes
            return try Self.authorizedOriginals(evidenceIDs, snapshot: snapshot).filter { source in
                let size = source.text?.utf8.count ?? 0
                guard size <= remaining else { return false }
                remaining -= size
                return true
            }
        }
    }

    static func authorizedOriginals(_ ids: [String], snapshot: GraphRecallSnapshot) throws -> [BrainEvidence] {
        guard ids.count <= 16, Set(ids).count == ids.count else { throw BrainStoreError.invalid }
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        var live = [String: BrainEvidence]()
        for source in snapshot.claims.flatMap(\.roots) where wanted.contains(source.id) && !snapshot.blockedOriginals.contains(source.id) {
            live[source.id] = source
        }
        return try ids.map {
            guard let source = live[$0] else { throw BrainStoreError.denied }
            return source
        }
    }

    static func project(query: String, snapshot: GraphRecallSnapshot, budget: BrainRecallBudget)
        -> (result: ProjectRecallResult, sources: [BrainEvidence]) {
        var cue = RecallCue.tokens(query)
        // A leading address belongs to neither full nor partial project-name matching.
        if cue.first == "oye" {
            cue.removeFirst()
            if cue.first == "gemma" { cue.removeFirst() }
        } else if cue.first == "gemma",
                  query.range(of: #"^\s*gemma\s*[,!:]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            cue.removeFirst()
        }
        let resumeWords: Set<String> = ["continue", "resume", "retomar", "continuar", "continuemos", "seguir", "sigamos"]
        let commandAndFiller = resumeWords.union(["working", "project", "trabajando", "proyecto", "vamos", "please", "favor"])
        let requested = cue.filter { !commandAndFiller.contains($0) }
        // All-generic names need a target after a resume command. Keep the intact target
        // for exact labels, and allow outer politeness around a non-structural target.
        // Mixed names retain their full words, e.g. "Project Aurora Please".
        let explicitTarget: [String]
        if let marker = cue.firstIndex(where: { resumeWords.contains($0) }),
           cue[..<marker].allSatisfy({ commandAndFiller.contains($0) }) {
            explicitTarget = Array(cue.dropFirst(marker + 1))
        } else { explicitTarget = [] }
        let politeness: Set<String> = ["please", "favor"]
        guard !cue.isEmpty, budget.maximumCandidates > 0, budget.maximumUTF8Bytes > 0 else { return (.none, []) }
        let entries = snapshot.claims.filter { $0.claim.predicate.hasPrefix("project.") }
        let contradicted = Set(entries.flatMap { $0.claim.contradictsIDs })
        let viable = entries.filter { !contradicted.contains($0.claim.id) && $0.claim.contradictsIDs.isEmpty }
        let grouped = Dictionary(grouping: viable, by: { $0.claim.subject })
        // Full labels are token ranges: a longer nested name may disambiguate a shorter
        // one, but disjoint names explicitly name multiple projects and must clarify.
        typealias Match = (String, SupportedRecallClaim, SupportedRecallClaim, [Range<Int>])
        var full = [Match](), partial = [Match]()
        for (subject, claims) in grouped {
            let ordered = claims.sorted(by: newer)
            guard let name = ordered.first(where: { isLabel($0, predicate: .projectName) }),
                  let nameText = name.text, nameText.utf8.count <= 192 else { continue }
            for label in [name] + ordered.filter({ isLabel($0, predicate: .projectAlias) }) {
                let words = RecallCue.tokens(label.text ?? "")
                guard !words.isEmpty else { continue }
                let isGenericName = words.allSatisfy { commandAndFiller.contains($0) }
                let ranges = cue.matchingRanges(words).filter { range in
                    guard isGenericName else { return true }
                    // A generic name can match only the target, never the leading command.
                    let targetStart = cue.count - explicitTarget.count
                    guard range.lowerBound >= targetStart else { return false }
                    if words == explicitTarget { return true }
                    return words != ["project"] && words != ["proyecto"] && words.contains { !politeness.contains($0) }
                        && cue[targetStart..<range.lowerBound].allSatisfy { politeness.contains($0) }
                        && cue[range.upperBound...].allSatisfy { politeness.contains($0) }
                }
                if !ranges.isEmpty { full.append((subject, name, label, ranges)) }
                else if !requested.isEmpty, Set(requested).isSubset(of: Set(words)) { partial.append((subject, name, label, [])) }
            }
        }
        let matches = full.isEmpty ? partial : full.filter { candidate in
            candidate.3.contains { range in
                !full.contains { other in
                    other.0 != candidate.0 && other.3.contains { longer in
                        longer.count > range.count && longer.lowerBound <= range.lowerBound && longer.upperBound >= range.upperBound
                    }
                }
            }
        }
        var seenProjects = Set<String>()
        let names = matches.sorted { ($0.0, $0.2.claim.id) < ($1.0, $1.2.claim.id) }
            .filter { seenProjects.insert($0.0).inserted }
        if names.count > 1 {
            // Ambiguity survives an options budget that cannot hold every choice. A generic
            // clarification discloses no unlisted options or their evidence references.
            guard names.count <= min(4, budget.maximumCandidates) else { return (.clarify([]), []) }
            let labels = names.compactMap { $0.1.text }
            let options = Set(labels).count == labels.count ? labels : zip(labels, names).map { "\($0.0) (\($0.1.0))" }
            guard options.joined(separator: " / ").utf8.count <= budget.maximumUTF8Bytes else { return (.clarify([]), []) }
            return (.clarify(options), names.flatMap { $0.1.roots + $0.2.roots })
        }
        guard let first = names.first, let display = first.1.text, display.utf8.count <= budget.maximumUTF8Bytes else { return (.none, []) }
        let local = (grouped[first.0] ?? []).sorted(by: newer)
        let liveEpisodes = Set(snapshot.claims.filter {
            $0.claim.predicate == RecallClaimPredicate.episode.rawValue && $0.claim.modality == .asserted
        }.map { $0.claim.subject })
        var memberships = [String: SupportedRecallClaim]()
        for entry in local where entry.claim.predicate == RecallClaimPredicate.projectEpisode.rawValue && entry.claim.modality == .asserted {
            guard case .string(let episode) = entry.claim.value, episode != first.0,
                  liveEpisodes.contains(episode), memberships[episode] == nil else { continue }
            memberships[episode] = entry
            if memberships.count == 32 { break }
        }
        let ordered = (local + memberships.keys.flatMap { grouped[$0] ?? [] }).sorted(by: newer)
        var bytes = budget.maximumUTF8Bytes - display.utf8.count
        var slots = budget.maximumCandidates
        func items(_ predicate: RecallClaimPredicate, limit: Int, accepts: (BrainClaimModality) -> Bool) -> [ProjectRecallItem] {
            var seen = Set<String>()
            var result = [ProjectRecallItem]()
            let matching = ordered.filter { $0.claim.predicate == predicate.rawValue && accepts($0.claim.modality) }
            let candidates = predicate == .checkpoint ? Array(matching.prefix(1)) : matching
            for entry in candidates {
                guard result.count < limit, slots > 0 else { break }
                guard let text = entry.text, text.utf8.count <= bytes, seen.insert(text).inserted else { continue }
                let associations = memberships[entry.claim.subject]?.roots ?? []
                result.append(.init(text: text, claim: entry.claim, sources: entry.roots.map(AssociativeRetriever.metadata),
                                    associationSources: associations.map(AssociativeRetriever.metadata)))
                bytes -= text.utf8.count
                slots -= 1
            }
            return result
        }
        let checkpoint = items(.checkpoint, limit: 1) { $0 == .asserted }.first
        let decisions = items(.decision, limit: 2) { $0 == .asserted }
        let progress = items(.progress, limit: 2) { $0 == .asserted }
        let next = items(.nextStep, limit: 3) { $0 == .asserted || $0 == .proposed || $0 == .hypothetical || $0 == .inferred }
        let sourceReferences = first.1.roots + first.2.roots
        return (.resolved(.init(projectID: first.0, name: display, checkpoint: checkpoint,
                                decisions: decisions, progress: progress, nextSteps: next)), sourceReferences)
    }

    private static func newer(_ lhs: SupportedRecallClaim, _ rhs: SupportedRecallClaim) -> Bool {
        let l = lhs.claim, r = rhs.claim
        return (l.validFrom, l.recordedAt, l.revision, l.id) > (r.validFrom, r.recordedAt, r.revision, r.id)
    }

    private static func isLabel(_ entry: SupportedRecallClaim, predicate: RecallClaimPredicate) -> Bool {
        entry.claim.predicate == predicate.rawValue && entry.claim.modality == .asserted && entry.text != nil
    }

    func orientation(threadID: String, scope: BrainAccessScope, asOf: Double,
                     snapshot: GraphRecallSnapshot, db: Database) throws -> StartupOrientation? {
        guard scope != .thread else { return nil }
        let resolver = GraphMemoryQuery.EvidenceResolver(brain: brain, threadID: threadID, scope: scope, asOf: asOf, db: db)
        struct Boundaries {
            var firstUser: BrainEvidence?
            var first: BrainEvidence
            var last: BrainEvidence
        }
        // Canonical evidence IDs are hashes, not transcript order. Resolve seq only for
        // an exact canonical match; handcrafted evidence retains its deterministic fallback.
        var canonicalSequences = [String: Int]()
        for row in try TranscriptRow.fetchAll(db) where brain.authorization.threads.contains(row.threadId) && row.threadId != threadID {
            guard let source = ConsolidationEvidenceAdapter.evidence(for: row, scope: scope) else { continue }
            canonicalSequences[source.id] = row.seq
        }
        func order(_ source: BrainEvidence) -> (Double, Double, Int, Int, String) {
            (source.observedAt, source.recordedAt, canonicalSequences[source.id] ?? 0,
             source.sourceKind == .userMessage ? 0 : 1, source.id)
        }
        var byThread = [String: Boundaries]()
        let rows = try String.fetchCursor(db, sql: """
            SELECT payload FROM brain_evidence
            WHERE json_extract(payload, '$.accessScope')=? AND json_extract(payload, '$.threadID')<>?
              AND json_extract(payload, '$.sourceKind') IN ('userMessage','assistantMessage')
            """, arguments: [scope.rawValue, threadID])
        while let payload = try rows.next() {
            let source = try BrainStore.decode(BrainEvidence.self, payload)
            guard !snapshot.blockedOriginals.contains(source.id), try resolver.admits(source),
                  try !BrainStore.isExcluded(db, kind: .evidence, id: source.id, fingerprint: BrainStore.evidenceFingerprint(payload)) else { continue }
            let user = source.sourceKind == .userMessage ? source : nil
            var ends = byThread[source.threadID] ?? Boundaries(firstUser: user, first: source, last: source)
            if order(source) < order(ends.first) { ends.first = source }
            if order(source) > order(ends.last) { ends.last = source }
            if let user, ends.firstUser.map({ order(user) < order($0) }) ?? true { ends.firstUser = user }
            byThread[source.threadID] = ends
        }
        guard let prior = byThread.values.max(by: { order($0.last) < order($1.last) }) else { return nil }
        func fragment(_ source: BrainEvidence) -> StartupOrientationFragment? {
            guard let original = source.text else { return nil }
            let prefix = String(decoding: original.utf8.prefix(192), as: UTF8.self)
            let text = prefix.hasSuffix("�") ? String(prefix.dropLast()) + "…" : prefix + (original.utf8.count > 192 ? "…" : "")
            return .init(text: text, source: AssociativeRetriever.metadata(source))
        }
        let first = prior.firstUser ?? prior.first
        return .init(threadID: prior.last.threadID, opening: fragment(first),
                     closing: prior.last.id == first.id ? nil : fragment(prior.last))
    }
}

extension AssociativeRetriever {
    public func resumeProject(query: String, threadID: String, scope: BrainAccessScope, asOf: Double,
                              budget: BrainRecallBudget) throws -> ProjectRecallResult {
        try brain.store.dbQueue.read { db in
            let snapshot = try GraphMemoryQuery(brain: brain).snapshot(threadID: threadID, scope: scope, asOf: asOf, db: db)
            return EpisodeReconstructor.project(query: query, snapshot: snapshot, budget: budget).result
        }
    }

    public func startupOrientation(threadID: String, scope: BrainAccessScope, asOf: Double) throws -> StartupOrientation? {
        try brain.store.dbQueue.read { db in
            let snapshot = try GraphMemoryQuery(brain: brain).snapshot(threadID: threadID, scope: scope, asOf: asOf, db: db)
            return try EpisodeReconstructor(brain: brain).orientation(threadID: threadID, scope: scope, asOf: asOf, snapshot: snapshot, db: db)
        }
    }
}

private extension Array where Element == String {
    func matchingRanges(_ words: [String]) -> [Range<Int>] {
        guard !words.isEmpty, words.count <= count else { return [] }
        return (0...(count - words.count)).compactMap {
            let range = $0..<($0 + words.count)
            return self[range].elementsEqual(words) ? range : nil
        }
    }
}
