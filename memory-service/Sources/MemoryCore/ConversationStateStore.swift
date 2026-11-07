import Foundation
import GRDB
import BrainContract

/// Trusted grouping supplied by a caller with actual tool/turn linkage. Never inferred from time.
public struct ConversationUnitGroup: Equatable, Sendable {
    public let id: String
    public let evidenceIDs: [String]
    public init(id: String, evidenceIDs: [String]) { self.id = id; self.evidenceIDs = evidenceIDs }
}
public struct ConversationSource: Codable, Equatable, Sendable {
    public let evidence: BrainEvidence
    public let transcriptID: String?
    public let groupID: String
}
public struct ConversationSourceReference: Codable, Equatable, Sendable {
    public let evidenceID: String
    public let transcriptID: String?
    public let fingerprint: String
}
public struct ConversationSegment: Codable, Equatable, Sendable {
    public let id: String
    public let threadID: String
    public let revision: Int64
    /// Ordered raw source range, not references to previous summaries.
    public let sources: [ConversationSourceReference]
    public let state: ConversationStateCandidate
}
public struct ConversationSnapshot: Sendable {
    public let threadID: String
    public let revision: Int64
    public let sources: [ConversationSource]
    public let segments: [ConversationSegment]
    public let claims: [BrainClaim]
    let memoryEvidence: [BrainEvidence]
    let claimEvidenceIDs: [String: [String]]
    /// The agent's own identity, read in the same transaction as the conversation and confined to
    /// this thread. Absent when the grant does not hold the agent subject or scope.
    let identity: BrainIdentity?
    let identityEvidence: [BrainEvidence]
    /// What a retraction could take from that identity. Revalidation compares this rather than the
    /// whole identity, which would also compare a growing experience projection.
    let identityDependencies: AgentIdentityDependencies?
}

/// Source snapshots and derived segments share the brain's owner, revision and erasure boundary.
/// Models never run under these transactions. Raw transcript reads are always exact-thread.
public final class ConversationStateStore {
    let brain: BrainStore
    private let unitGroups: [ConversationUnitGroup]
    /// Native capability lines contributed by the host, passed through to the agent identity.
    private let capabilityAddenda: [String]
    public init(brain: BrainStore, unitGroups: [ConversationUnitGroup] = [], capabilityAddenda: [String] = []) {
        self.brain = brain; self.unitGroups = unitGroups; self.capabilityAddenda = capabilityAddenda
    }
    private func requireThread(_ thread: String, db: Database) throws {
        try brain.checkOwner(db, bind: false)
        guard brain.authorization.owner == ConsolidationEvidenceAdapter.ownerID,
              brain.authorization.subjects.contains("self:user"),
              !thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              brain.authorization.threads.contains(thread),
              !brain.authorization.scopes.isDisjoint(with: [.user, .thread]) else { throw BrainStoreError.denied }
    }
    static func reference(_ source: ConversationSource) throws -> ConversationSourceReference {
        .init(evidenceID: source.evidence.id, transcriptID: source.transcriptID,
              fingerprint: BrainStore.digest(try BrainStore.encode(source)))
    }
    public func snapshot(threadID: String) throws -> ConversationSnapshot {
        // A write transaction lets stale derived payloads be removed with their source check.
        try brain.store.dbQueue.write { try snapshot(threadID: threadID, db: $0) }
    }
    private func snapshot(threadID: String, db: Database) throws -> ConversationSnapshot {
        try requireThread(threadID, db: db)
        let revision = try BrainStore.revision(db)
        let rows = try TranscriptRow.fetchAll(db, sql: "SELECT * FROM transcript WHERE threadId=? ORDER BY seq", arguments: [threadID])
        var sources = rows.compactMap { row -> ConversationSource? in
            let scope: BrainAccessScope = brain.authorization.scopes.contains(.user) ? .user : .thread
            guard let evidence = ConsolidationEvidenceAdapter.evidence(for: row, scope: scope) else { return nil }
            return ConversationSource(evidence: evidence, transcriptID: row.id, groupID: ConversationWindow.groupID(for: row))
        }
        let rawPayloads = try String.fetchAll(db, sql: "SELECT payload FROM brain_evidence ORDER BY id")
        let allEvidence = try rawPayloads.map { try BrainStore.decode(BrainEvidence.self, $0) }
        let persistedByID = Dictionary(uniqueKeysWithValues: allEvidence.map { ($0.id, $0) })
        sources = sources.compactMap { source in
            guard let persisted = persistedByID[source.evidence.id] else { return source }
            // A persisted access scope is authoritative. Transcript adaptation cannot widen it.
            guard brain.canRead(persisted), persisted.threadID == threadID,
                  persisted.sourceKind == source.evidence.sourceKind,
                  persisted.speakerID == source.evidence.speakerID,
                  persisted.text == source.evidence.text else { return nil }
            return .init(evidence: persisted, transcriptID: source.transcriptID, groupID: source.groupID)
        }
        let transcriptIDs = Set(sources.map { $0.evidence.id })
        let additional = allEvidence.filter {
            $0.threadID == threadID && brain.canRead($0) && !transcriptIDs.contains($0.id)
                // Canonical transcript roots are current conversation only while their exact
                // original row still exists. A historical persisted copy is not a new raw turn.
                && !$0.id.hasPrefix("transcript:")
                && [.userMessage, .assistantMessage, .toolObservation].contains($0.sourceKind)
                && $0.text?.isEmpty == false && $0.observedAt.isFinite
        }.sorted { ($0.observedAt, $0.id) < ($1.observedAt, $1.id) }
        for evidence in additional {
            // Brain-turn references are authoritative linkage, unlike nearby timestamps.
            let turn = try String.fetchOne(db, sql: "SELECT turn_id FROM brain_turn_ref WHERE evidence_id=? ORDER BY turn_id LIMIT 1", arguments: [evidence.id])
            sources.append(.init(evidence: evidence, transcriptID: nil, groupID: turn.map { "turn:" + $0 } ?? "source:" + evidence.id))
        }
        // Both storage populations share a timeline. Timestamps govern across differing
        // times; actual transcript sequence wins tied timestamps before kind/ID tie-breaks.
        let transcriptSequences = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.seq) })
        sources.sort { lhs, rhs in
            if lhs.evidence.observedAt != rhs.evidence.observedAt { return lhs.evidence.observedAt < rhs.evidence.observedAt }
            if lhs.evidence.recordedAt != rhs.evidence.recordedAt { return lhs.evidence.recordedAt < rhs.evidence.recordedAt }
            let leftSequence = lhs.transcriptID.flatMap { transcriptSequences[$0] }
            let rightSequence = rhs.transcriptID.flatMap { transcriptSequences[$0] }
            switch (leftSequence, rightSequence) {
            case let (.some(left), .some(right)):
                if left != right { return left < right }
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
            if lhs.evidence.sourceKind != rhs.evidence.sourceKind { return lhs.evidence.sourceKind.rawValue < rhs.evidence.sourceKind.rawValue }
            return lhs.evidence.id < rhs.evidence.id
        }
        var assigned = Set<String>(), groupNames = Set<String>()
        for group in unitGroups {
            guard !group.id.isEmpty, groupNames.insert(group.id).inserted,
                  !group.evidenceIDs.isEmpty, Set(group.evidenceIDs).count == group.evidenceIDs.count,
                  assigned.isDisjoint(with: group.evidenceIDs) else { throw BrainStoreError.invalid }
            assigned.formUnion(group.evidenceIDs)
            let members = sources.filter { group.evidenceIDs.contains($0.evidence.id) }
            let complete = members.count == group.evidenceIDs.count
            let hasTool = members.contains { $0.evidence.sourceKind == .toolObservation }
            let hasAssistant = members.contains { $0.evidence.sourceKind == .assistantMessage }
            if !complete || (hasTool && !hasAssistant) {
                sources.removeAll { group.evidenceIDs.contains($0.evidence.id) }
                continue
            }
            sources = sources.map { source in
                group.evidenceIDs.contains(source.evidence.id)
                    ? .init(evidence: source.evidence, transcriptID: source.transcriptID, groupID: group.id) : source
            }
        }
        sources.removeAll { $0.evidence.sourceKind == .toolObservation && !assigned.contains($0.evidence.id) }
        let live = Dictionary(uniqueKeysWithValues: try sources.map { ($0.evidence.id, try Self.reference($0)) })
        let groupMembers = Dictionary(grouping: sources, by: { $0.groupID })
            .mapValues { Set($0.map { $0.evidence.id }) }
        var segments = [ConversationSegment]()
        for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM brain_conversation_segment WHERE thread_id=? ORDER BY rowid", arguments: [threadID]) {
            let segment = try BrainStore.decode(ConversationSegment.self, row["payload"])
            let segmentIDs = Set(segment.sources.map(\.evidenceID))
            // A late assistant/tool result extends the durable group; rebuild its old partial
            // summary from all originals instead of leaving the new member uncompacted forever.
            let completeGroups = sources.filter { segmentIDs.contains($0.evidence.id) }.allSatisfy {
                (groupMembers[$0.groupID] ?? []).isSubset(of: segmentIDs)
            }
            if segment.revision <= revision && completeGroups && !segment.sources.isEmpty
                && segment.sources.allSatisfy({ live[$0.evidenceID] == $0 }) {
                segments.append(segment)
            } else { try Self.deleteSegment(row["id"], db: db) }
        }
        // User-scoped durable memories intentionally cross chats. Thread-scoped evidence still
        // uses the existing authorization rules; conversation raw never inherits this widening.
        let evidenceByID = Dictionary(uniqueKeysWithValues: allEvidence.map { ($0.id, $0) })
        var visible = [BrainClaim]()
        for payload in try String.fetchAll(db, sql: "SELECT payload FROM brain_claim ORDER BY revision, id") {
            let claim = try BrainStore.decode(BrainClaim.self, payload)
            guard brain.authorization.subjects.contains(claim.subject), claim.validFrom <= brain.clock(),
                  !claim.evidenceIDs.isEmpty else { continue }
            let evidence = claim.evidenceIDs.compactMap { evidenceByID[$0] }
            guard evidence.count == claim.evidenceIDs.count, evidence.allSatisfy({ brain.canRead($0) }) else { continue }
            visible.append(claim)
        }
        let superseded = Set(visible.compactMap(\.supersedesID))
        let claims = visible.filter { $0.status == .active && !superseded.contains($0.id) && ($0.validTo.map { brain.clock() < $0 } ?? true) }
        var rootIDs = Set<String>(), claimEvidenceIDs = [String: [String]]()
        for claim in claims {
            var claimRoots = Set<String>()
            for id in claim.evidenceIDs {
                if let evidence = evidenceByID[id] { claimRoots.formUnion(try brain.roots(of: evidence, db: db)) }
            }
            rootIDs.formUnion(claimRoots)
            claimEvidenceIDs[claim.id] = claimRoots.sorted()
        }
        let memoryEvidence = rootIDs.sorted().compactMap { evidenceByID[$0] }.filter { brain.canRead($0) }
        // The agent's identity is read here, inside the same transaction, so that it is covered by
        // the post-await revalidation below: an identity source withdrawn while a model was running
        // must make assembly conflict rather than letting withdrawn personalisation reach a prompt.
        // A grant that does not hold the agent subject and scope simply gets no identity.
        // Both the experience projection and the citable identity sources are confined to this
        // thread: everything the identity section renders verbatim is raw content, and raw content
        // here is exact-thread like every other raw path in this store.
        var identity: BrainIdentity?
        var identityEvidence = [BrainEvidence]()
        var identityDependencies: AgentIdentityDependencies?
        if brain.authorization.subjects.contains(BrainIdentity.agentID),
           brain.authorization.scopes.contains(.agent) {
            let identityStore = AgentIdentityStore(brain: brain, capabilityAddenda: capabilityAddenda)
            identity = try identityStore.identity(agentID: BrainIdentity.agentID, db: db, thread: threadID)
            identityEvidence = try identityStore.identityEvidence(agentID: BrainIdentity.agentID, db: db, thread: threadID)
            identityDependencies = try identityStore.dependencies(agentID: BrainIdentity.agentID, db: db)
        }
        return .init(threadID: threadID, revision: revision, sources: sources, segments: segments,
                     claims: claims, memoryEvidence: memoryEvidence, claimEvidenceIDs: claimEvidenceIDs,
                     identity: identity, identityEvidence: identityEvidence,
                     identityDependencies: identityDependencies)
    }
    /// Revalidate after EVERY model await, including model failures before fallback. The result
    /// is built inside the same transaction that checks revision and original source bytes.
    func validated<T>(_ original: ConversationSnapshot, _ body: (ConversationSnapshot) throws -> T) throws -> T {
        try brain.store.dbQueue.write { db in
            let current = try snapshot(threadID: original.threadID, db: db)
            try Self.requireSameSources(original, current)
            return try body(current)
        }
    }
    private static func requireSameSources(_ old: ConversationSnapshot, _ current: ConversationSnapshot) throws {
        guard old.revision == current.revision, old.sources == current.sources,
              old.claims == current.claims, old.memoryEvidence == current.memoryEvidence,
              old.identityDependencies == current.identityDependencies else { throw BrainStoreError.conflict }
    }
    func save(_ candidate: ConversationStateCandidate, sources: [ConversationSource], snapshot original: ConversationSnapshot) throws {
        try brain.store.dbQueue.write { db in
            let current = try snapshot(threadID: original.threadID, db: db)
            try Self.requireSameSources(original, current)
            let ids = Set(sources.map { $0.evidence.id })
            guard !ids.isEmpty, ids.count == sources.count, sources.allSatisfy({ current.sources.contains($0) }),
                  !candidate.statements.isEmpty else { throw BrainStoreError.invalid }
            for statement in candidate.statements {
                guard !statement.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !statement.evidenceIDs.isEmpty, Set(statement.evidenceIDs).count == statement.evidenceIDs.count,
                      Set(statement.evidenceIDs).isSubset(of: ids) else { throw BrainStoreError.invalid }
            }
            let refs = try sources.map(Self.reference)
            let id = BrainStore.digest(try BrainStore.encode(refs) + ":" + String(current.revision))
            if current.segments.contains(where: { $0.id == id }) { return }
            guard current.segments.allSatisfy({ Set($0.sources.map(\.evidenceID)).isDisjoint(with: ids) }) else { throw BrainStoreError.conflict }
            let segment = ConversationSegment(id: id, threadID: current.threadID, revision: current.revision, sources: refs, state: candidate)
            try db.execute(sql: "INSERT INTO brain_conversation_segment(id, thread_id, revision, payload) VALUES (?, ?, ?, ?)",
                           arguments: [id, current.threadID, current.revision, try BrainStore.encode(segment)])
            for ref in refs {
                try db.execute(sql: "INSERT INTO brain_conversation_source(segment_id, evidence_id, transcript_id, fingerprint) VALUES (?, ?, ?, ?)",
                               arguments: [id, ref.evidenceID, ref.transcriptID, ref.fingerprint])
            }
        }
    }
    private static func deleteSegment(_ id: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM brain_conversation_source WHERE segment_id=?", arguments: [id])
        try db.execute(sql: "DELETE FROM brain_conversation_segment WHERE id=?", arguments: [id])
    }
}

extension BrainStore {
    /// Resolve a legacy-only canonical original without inventing or reingesting evidence.
    /// Callers still enforce owner/scope/thread grants; existing evidence rows always win.
    func conversationOriginal(_ evidenceID: String, db: Database) throws -> BrainEvidence? {
        guard evidenceID.hasPrefix("transcript:") else { return nil }
        for row in try TranscriptRow.fetchAll(db) {
            guard ConsolidationEvidenceAdapter.evidenceID(for: row) == evidenceID else { continue }
            return ConsolidationEvidenceAdapter.evidence(for: row)
        }
        return nil
    }
    /// Invalidate only dependent derived payloads. A revision stamp records provenance; normal
    /// new/empty turn commits must not discard an incremental conversation's entire gist.
    static func invalidateConversationState(evidenceIDs: Set<String> = [], transcriptIDs: Set<String> = [],
                                           threadIDs: Set<String> = [], all: Bool = false, db: Database) throws {
        var ids = Set<String>()
        for row in try Row.fetchAll(db, sql: "SELECT s.id, s.thread_id, r.evidence_id, r.transcript_id FROM brain_conversation_segment s JOIN brain_conversation_source r ON r.segment_id=s.id") {
            let transcript: String? = row["transcript_id"]
            if all || evidenceIDs.contains(row["evidence_id"] as String)
                || threadIDs.contains(row["thread_id"] as String)
                || transcript.map({ transcriptIDs.contains($0) }) == true { ids.insert(row["id"]) }
        }
        for id in ids {
            try db.execute(sql: "DELETE FROM brain_conversation_source WHERE segment_id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM brain_conversation_segment WHERE id=?", arguments: [id])
        }
    }
    func invalidateConversationCorrections(_ updates: [BrainClaimUpdate], db: Database) throws {
        var sources = Set<String>()
        for update in updates {
            for target in Set(update.claim.contradictsIDs + [update.claim.supersedesID].compactMap { $0 }) {
                guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id=?", arguments: [target]) else { continue }
                let claim = try Self.decode(BrainClaim.self, payload)
                sources.formUnion(claim.evidenceIDs)
                for id in claim.evidenceIDs { sources.formUnion(try roots(of: loadEvidence(id, db: db), db: db)) }
            }
        }
        if !sources.isEmpty { try Self.invalidateConversationState(evidenceIDs: sources, db: db) }
    }
}
