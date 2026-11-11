import Foundation
import BrainContract
import GRDB

/// Commit these predicates through BrainStore using ordinary versioned BrainClaim updates.
/// Links and project membership carry an authorized target subject ID. The other predicates
/// carry text values. A subject's recall.state is one current-state slot. Use a distinct
/// subject for each independent state. Historical occurrences can use recall.episode.
/// A link helps locate other claims. Each claim retains its own evidence and modality.
public enum RecallClaimPredicate: String, Sendable {
    case label = "recall.label"
    case link = "recall.link"
    case episode = "recall.episode"
    case detail = "recall.detail"
    case state = "recall.state"
    case projectEpisode = "project.episode"
    case projectName = "project.name"
    case projectAlias = "project.alias"
    case checkpoint = "project.checkpoint"
    case decision = "project.decision"
    case progress = "project.progress"
    case nextStep = "project.next-step"
}

struct SupportedRecallClaim {
    let claim: BrainClaim
    let roots: [BrainEvidence]

    var text: String? {
        switch claim.value {
        case .string(let text): return text.isEmpty ? nil : text
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }
}

struct GraphRecallSnapshot {
    let claims: [SupportedRecallClaim]
    let blockedOriginals: Set<String>
}

struct GraphMemoryQuery {
    let brain: BrainStore

    func snapshot(threadID: String, scope: BrainAccessScope, asOf: Double, db: Database) throws -> GraphRecallSnapshot {
        try brain.checkOwner(db, bind: false)
        guard brain.authorization.threads.contains(threadID), brain.authorization.scopes.contains(scope) else {
            throw BrainStoreError.denied
        }
        guard asOf.isFinite else { throw BrainStoreError.invalid }
        var payloads = [String]()
        let subjects = brain.authorization.subjects.sorted()
        for offset in stride(from: 0, to: subjects.count, by: 400) {
            let batch = Array(subjects[offset..<min(offset + 400, subjects.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            payloads += try String.fetchAll(db, sql: "SELECT payload FROM brain_claim WHERE subject IN (\(placeholders))",
                arguments: StatementArguments(batch))
        }
        let claims = try payloads.map { try BrainStore.decode(BrainClaim.self, $0) }
            .filter { $0.validFrom <= asOf && $0.recordedAt <= asOf }
        // Commits only supersede within a subject, predicate and scope. A correction we
        // cannot read still hides what it replaced.
        let superseded = Set(claims.compactMap(\.supersedesID)).union(
            try BrainStore.disposedPredecessors(claims, asOf: asOf, recordedBy: asOf, db: db))
        let suppressed = Set(try String.fetchAll(db, sql: "SELECT claim_id FROM brain_projection WHERE suppressed=1"))
        var resolver = EvidenceResolver(brain: brain, threadID: threadID, scope: scope, asOf: asOf, db: db)
        var visible = [SupportedRecallClaim]()
        var blocked = Set<String>()
        for claim in claims {
            let ids = claim.evidenceIDs
            guard !ids.isEmpty else { continue }
            let excluded = try BrainStore.isExcluded(db, kind: .claim, id: claim.id,
                fingerprint: BrainStore.claimFingerprint(subject: claim.subject, predicate: claim.predicate, value: claim.value))
            let withdrawn = claim.status != .active || superseded.contains(claim.id) || suppressed.contains(claim.id)
                || (claim.validTo.map { asOf >= $0 } ?? false) || excluded
            if withdrawn {
                blocked.formUnion(ids)
                for id in ids { blocked.formUnion(try resolver.roots(id).map(\.id)) }
                continue
            }
            var roots = [String: BrainEvidence]()
            var admissible = true
            for id in ids {
                let resolved = try resolver.roots(id)
                guard !resolved.isEmpty else { admissible = false; break }
                for root in resolved { roots[root.id] = root }
            }
            guard admissible else { continue }
            let direct = try ids.compactMap { try resolver.evidence($0) }
            guard BrainStore.admitsPreference(claim, sources: direct, threadID: threadID) else { continue }
            visible.append(.init(claim: claim, roots: roots.values.sorted { $0.id < $1.id }))
        }
        return .init(claims: visible, blockedOriginals: blocked)
    }

    struct EvidenceResolver {
        let brain: BrainStore
        let threadID: String
        let scope: BrainAccessScope
        let asOf: Double
        let db: Database
        private var sources = [String: BrainEvidence]()
        private var missing = Set<String>()
        private var resolved = [String: [BrainEvidence]]()

        init(brain: BrainStore, threadID: String, scope: BrainAccessScope, asOf: Double, db: Database) {
            self.brain = brain; self.threadID = threadID; self.scope = scope; self.asOf = asOf; self.db = db
        }

        mutating func evidence(_ id: String) throws -> BrainEvidence? {
            if let source = sources[id] { return source }
            if missing.contains(id) { return nil }
            guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [id]),
                  try !BrainStore.isExcluded(db, kind: .evidence, id: id, fingerprint: BrainStore.evidenceFingerprint(payload)) else {
                missing.insert(id)
                return nil
            }
            let source = try BrainStore.decode(BrainEvidence.self, payload)
            guard source.id == id, try admits(source) else { missing.insert(id); return nil }
            sources[id] = source
            return source
        }

        func admits(_ source: BrainEvidence) throws -> Bool {
            guard source.accessScope == scope, brain.canRead(source),
                  brain.authorization.threads.contains(source.threadID),
                  scope != .thread || source.threadID == threadID,
                  brain.authorization.sourceSpeakers[source.sourceKind]?.contains(source.speakerID) == true,
                  source.observedAt <= asOf, source.recordedAt <= asOf,
                  source.text?.isEmpty == false else { return false }
            if source.id.hasPrefix("transcript:") {
                let rows = try TranscriptRow.fetchAll(db, sql: "SELECT * FROM transcript WHERE threadId=? AND createdAt=?",
                    arguments: [source.threadID, source.observedAt])
                return rows.contains { ConsolidationEvidenceAdapter.evidence(for: $0, scope: scope) == source }
            }
            return true
        }

        mutating func roots(_ id: String, visiting: Set<String> = []) throws -> [BrainEvidence] {
            if let cached = resolved[id] { return cached }
            guard visiting.count < 16, !visiting.contains(id), let source = try evidence(id) else { return [] }
            let parents = source.parentEvidenceIDs ?? []
            guard source.sourceKind == .derived else { return parents.isEmpty ? [source] : [] }
            guard !parents.isEmpty, parents.count <= 32 else { return [] }
            var byID = [String: BrainEvidence]()
            for parent in parents {
                let roots = try roots(parent, visiting: visiting.union([id]))
                guard !roots.isEmpty else { return [] }
                for root in roots { byID[root.id] = root }
                guard byID.count <= 32 else { return [] }
            }
            let result = byID.values.sorted { $0.id < $1.id }
            resolved[id] = result
            return result
        }
    }
}
