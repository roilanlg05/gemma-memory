import Foundation
import GRDB
import BrainContract

/// The resolved personal state of an identity: what the stored deltas add up to.
struct AgentIdentityState {
    var displayName: String?
    var character: BrainAgentCharacter?
}

/// The withdrawable part of an identity — what a retraction can take away — for revalidating a
/// snapshot after a model await.
///
/// The autobiography is deliberately absent. It is a projection that grows as the agent speaks and
/// as outcome receipts are recorded, and neither of those withdraws anything, so comparing it
/// turned an ordinary concurrent turn into a typed `conflict` that callers are told to read as
/// "data was withdrawn". The withdrawal classes stay covered without it: an in-thread utterance
/// that really is withdrawn also changes `ConversationSnapshot.sources`, and every forget mints a
/// revision. This set is a conservative superset of the identity's own dependencies — the
/// generation, the surviving revision numbers, every source those revisions declare, and the
/// configuration they resolve to — because a missed withdrawal is expensive and a spurious
/// conflict only costs a recomputation.
struct AgentIdentityDependencies: Equatable, Sendable {
    let generation: Int64
    let revisions: [Int64]
    let evidenceIDs: [String]
    let displayName: String
    let character: BrainAgentCharacter
}

/// Transactional store for the agent's own identity.
///
/// Three things are deliberately kept apart here:
///
/// 1. **The core is configuration, not memory.** `BrainAgentCore.gemma` is a compiled constant.
///    Nothing in the database can change the agent's nature, its values or its boundaries, so a
///    quoted page, a recalled claim or a model proposal has nothing to write to. A generic claim
///    whose predicate sits in `BrainIdentity.reservedPredicatePrefix` is not even reported as part
///    of the identity, which means the only way a committed claim could influence the identity is
///    the way it cannot: through this store.
/// 2. **The character is personal, source-bound data.** A custom display name and a typed
///    character are stored as an append-only series of deltas, each carrying the sources that
///    authorised it, each descending from the one before. Forgetting a source removes its revision
///    and that revision's descendants, and the defaults reseed — an older custom identity is never
///    revived by an erasure.
/// 3. **The autobiography is a live projection, never a store.** It is read from the recorded
///    assistant utterances and the sanitised outcome receipts that already exist, so a proposal, a
///    plan or a claim with an invented source can never appear as something that happened. An
///    utterance proves only that it was said; a receipt's status is reported, not verified.
///
/// Models are never called from here, and nothing in this file runs a model, an embedding or a
/// network request inside a transaction.
final class AgentIdentityStore {
    let brain: BrainStore
    /// Lines a native host contributes about what this installation can actually do. Server
    /// injected, never stored and never model-authored.
    let capabilityAddenda: [String]

    init(brain: BrainStore, capabilityAddenda: [String] = []) {
        self.brain = brain
        self.capabilityAddenda = capabilityAddenda
    }

    // MARK: Authorization

    /// An agent identity read obeys owner, subject and scope. The user's identity is not the
    /// agent's: asking for it through this entry point is a malformed request, not a wider grant,
    /// and the relationship subject is read through `relationship(db:)` alone.
    func requireAgentRead(_ agentID: String) throws {
        guard agentID == BrainIdentity.agentID else { throw BrainStoreError.invalid }
        try brain.requireAccess(subject: BrainIdentity.agentID, scope: .agent)
    }

    func requireRelationshipRead() throws {
        try brain.requireAccess(subject: BrainIdentity.relationshipID, scope: .shared)
    }

    // MARK: Reads

    /// The live generation for one agent. Its own row wins; the store-wide row in
    /// `brain_identity_meta` is the floor for an agent that has never been purged, and for one
    /// minted after a whole-store erasure. Reading it per agent is what keeps one agent's forget
    /// from moving another agent's floor.
    func generation(_ agentID: String, db: Database) throws -> Int64 {
        if let own = try Int64.fetchOne(db, sql: "SELECT generation FROM brain_identity_generation WHERE agent_id=?",
                                        arguments: [agentID]) {
            return own
        }
        return try BrainStore.identityGenerationFloor(db)
    }

    /// The surviving revisions of the current generation, oldest first. The row's own `revision`
    /// column is authoritative; a payload that disagrees with it is not trusted.
    func history(_ agentID: String, db: Database) throws -> [BrainIdentityRevision] {
        let generation = try self.generation(agentID, db: db)
        var entries = [BrainIdentityRevision]()
        for row in try Row.fetchAll(db, sql: "SELECT revision, payload FROM brain_identity_revision WHERE agent_id=? AND generation=? ORDER BY revision",
                                    arguments: [agentID, generation]) {
            let entry = try BrainStore.decode(BrainIdentityRevision.self, row["payload"])
            guard entry.revision == (row["revision"] as Int64) else { throw BrainStoreError.invalid }
            entries.append(entry)
        }
        return entries
    }

    /// Folds the deltas into the state they describe. A revert replays the prefix up to the
    /// revision it restores, rather than trusting a stored snapshot, so the restored state is
    /// always exactly what the surviving sources support. `visiting` bounds the replay.
    static func state(_ history: [BrainIdentityRevision], upTo: Int64? = nil,
                      visiting: Set<Int64> = []) -> AgentIdentityState {
        var state = AgentIdentityState()
        for entry in history where upTo.map({ entry.revision <= $0 }) ?? true {
            switch entry.kind {
            case .configure:
                if let displayName = entry.displayName { state.displayName = displayName }
                if let character = entry.character { state.character = character }
            case .revert:
                guard let target = entry.revertedToRevision, !visiting.contains(entry.revision) else { continue }
                state = Self.state(history, upTo: target, visiting: visiting.union([entry.revision]))
            }
        }
        return state
    }

    /// Claims about a subject, with the reserved identity predicates removed. A commit can record
    /// a claim that *looks* like identity configuration; it cannot make this read return it.
    ///
    /// What remains is a list of identifiers, not identity content: it reports that claims about
    /// this subject exist, and a caller that wants their content reads them from the claim store
    /// under its own grant. The rendered identity section is built from the core, the character and
    /// the autobiography alone, so nothing a claim says reaches a prompt through this path.
    private func claimIDs(subject: String, scope: BrainAccessScope, db: Database) throws -> [String] {
        try brain.claims(subject: subject, asOf: brain.clock(), scope: scope, db: db)
            .filter { !$0.predicate.hasPrefix(BrainIdentity.reservedPredicatePrefix) }
            .map(\.id)
    }

    /// `thread`, when given, confines the experience projection to that one conversation. A caller
    /// that renders verbatim autobiography text into a prompt passes the thread it is assembling,
    /// because the agent's own speech routinely restates what the user said and is therefore no
    /// weaker a class of content than a transcript turn. `nil` is the service's own read, which
    /// stays bounded by the grant's threads.
    func identity(agentID: String, db: Database, thread: String? = nil) throws -> BrainIdentity {
        try requireAgentRead(agentID)
        try brain.checkOwner(db, bind: false)
        return try resolvedIdentity(agentID: agentID, db: db, thread: thread)
    }

    /// Owner and access are already checked by the caller.
    private func resolvedIdentity(agentID: String, db: Database, thread: String? = nil) throws -> BrainIdentity {
        let history = try self.history(agentID, db: db)
        let state = Self.state(history)
        let profile = BrainAgentProfile(
            core: .gemma,
            character: state.character ?? .init(),
            history: history,
            autobiography: try autobiography(db: db, thread: thread),
            capabilityAddenda: capabilityAddenda)
        return BrainIdentity(id: agentID, kind: .agent,
                             displayName: state.displayName ?? BrainAgentCore.gemma.name,
                             claimIDs: try claimIDs(subject: agentID, scope: .agent, db: db),
                             agentProfile: profile)
    }

    /// What a retraction could take away from this identity, for post-await revalidation.
    func dependencies(agentID: String, db: Database) throws -> AgentIdentityDependencies {
        let history = try self.history(agentID, db: db)
        let state = Self.state(history)
        return .init(generation: try generation(agentID, db: db),
                     revisions: history.map(\.revision),
                     evidenceIDs: Set(history.flatMap(\.evidenceIDs)).sorted(),
                     displayName: state.displayName ?? BrainAgentCore.gemma.name,
                     character: state.character ?? .init())
    }

    /// The shared subject. It carries no agent profile and is never merged with either self: the
    /// relationship is what happened between them, not who either of them is.
    func relationship(db: Database) throws -> BrainIdentity {
        try requireRelationshipRead()
        try brain.checkOwner(db, bind: false)
        return BrainIdentity(id: BrainIdentity.relationshipID, kind: .relationship,
                             displayName: BrainAgentCore.relationshipDisplayName,
                             claimIDs: try claimIDs(subject: BrainIdentity.relationshipID, scope: .shared, db: db),
                             agentProfile: nil)
    }

    /// The readable sources the current history rests on, so a caller can cite them. `thread`
    /// confines them to one conversation, for the same reason the experience projection is
    /// confined: a caller assembling a thread must be able to resolve every id it cites, and
    /// `BrainContextBundle.sourceReferences` is a same-thread surface.
    func identityEvidence(agentID: String, db: Database, thread: String? = nil) throws -> [BrainEvidence] {
        var sources = [String: BrainEvidence]()
        for entry in try history(agentID, db: db) {
            for id in entry.evidenceIDs where sources[id] == nil {
                guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [id]) else { continue }
                let evidence = try BrainStore.decode(BrainEvidence.self, payload)
                guard admits(evidence, thread: thread) else { continue }
                sources[id] = evidence
            }
        }
        return sources.values.sorted { $0.id < $1.id }
    }

    /// Readable, inside the grant's threads, and — when a thread is named — inside that one.
    ///
    /// `BrainStore.canRead` admits `.user`-scoped evidence from any thread, which is right for a
    /// durable claim and wrong for raw text: every other raw-content path in the conversation
    /// store is exact-thread by construction, and the identity section must not become the one
    /// cross-chat channel for verbatim content.
    private func admits(_ evidence: BrainEvidence, thread: String?) -> Bool {
        guard brain.canRead(evidence), brain.authorization.threads.contains(evidence.threadID) else { return false }
        return thread.map { $0 == evidence.threadID } ?? true
    }

    /// What the agent actually did, in the order it happened.
    ///
    /// Only two kinds of row qualify, and both already exist for other reasons: an assistant
    /// utterance the agent is recorded as having produced, and an outcome receipt bound to one of
    /// those utterances. A receipt whose supporting sources are no longer readable is not history
    /// and is dropped. Nothing is copied into a second store, so there is no autobiography to
    /// diverge from the record.
    ///
    /// Entries are always bounded by the grant's threads, and by `thread` when one is named — see
    /// `admits`. A receipt is admitted only when *every* source it names is, so a receipt that
    /// spans conversations does not carry another one's identifiers into this one.
    func autobiography(db: Database, thread: String? = nil) throws -> [BrainAutobiographyEntry] {
        var entries = [BrainAutobiographyEntry]()
        var spoken = Set<String>()
        for payload in try String.fetchAll(db, sql: "SELECT payload FROM brain_evidence ORDER BY id") {
            guard let evidence = try? BrainStore.decode(BrainEvidence.self, payload) else { continue }
            guard evidence.sourceKind == .assistantMessage, evidence.speakerID == BrainIdentity.agentID,
                  admits(evidence, thread: thread), let text = evidence.text, !text.isEmpty else { continue }
            spoken.insert(evidence.id)
            entries.append(.init(id: evidence.id, kind: .utterance, qualification: .utteranceOnly,
                                 text: text, status: nil, redacted: false,
                                 recordedAt: evidence.recordedAt, evidenceIDs: [evidence.id]))
        }
        for row in try Row.fetchAll(db, sql: "SELECT principal, operation_hash, payload, redacted FROM brain_turn_outcome ORDER BY operation_hash") {
            let principal: String = row["principal"], key: String = row["operation_hash"]
            guard principal == brain.authorization.principal else { continue }
            let refs = try String.fetchAll(db, sql: "SELECT evidence_id FROM brain_turn_outcome_ref WHERE principal=? AND operation_hash=? ORDER BY evidence_id",
                                           arguments: [principal, key])
            guard !refs.isEmpty, refs.contains(where: { spoken.contains($0) }) else { continue }
            let admitted = try refs.allSatisfy { id in
                guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [id]),
                      let evidence = try? BrainStore.decode(BrainEvidence.self, payload) else { return false }
                return admits(evidence, thread: thread)
            }
            guard admitted, let outcome = try? BrainStore.decode(BrainOutcome.self, row["payload"] as String) else { continue }
            // Redaction is a durable property of the stored receipt, not a rendering choice: until
            // Tasks 12/14 inject an audited sanitiser the description is empty and stays empty.
            let redacted: Bool = row["redacted"]
            entries.append(.init(id: outcome.id, kind: .outcomeReceipt,
                                 qualification: .reportedOutcomeUnverified,
                                 text: redacted ? "" : outcome.description, status: outcome.status,
                                 redacted: redacted, recordedAt: outcome.recordedAt, evidenceIDs: refs))
        }
        return Array(entries.sorted { ($0.recordedAt, $0.id) < ($1.recordedAt, $1.id) }
            .suffix(BrainAgentProfile.maximumAutobiographyEntries))
    }

    // MARK: Revision

    /// What the operation journal keeps: the configuration this operation decided, and nothing
    /// else. The autobiography is a live projection of recorded turns and the capability addenda
    /// come from the host, so storing either here would duplicate a payload the brain already holds
    /// — and a duplicate copy of an utterance would survive the retraction of the turn it came
    /// from, which is exactly the leak the no-second-store rule exists to prevent.
    private static func decision(_ identity: BrainIdentity) -> BrainIdentity {
        guard let profile = identity.agentProfile else { return identity }
        return .init(id: identity.id, kind: identity.kind, displayName: identity.displayName,
                     claimIDs: identity.claimIDs,
                     agentProfile: .init(core: profile.core, character: profile.character,
                                         history: profile.history, autobiography: [], capabilityAddenda: []))
    }

    /// Restores the live parts of a replayed decision. The configuration is what the operation
    /// decided and is returned verbatim; experience and capabilities are what is true now.
    private func projecting(_ identity: BrainIdentity, db: Database) throws -> BrainIdentity {
        guard let profile = identity.agentProfile else { return identity }
        return .init(id: identity.id, kind: identity.kind, displayName: identity.displayName,
                     claimIDs: identity.claimIDs,
                     agentProfile: .init(core: profile.core, character: profile.character,
                                         history: profile.history,
                                         autobiography: try autobiography(db: db),
                                         capabilityAddenda: capabilityAddenda))
    }

    /// Sources that may authorise an identity operation: the user's own recorded messages, in a
    /// thread this principal holds, at the user scope, each with a surviving evidence root.
    ///
    /// This is what stops the agent configuring itself and stops quoted content configuring it
    /// either. A tool observation is something the agent read, and an assistant message is
    /// something the agent said; neither is the user deciding who the assistant is.
    private func authorizingSources(_ ids: [String], db: Database) throws -> [BrainEvidence] {
        guard !ids.isEmpty, Set(ids).count == ids.count else { throw BrainStoreError.invalid }
        return try ids.map { id in
            let evidence = try brain.loadEvidence(id, db: db)
            guard brain.canRead(evidence), evidence.accessScope == .user,
                  evidence.sourceKind == .userMessage, evidence.speakerID == BrainIdentity.userID,
                  brain.authorization.threads.contains(evidence.threadID) else { throw BrainStoreError.denied }
            guard !(try brain.roots(of: evidence, db: db)).isEmpty else { throw BrainStoreError.invalid }
            return evidence
        }
    }

    /// Applies one identity operation under optimistic concurrency.
    ///
    /// Replaying the same operation ID with the same request returns the configuration that
    /// operation decided, with the live experience projected onto it — including under a stale
    /// `expectedRevision`, since a retry of a change that already happened is not a conflict. The
    /// same operation ID with a different request is a conflict, as is a stale expected revision
    /// for a new operation, and a withdrawn operation ID is refused outright so an erased
    /// personalisation cannot be replayed back into existence.
    func revise(agentID: String, expectedRevision: Int64, operationID: String,
                change: BrainIdentityChange) throws -> BrainIdentity {
        try brain.requirePrincipal()
        // The identity grant is checked before anything else, so a caller without it learns
        // nothing about the store's state from the error it gets.
        guard brain.authorization.mayReviseIdentity else { throw BrainStoreError.denied }
        try requireAgentRead(agentID)
        let operation = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operation.isEmpty, expectedRevision >= 0 else { throw BrainStoreError.invalid }
        let key = BrainStore.digest(operation)
        let requestHash = BrainStore.digest(try BrainStore.encode(change))
        return try brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: true)
            if let row = try Row.fetchOne(db, sql: "SELECT request_hash, result, withdrawn, revision FROM brain_identity_operation WHERE principal=? AND operation_hash=?",
                                          arguments: [brain.authorization.principal, key]) {
                guard !(row["withdrawn"] as Bool) else { throw BrainStoreError.denied }
                guard (row["request_hash"] as String?) == requestHash,
                      let result = row["result"] as String? else { throw BrainStoreError.conflict }
                // A replay may hand back an earlier configuration — a retry of an operation that
                // later revisions have since built on is not a conflict, and the caller asked for
                // what *that* operation did. It may never hand back a configuration the surviving
                // record no longer holds: the operation's own revision must still be live, and
                // what it returned must be a prefix of the history that exists now. Otherwise an
                // idempotent retry would be told something the very next read contradicts, which
                // is how withdrawn personalisation comes back.
                let stored = try BrainStore.decode(BrainIdentity.self, result)
                let live = try self.history(agentID, db: db)
                guard let storedRevision = row["revision"] as Int64?,
                      live.contains(where: { $0.revision == storedRevision }),
                      let storedProfile = stored.agentProfile,
                      Array(live.prefix(storedProfile.history.count)) == storedProfile.history else {
                    throw BrainStoreError.conflict
                }
                return try projecting(stored, db: db)
            }
            let current = try BrainStore.revision(db)
            guard expectedRevision == current, current < Int64.max else { throw BrainStoreError.conflict }
            let next = current + 1
            let history = try self.history(agentID, db: db)
            let generation = try self.generation(agentID, db: db)
            _ = try authorizingSources(change.evidenceIDs, db: db)
            var evidenceIDs = [String]()
            var displayName: String?
            var character: BrainAgentCharacter?
            var revertedTo: Int64?
            switch change.kind {
            case .configure:
                displayName = change.validDisplayName
                character = change.character
                // An operation that changes nothing is not an operation, a display name that was
                // supplied but is not a valid one is refused rather than quietly dropped, and a
                // field belonging to the other operation kind is never silently ignored.
                guard displayName != nil || character != nil, change.revision == nil,
                      change.displayName == nil || displayName != nil else { throw BrainStoreError.invalid }
                evidenceIDs = change.evidenceIDs
            case .revert:
                guard change.displayName == nil, change.character == nil else { throw BrainStoreError.invalid }
                guard let target = change.revision,
                      let restored = history.first(where: { $0.revision == target }) else { throw BrainStoreError.invalid }
                revertedTo = target
                // A revert inherits the dependencies of the revision it restores: the restored
                // content came from those sources and has to disappear with them.
                evidenceIDs = Set(change.evidenceIDs).union(restored.evidenceIDs).sorted()
            }
            let entry = BrainIdentityRevision(revision: next, kind: change.kind, displayName: displayName,
                                              character: character, revertedToRevision: revertedTo,
                                              recordedAt: brain.clock(), evidenceIDs: evidenceIDs)
            try db.execute(sql: "INSERT INTO brain_identity_revision(agent_id, revision, generation, parent_revision, payload) VALUES (?, ?, ?, ?, ?)",
                           arguments: [agentID, next, generation, history.last?.revision, try BrainStore.encode(entry)])
            for id in evidenceIDs {
                try db.execute(sql: "INSERT INTO brain_identity_source(agent_id, revision, evidence_id) VALUES (?, ?, ?)",
                               arguments: [agentID, next, id])
            }
            try db.execute(sql: "UPDATE brain_meta SET revision=? WHERE id=1", arguments: [next])
            let identity = try resolvedIdentity(agentID: agentID, db: db)
            try db.execute(sql: "INSERT INTO brain_identity_operation(principal, operation_hash, request_hash, result, withdrawn, agent_id, revision) VALUES (?, ?, ?, ?, 0, ?, ?)",
                           arguments: [brain.authorization.principal, key, requestHash,
                                       try BrainStore.encode(Self.decision(identity)), agentID, next])
            return identity
        }
    }
}

/// Identifies the revision one identity operation produced, so a tombstone is matched to the exact
/// revision that was withdrawn rather than to a revision number alone.
private func agentIdentityRevisionKey(_ agentID: String, _ revision: Int64) -> String {
    agentID + "\u{1}" + String(revision)
}

/// One identity revision as the retraction closure needs it: its support set, the revision it
/// descends from and the revision it restores, if any.
private struct AgentIdentityRevisionRow {
    let agentID: String
    let revision: Int64
    let parent: Int64?
    let revertedTo: Int64?
    let sources: Set<String>
}

extension BrainStore {
    /// Erasure over the identity tables, inside the same transaction as the rest of the closure.
    ///
    /// A custom display name, a typed character and the revision history are personal data, so they
    /// follow the same rule as everything else the brain derived: a revision whose source is
    /// withdrawn goes, and so does every revision that descends from it or reverts to it. The
    /// defaults then reseed. Nothing revives an older custom identity, because the surviving
    /// revisions are replayed from scratch and an erased one is simply not there.
    ///
    /// Whole-store erasure, and a subject erasure naming any of the three reserved subjects, clear
    /// the custom history outright. Those scopes mean "this relationship's memory", and who the
    /// assistant was configured to be for this user is part of it.
    ///
    /// What remains is a tombstone per operation that holds no payload — `withdrawn = 1`, request
    /// fingerprint and result NULL — plus a bumped generation counter. The cost of this is that the
    /// user reconfigures the character; the cost of the alternative is withdrawn personalisation
    /// coming back.
    func purgeIdentityJournals(_ closure: BrainRetractionClosure, db: Database) throws {
        let clearAll = closure.purgeEverything
            || !closure.subjectIDs.isDisjoint(with: BrainIdentity.reservedSubjects)
        var rows = [AgentIdentityRevisionRow]()
        for row in try Row.fetchAll(db, sql: "SELECT agent_id, revision, parent_revision, payload FROM brain_identity_revision ORDER BY revision") {
            let agentID: String = row["agent_id"], revision: Int64 = row["revision"]
            let sources = Set(try String.fetchAll(db, sql: "SELECT evidence_id FROM brain_identity_source WHERE agent_id=? AND revision=?",
                                                  arguments: [agentID, revision]))
            // An undecodable payload still has its source table and its parent link, which is
            // enough to withdraw it; it is never left behind for being unreadable.
            let entry = try? Self.decode(BrainIdentityRevision.self, row["payload"] as String)
            rows.append(.init(agentID: agentID, revision: revision, parent: row["parent_revision"],
                              revertedTo: entry?.revertedToRevision, sources: sources))
        }
        // A revision number is only unique inside one agent's chain, so the closure is keyed by
        // (agent, revision) throughout. Keying it by the number alone made a parent link in one
        // chain withdraw the same-numbered revision in another, and deleted rows a forget had no
        // business touching.
        var removed = Set<String>()
        func key(_ row: AgentIdentityRevisionRow) -> String {
            agentIdentityRevisionKey(row.agentID, row.revision)
        }
        if clearAll {
            removed = Set(rows.map(key))
        } else {
            var changed = true
            while changed {
                changed = false
                for row in rows where !removed.contains(key(row)) {
                    let parentRemoved = row.parent.map {
                        removed.contains(agentIdentityRevisionKey(row.agentID, $0))
                    } == true
                    let targetRemoved = row.revertedTo.map {
                        removed.contains(agentIdentityRevisionKey(row.agentID, $0))
                    } == true
                    guard !row.sources.isDisjoint(with: closure.evidenceIDs)
                            || parentRemoved || targetRemoved else { continue }
                    removed.insert(key(row)); changed = true
                }
            }
        }
        guard clearAll || !removed.isEmpty else { return }
        var touchedAgents = Set<String>()
        for row in rows where removed.contains(key(row)) {
            touchedAgents.insert(row.agentID)
            try db.execute(sql: "DELETE FROM brain_identity_source WHERE agent_id=? AND revision=?",
                           arguments: [row.agentID, row.revision])
            try db.execute(sql: "DELETE FROM brain_identity_revision WHERE agent_id=? AND revision=?",
                           arguments: [row.agentID, row.revision])
        }
        for row in try Row.fetchAll(db, sql: "SELECT principal, operation_hash, agent_id, revision FROM brain_identity_operation") {
            let agentID: String? = row["agent_id"], revision: Int64? = row["revision"]
            var producedWithdrawnRevision = false
            if let agentID, let revision {
                producedWithdrawnRevision = removed.contains(agentIdentityRevisionKey(agentID, revision))
            }
            guard clearAll || producedWithdrawnRevision else { continue }
            try db.execute(sql: "UPDATE brain_identity_operation SET withdrawn=1, request_hash=NULL, result=NULL, revision=NULL WHERE principal=? AND operation_hash=?",
                           arguments: [row["principal"] as String, row["operation_hash"] as String])
        }
        // The generation counter is a stale-backup defence, so it still advances after a partial
        // purge — but the survivors are re-stamped into the new generation in the same
        // transaction. Advancing it without re-stamping made every revision whose sources are
        // still live unreadable, which is a silent erasure far wider than the user asked for: a
        // forget of the one message that authorised a revert also took the name and the character
        // set from two other messages that were still there.
        //
        // Both halves are keyed by agent. A partial forget advances the floor for the chains it
        // actually reached and re-stamps their survivors; a chain it never named keeps its own
        // floor and its own stamps, and is readable afterwards without having been rewritten.
        if clearAll {
            // Whole-store erasure, or an erasure naming a reserved subject, raises one floor above
            // every per-agent floor and drops the per-agent rows, so every agent — including one
            // whose rows only exist in a stale backup — falls back to a generation nothing was
            // ever stamped with.
            let agentFloor = try Int64.fetchOne(db, sql: "SELECT MAX(generation) FROM brain_identity_generation") ?? 0
            let floor = max(try BrainStore.identityGenerationFloor(db), agentFloor)
            guard floor < Int64.max else { throw BrainStoreError.invalid }
            try db.execute(sql: "DELETE FROM brain_identity_generation")
            try db.execute(sql: "UPDATE brain_identity_meta SET generation=? WHERE id=1", arguments: [floor + 1])
            return
        }
        let floor = try BrainStore.identityGenerationFloor(db)
        for agentID in touchedAgents.sorted() {
            let current = try Int64.fetchOne(db, sql: "SELECT generation FROM brain_identity_generation WHERE agent_id=?",
                                             arguments: [agentID]) ?? floor
            guard current < Int64.max else { throw BrainStoreError.invalid }
            try db.execute(sql: """
                INSERT INTO brain_identity_generation(agent_id, generation) VALUES (?, ?)
                ON CONFLICT(agent_id) DO UPDATE SET generation=excluded.generation
                """, arguments: [agentID, current + 1])
            try db.execute(sql: "UPDATE brain_identity_revision SET generation=? WHERE agent_id=? AND generation=?",
                           arguments: [current + 1, agentID, current])
        }
    }

    /// The store-wide generation floor. An agent with no row of its own reads this, so a new
    /// identity minted after a whole-store erasure can never land in a generation that erasure
    /// already declared dead.
    static func identityGenerationFloor(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT generation FROM brain_identity_meta WHERE id=1") ?? 0
    }
}
