import Foundation
import GRDB
import BrainContract
import Crypto

/// Identifier classes carried by persistent exclusion markers.
enum BrainExclusionKind: String, CaseIterable {
    case evidence, claim, node, transcript
}

/// A persistent exclusion marker: which row id was retracted, and a fingerprint of the content
/// that was withdrawn from it.
///
/// Keying on content as well as id is what separates *reingestion* — a stale backup or sync
/// pushing back the same body under the same id — from a legitimate later write that reuses a
/// deterministic id, such as a corrected evidence record or a re-stated identity. An id-only
/// marker would brick those write paths permanently. A fingerprint is a one-way digest and cannot
/// be read back as content, so a marker still carries nothing withdrawn.
struct BrainExclusionMarker: Hashable {
    let kind: BrainExclusionKind
    let id: String
    let fingerprint: String
}

/// Everything one retraction removes. Identifier sets are persisted as exclusion markers;
/// `withdrawnTexts` exists only for the duration of the transaction and is never stored.
struct BrainRetractionClosure {
    var purgeEverything = false
    var evidenceIDs = Set<String>()
    var rootEvidenceIDs = Set<String>()
    var claimIDs = Set<String>()
    var threadIDs = Set<String>()
    var subjectIDs = Set<String>()
    var nodeIDs = Set<String>()
    var transcriptIDs = Set<String>()
    var withdrawnTexts = Set<String>()
}

extension BrainStore {
    /// Content similarity is a backstop for derived rows that carry no provenance link (most
    /// consolidation output has a nil `sourceRef`). A short fragment is not distinctive enough to
    /// attribute to the withdrawn source, so only normalized texts of at least this length take
    /// part in it. Rows reachable through recorded provenance are purged regardless of length.
    static let minimumDistinctiveTextLength = 12

    /// Deterministic ids the brain reuses by design: the singleton identities and the kind hubs.
    /// Their rows are erased like any other, but they are never *marked*, because a marker on a
    /// reusable id would refuse every later write to it and would make a legitimately rebuilt row
    /// deletable by `applyExclusions`. A rebuilt hub or a re-stated identity is not the withdrawn
    /// row — it is new content under a fixed name.
    static let unmarkableNodeIDs: Set<String> = [selfUserID, "self:agent", "relationship:user:agent"]

    static func isMarkable(_ node: Node) -> Bool {
        !unmarkableNodeIDs.contains(node.id)
            && node.kind != HubKind.hub.rawValue
            && !node.id.hasPrefix("hub:")
    }

    static func normalizedContent(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static let fingerprintSeparator = "\u{1F}"

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func nodeFingerprint(label: String, body: String) -> String {
        digest(normalizedContent(label) + fingerprintSeparator + normalizedContent(body))
    }
    static func nodeFingerprint(_ node: Node) -> String {
        nodeFingerprint(label: node.label, body: node.body)
    }
    static func transcriptFingerprint(_ text: String) -> String {
        digest(normalizedContent(text))
    }
    /// Evidence payloads are canonically encoded, so a byte-identical payload is a replay of the
    /// same record, while any correction — new text, new observation time — hashes differently.
    static func evidenceFingerprint(_ payload: String) -> String {
        digest(payload)
    }
    /// A claim's revision is stamped at commit time, so the fingerprint covers what the claim
    /// asserts rather than when it was recorded. An undecodable payload is fingerprinted raw.
    static func claimFingerprint(subject: String, predicate: String, value: BrainValue) -> String {
        let encoded = (try? encode(value)) ?? ""
        return digest(normalizedContent(subject) + fingerprintSeparator
                      + normalizedContent(predicate) + fingerprintSeparator + encoded)
    }
    static func claimFingerprint(payload: String) -> String {
        guard let claim = try? decode(BrainClaim.self, payload) else { return digest(payload) }
        return claimFingerprint(subject: claim.subject, predicate: claim.predicate, value: claim.value)
    }

    static func isExcluded(_ db: Database, kind: BrainExclusionKind, id: String, fingerprint: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM brain_exclusion WHERE kind=? AND id=? AND fingerprint=?)",
                          arguments: [kind.rawValue, id, fingerprint]) ?? false
    }

    // MARK: Forget

    /// Erases a scope and everything derived from it in one transaction. Success means the whole
    /// closure is gone; any failure rolls back and throws, so a receipt never implies an erasure
    /// that only partly happened.
    func forget(scope: BrainForgetScope, expectedRevision: Int64, operationID: String) throws -> BrainForgetReceipt {
        try requirePrincipal()
        guard authorization.mayForget, authorization.scopes.contains(.user) else { throw BrainStoreError.denied }
        let operation = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (scope.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operation.isEmpty, expectedRevision >= 0 else { throw BrainStoreError.invalid }
        if scope.kind == .all {
            guard target.isEmpty else { throw BrainStoreError.invalid }
            // Whole-store erasure is the owner's decision alone; a delegate cannot make it.
            guard authorization.principal == authorization.owner else { throw BrainStoreError.denied }
        } else {
            guard !target.isEmpty else { throw BrainStoreError.invalid }
        }
        let scopePayload = try Self.encode(scope)
        return try store.dbQueue.write { db in
            try checkOwner(db, bind: false)
            if let row = try Row.fetchOne(db, sql: "SELECT scope, receipt FROM brain_forget_operations WHERE principal=? AND operation=?",
                                          arguments: [authorization.principal, operation]) {
                guard (row["scope"] as String) == scopePayload else { throw BrainStoreError.conflict }
                return try Self.decode(BrainForgetReceipt.self, row["receipt"] as String)
            }
            let current = try Self.revision(db)
            guard expectedRevision == current, current < Int64.max else { throw BrainStoreError.conflict }
            try authorizeTarget(scope.kind, target, db: db)
            let closure = try resolveClosure(scope.kind, target, db: db)
            let next = current + 1
            try purge(closure, db: db, revision: next)
            try db.execute(sql: "UPDATE brain_meta SET revision=? WHERE id=1", arguments: [next])
            let receipt = BrainForgetReceipt(
                clientOperationID: operation, scope: scope, state: .committed, revision: next,
                forgottenEvidenceIDs: closure.evidenceIDs.sorted(),
                forgottenClaimIDs: closure.claimIDs.sorted(),
                affectedIDs: closure.nodeIDs.union(closure.transcriptIDs).sorted(),
                sourceEvidenceIDs: closure.rootEvidenceIDs.sorted())
            try db.execute(sql: "INSERT INTO brain_forget_operations VALUES (?, ?, ?, ?)",
                           arguments: [authorization.principal, operation, scopePayload, try Self.encode(receipt)])
            return receipt
        }
    }

    /// Re-applies the exclusion markers of the given retractions, so a store that was restored or
    /// re-synced from stale inputs cannot serve withdrawn rows. The caller invokes this before
    /// restored reads; nothing schedules it.
    ///
    /// Each receipt must be one this store issued — it is compared against
    /// `brain_forget_operations` and an unknown or altered receipt is refused. Without that check
    /// this would be a second deletion path able to erase arbitrary identifiers with no scope, no
    /// authorization over the target and no revision. The markers of the verified retractions are
    /// then the authoritative work list, and each is re-applied only while the row still holds the
    /// fingerprinted content, so a row that legitimately reuses a retracted id survives.
    ///
    /// No revision is minted: this re-applies an earlier decision, it does not make a new one.
    func applyExclusions(_ receipts: [BrainForgetReceipt]) throws {
        try requirePrincipal()
        guard authorization.mayForget, authorization.scopes.contains(.user) else { throw BrainStoreError.denied }
        try store.dbQueue.write { db in
            try checkOwner(db, bind: false)
            var authorized = Set<String>()
            for receipt in receipts {
                guard let stored = try String.fetchOne(db, sql: "SELECT receipt FROM brain_forget_operations WHERE principal=? AND operation=?",
                                                       arguments: [authorization.principal, receipt.clientOperationID]),
                      try Self.decode(BrainForgetReceipt.self, stored) == receipt else { throw BrainStoreError.denied }
                authorized.formUnion(receipt.forgottenEvidenceIDs)
                authorized.formUnion(receipt.forgottenClaimIDs)
                authorized.formUnion(receipt.sourceEvidenceIDs ?? [])
                authorized.formUnion(receipt.affectedIDs ?? [])
            }
            guard !authorized.isEmpty else { return }
            var closure = BrainRetractionClosure()
            for row in try Row.fetchAll(db, sql: "SELECT kind, id, fingerprint FROM brain_exclusion") {
                let id: String = row["id"], fingerprint: String = row["fingerprint"]
                guard authorized.contains(id), let kind = BrainExclusionKind(rawValue: row["kind"]) else { continue }
                switch kind {
                case .node:
                    guard let node = try Node.fetchOne(db, key: id),
                          Self.nodeFingerprint(node) == fingerprint else { continue }
                    closure.nodeIDs.insert(id)
                case .transcript:
                    guard let text = try String.fetchOne(db, sql: "SELECT text FROM transcript WHERE id=?", arguments: [id]),
                          Self.transcriptFingerprint(text) == fingerprint else { continue }
                    closure.transcriptIDs.insert(id)
                case .evidence:
                    guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [id]),
                          Self.evidenceFingerprint(payload) == fingerprint else { continue }
                    closure.evidenceIDs.insert(id)
                case .claim:
                    guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id=?", arguments: [id]),
                          Self.claimFingerprint(payload: payload) == fingerprint else { continue }
                    closure.claimIDs.insert(id)
                }
            }
            try purge(closure, db: db, revision: try Self.revision(db))
        }
    }

    // MARK: Authorization

    private func authorizeTarget(_ kind: BrainForgetScopeKind, _ target: String, db: Database) throws {
        switch kind {
        case .all:
            return
        case .thread:
            guard authorization.threads.contains(target) else { throw BrainStoreError.denied }
        case .subject:
            guard authorization.subjects.contains(target) else { throw BrainStoreError.denied }
        case .evidence:
            let evidence = try loadEvidence(target, db: db)
            guard canRead(evidence), authorization.threads.contains(evidence.threadID) else { throw BrainStoreError.denied }
        case .claim:
            guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id=?", arguments: [target]) else {
                throw BrainStoreError.invalid
            }
            let claim = try Self.decode(BrainClaim.self, payload)
            guard authorization.subjects.contains(claim.subject) else { throw BrainStoreError.denied }
        }
    }

    /// Provenance-linked erasure follows a withdrawn source wherever it lives, across threads — but
    /// only within what the principal holds. If the closure reaches a thread or a subject outside
    /// the grant the whole operation is refused, rather than erasing part of it: a half-erasure
    /// that reports success is worse than an observable failure.
    private func requireGrant(_ closure: BrainRetractionClosure,
                              evidence: [String: BrainEvidence],
                              claims: [String: BrainClaim],
                              transcriptThreads: [String: String]) throws {
        var threads = Set(closure.threadIDs)
        threads.formUnion(closure.evidenceIDs.compactMap { evidence[$0]?.threadID })
        threads.formUnion(closure.transcriptIDs.compactMap { transcriptThreads[$0] })
        guard threads.isSubset(of: authorization.threads) else { throw BrainStoreError.denied }
        var subjects = Set(closure.subjectIDs)
        subjects.formUnion(closure.claimIDs.compactMap { claims[$0]?.subject })
        guard subjects.isSubset(of: authorization.subjects) else { throw BrainStoreError.denied }
    }

    // MARK: Closure resolution

    private func resolveClosure(_ kind: BrainForgetScopeKind, _ target: String, db: Database) throws -> BrainRetractionClosure {
        var closure = BrainRetractionClosure()
        var evidence = [String: BrainEvidence]()
        var opaqueEvidence = [String: String]()
        for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM brain_evidence") {
            let id: String = row["id"], payload: String = row["payload"]
            if let decoded = try? Self.decode(BrainEvidence.self, payload) { evidence[id] = decoded }
            else { opaqueEvidence[id] = payload }
        }
        var claims = [String: BrainClaim]()
        var claimPayloads = [String: String]()
        var opaqueClaims = Set<String>()
        for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM brain_claim") {
            let id: String = row["id"], payload: String = row["payload"]
            claimPayloads[id] = payload
            if let decoded = try? Self.decode(BrainClaim.self, payload) { claims[id] = decoded }
            else { opaqueClaims.insert(id) }
        }

        switch kind {
        case .all:
            closure.purgeEverything = true
            closure.evidenceIDs = Set(evidence.keys).union(opaqueEvidence.keys)
            closure.claimIDs = Set(claimPayloads.keys)
            closure.subjectIDs = Set(claims.values.map(\.subject))
            closure.threadIDs = Set(evidence.values.map(\.threadID))
                .union(try String.fetchAll(db, sql: "SELECT DISTINCT threadId FROM transcript"))
        case .thread:
            closure.threadIDs = [target]
            closure.evidenceIDs = Set(evidence.filter { $0.value.threadID == target }.keys)
        case .evidence:
            closure.evidenceIDs = [target]
        case .subject:
            closure.subjectIDs = [target]
            closure.claimIDs = Set(claims.filter { $0.value.subject == target }.keys)
        case .claim:
            closure.claimIDs = [target]
        }

        // Dependency fixpoint over recorded provenance. Derived observations rooted in a withdrawn
        // source go with it; a claim that loses any of its sources can never be re-verified,
        // because claim payloads are immutable and its `evidenceIDs` are its complete support set;
        // a source kept alive only by purged claims is orphaned. Each round can feed the next.
        var changed = true
        while changed {
            changed = false
            for (id, item) in evidence where !closure.evidenceIDs.contains(id) {
                if !closure.evidenceIDs.isDisjoint(with: item.parentEvidenceIDs ?? []) {
                    closure.evidenceIDs.insert(id); changed = true
                }
            }
            for (id, claim) in claims where !closure.claimIDs.contains(id) {
                if !closure.evidenceIDs.isDisjoint(with: claim.evidenceIDs) {
                    closure.claimIDs.insert(id); changed = true
                }
            }
            // An undecodable claim payload still names its sources textually.
            for id in opaqueClaims where !closure.claimIDs.contains(id) {
                guard let payload = claimPayloads[id],
                      closure.evidenceIDs.contains(where: { payload.contains("\"\($0)\"") }) else { continue }
                closure.claimIDs.insert(id); changed = true
            }
            // Orphan detection needs every claim's support set to be readable. While an unresolved
            // claim payload remains, a source it might depend on cannot be proven orphaned, so the
            // rule stands down rather than erasing evidence another claim may still need.
            if opaqueClaims.isSubset(of: closure.claimIDs) {
                let survivors = Set(claims.filter { !closure.claimIDs.contains($0.key) }.values.flatMap(\.evidenceIDs))
                let purged = Set(claims.filter { closure.claimIDs.contains($0.key) }.values.flatMap(\.evidenceIDs))
                for id in purged.subtracting(survivors) where !closure.evidenceIDs.contains(id) {
                    closure.evidenceIDs.insert(id); changed = true
                }
            }
            // Content backstop over source rows: an overlapping body is the same withdrawn text.
            let texts = distinctiveTexts(closure.evidenceIDs.compactMap { evidence[$0]?.text })
            guard !texts.isEmpty else { continue }
            for (id, item) in evidence where !closure.evidenceIDs.contains(id) {
                guard let text = item.text, contains(Self.normalizedContent(text), texts) else { continue }
                closure.evidenceIDs.insert(id); changed = true
            }
            for (id, payload) in opaqueEvidence where !closure.evidenceIDs.contains(id) {
                guard contains(Self.normalizedContent(payload), texts) else { continue }
                closure.evidenceIDs.insert(id); changed = true
            }
            // A claim payload holds the asserted value verbatim, decodable or not.
            for (id, payload) in claimPayloads where !closure.claimIDs.contains(id) {
                guard contains(Self.normalizedContent(payload), texts) else { continue }
                closure.claimIDs.insert(id); changed = true
            }
        }
        closure.rootEvidenceIDs = Set(closure.evidenceIDs.filter { evidence[$0]?.sourceKind != .derived })
        let sourceTexts = distinctiveTexts(closure.evidenceIDs.compactMap { evidence[$0]?.text })
        closure.withdrawnTexts = sourceTexts

        // Raw turns. A whole thread goes when the thread itself is withdrawn; otherwise a turn is
        // withdrawn when it carries a withdrawn evidence body, in whichever thread it sits. An
        // evidence body IS the sanitized source content, so such a turn is that same content in
        // its other home, and leaving it would let `/v1/transcript/range` serve it verbatim and
        // let a later consolidation pass mint a fresh node from it.
        var purgedSeqs = [String: Set<Int>]()
        var transcriptThreads = [String: String]()
        for row in try TranscriptRow.fetchAll(db) {
            transcriptThreads[row.id] = row.threadId
            let withdrawnThread = closure.purgeEverything || closure.threadIDs.contains(row.threadId)
            let carriesSource = contains(Self.normalizedContent(row.text), sourceTexts)
            guard withdrawnThread || carriesSource else { continue }
            closure.transcriptIDs.insert(row.id)
            purgedSeqs[row.threadId, default: []].insert(row.seq)
        }

        if closure.purgeEverything {
            closure.nodeIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM node"))
            return closure
        }
        try requireGrant(closure, evidence: evidence, claims: claims, transcriptThreads: transcriptThreads)

        // Legacy graph, by recorded provenance: managed projections and bindings of withdrawn
        // claims, rows whose recorded source is withdrawn, the node a withdrawn subject *is*,
        // and summaries over withdrawn turns.
        for claimID in closure.claimIDs {
            closure.nodeIDs.formUnion(try String.fetchAll(db, sql: "SELECT node_id FROM brain_projection WHERE claim_id=?", arguments: [claimID]))
            closure.nodeIDs.formUnion(try String.fetchAll(db, sql: "SELECT node_id FROM brain_legacy_binding WHERE claim_id=?", arguments: [claimID]))
        }
        for subject in closure.subjectIDs {
            closure.nodeIDs.formUnion(try String.fetchAll(db, sql: "SELECT node_id FROM brain_legacy_binding WHERE subject=?", arguments: [subject]))
        }
        let withdrawnSources = closure.evidenceIDs.union(closure.threadIDs)
        let nodes = try Node.fetchAll(db)
        for node in nodes where !closure.nodeIDs.contains(node.id) {
            if let sourceRef = node.sourceRef, withdrawnSources.contains(sourceRef) {
                closure.nodeIDs.insert(node.id); continue
            }
            // The subject grant already bounds this: a scope can only name a held subject.
            if closure.subjectIDs.contains(node.id) || declaresSubject(node, in: closure.subjectIDs) {
                closure.nodeIDs.insert(node.id); continue
            }
            if node.kind == NodeKind.summary.rawValue, summaryCovers(node, purgedSeqs: purgedSeqs, threads: closure.threadIDs) {
                closure.nodeIDs.insert(node.id)
            }
        }

        // Content-similarity backstop, bounded to the grant. Unlike provenance, a verbatim overlap
        // is only evidence that a row *may* hold the withdrawn text, so it never reaches a row that
        // declares a thread or a subject the principal does not hold.
        closure.withdrawnTexts.formUnion(distinctiveTexts(
            closure.transcriptIDs.compactMap { id in try? String.fetchOne(db, sql: "SELECT text FROM transcript WHERE id=?", arguments: [id]) }.compactMap { $0 }))
        let knownThreads = Set(transcriptThreads.values)
        for node in nodes where !closure.nodeIDs.contains(node.id) {
            guard !attributedOutsideGrant(node, knownThreads: knownThreads),
                  contains(Self.normalizedContent(node.label + " " + node.body), closure.withdrawnTexts) else { continue }
            closure.nodeIDs.insert(node.id)
        }

        // A conclusion that loses any of its grounding is no longer supported by what remains.
        let derived = try Edge.filter(Column("relation") == Relation.derivesFrom.rawValue).fetchAll(db)
        changed = true
        while changed {
            changed = false
            for edge in derived where !closure.nodeIDs.contains(edge.srcId) && closure.nodeIDs.contains(edge.dstId) {
                closure.nodeIDs.insert(edge.srcId); changed = true
            }
        }
        return closure
    }

    private func distinctiveTexts(_ texts: [String]) -> Set<String> {
        Set(texts.map(Self.normalizedContent).filter { $0.count >= Self.minimumDistinctiveTextLength })
    }

    private func contains(_ candidate: String, _ texts: Set<String>) -> Bool {
        texts.contains { candidate.contains($0) }
    }

    private func declaresSubject(_ node: Node, in subjects: Set<String>) -> Bool {
        guard !subjects.isEmpty else { return false }
        return subjectsDeclared(by: node).contains { subjects.contains($0) }
    }

    private func subjectsDeclared(by node: Node) -> Set<String> {
        guard let data = node.extra?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(["subject", "subjectId", "subjectID"].compactMap { object[$0] as? String })
    }

    /// True when the row names a thread or a subject the principal does not hold. A row with no
    /// declared attribution is unattributed, not foreign, and stays reachable by the backstop.
    private func attributedOutsideGrant(_ node: Node, knownThreads: Set<String>) -> Bool {
        let subjects = subjectsDeclared(by: node)
        if !subjects.isEmpty, !subjects.isSubset(of: authorization.subjects) { return true }
        if let sourceRef = node.sourceRef, knownThreads.contains(sourceRef),
           !authorization.threads.contains(sourceRef) { return true }
        if let thread = summaryThread(node), !authorization.threads.contains(thread) { return true }
        return false
    }

    private func summaryThread(_ node: Node) -> String? {
        guard node.kind == NodeKind.summary.rawValue, let data = node.extra?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["threadId"] as? String
    }

    private func summaryCovers(_ node: Node, purgedSeqs: [String: Set<Int>], threads: Set<String>) -> Bool {
        guard let data = node.extra?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thread = object["threadId"] as? String else { return false }
        if threads.contains(thread) { return true }
        guard let range = object["turnRange"] as? [Int], range.count == 2,
              let purged = purgedSeqs[thread] else { return false }
        return purged.contains { $0 >= range[0] && $0 <= range[1] }
    }

    // MARK: Purge

    private func purge(_ closure: BrainRetractionClosure, db: Database, revision: Int64) throws {
        // Markers are fingerprinted from the rows as they stand, before anything is deleted.
        var markers = Set<BrainExclusionMarker>()
        for id in closure.nodeIDs {
            guard let node = try Node.fetchOne(db, key: id), Self.isMarkable(node) else { continue }
            markers.insert(.init(kind: .node, id: id, fingerprint: Self.nodeFingerprint(node)))
        }
        for id in closure.transcriptIDs {
            guard let text = try String.fetchOne(db, sql: "SELECT text FROM transcript WHERE id=?", arguments: [id]) else { continue }
            markers.insert(.init(kind: .transcript, id: id, fingerprint: Self.transcriptFingerprint(text)))
        }
        for id in closure.evidenceIDs {
            guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [id]) else { continue }
            markers.insert(.init(kind: .evidence, id: id, fingerprint: Self.evidenceFingerprint(payload)))
        }
        for id in closure.claimIDs {
            guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id=?", arguments: [id]) else { continue }
            markers.insert(.init(kind: .claim, id: id, fingerprint: Self.claimFingerprint(payload: payload)))
        }

        if closure.purgeEverything {
            // Personal-memory artifacts only. Encrypted connection-service credentials, service
            // and model configuration are not memory and are never erased by a memory scope.
            for table in ["node", "node_fts", "node_embedding", "node_tags", "edge", "transcript",
                          "transcript_embedding", "brain_evidence", "brain_evidence_operations",
                          "brain_claim", "brain_commit", "brain_projection", "brain_legacy_binding",
                          "sleep_cycle"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        } else {
            for id in closure.nodeIDs {
                try db.execute(sql: "DELETE FROM node WHERE id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM node_fts WHERE node_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM node_embedding WHERE node_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM node_tags WHERE node_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM edge WHERE srcId=? OR dstId=?", arguments: [id, id])
                try db.execute(sql: "DELETE FROM brain_projection WHERE node_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM brain_legacy_binding WHERE node_id=?", arguments: [id])
            }
            for id in closure.transcriptIDs {
                try db.execute(sql: "DELETE FROM transcript WHERE id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM transcript_embedding WHERE turn_id=?", arguments: [id])
            }
            for id in closure.evidenceIDs {
                try db.execute(sql: "DELETE FROM brain_evidence WHERE id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM brain_evidence_operations WHERE evidence_id=?", arguments: [id])
            }
            for id in closure.claimIDs {
                try db.execute(sql: "DELETE FROM brain_claim WHERE id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM brain_projection WHERE claim_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM brain_legacy_binding WHERE claim_id=?", arguments: [id])
            }
            try purgeJournals(closure, db: db)
            try scrubSurvivors(closure, db: db)
        }
        for marker in markers {
            try db.execute(sql: "INSERT OR IGNORE INTO brain_exclusion(kind, id, fingerprint, revision, owner) VALUES (?, ?, ?, ?, ?)",
                           arguments: [marker.kind.rawValue, marker.id, marker.fingerprint, revision, authorization.owner])
        }
    }

    /// The operation journals keep the prior bodies of what they wrote, so a row that mentions a
    /// withdrawn source or claim goes with it. Losing a journal entry costs that operation its
    /// replay; keeping the content is not an option.
    private func purgeJournals(_ closure: BrainRetractionClosure, db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT principal, operation, payload, evidence_id FROM brain_evidence_operations") {
            let payload: String = row["payload"]
            var withdrawn = contains(Self.normalizedContent(payload), closure.withdrawnTexts)
            if let item = try? Self.decode(BrainEvidence.self, payload) {
                withdrawn = withdrawn || closure.evidenceIDs.contains(item.id)
                    || !closure.evidenceIDs.isDisjoint(with: item.parentEvidenceIDs ?? [])
            }
            guard withdrawn else { continue }
            try db.execute(sql: "DELETE FROM brain_evidence_operations WHERE principal=? AND operation=?",
                           arguments: [row["principal"] as String, row["operation"] as String])
        }
        for row in try Row.fetchAll(db, sql: "SELECT principal, operation, payload, result FROM brain_commit") {
            let payload: String = row["payload"], result: String = row["result"]
            var withdrawn = contains(Self.normalizedContent(payload + " " + result), closure.withdrawnTexts)
            if let request = try? Self.decode(BrainCommitRequest.self, payload) {
                let evidenceIDs = Set(request.evidence.map(\.id))
                    .union(request.updates.flatMap { $0.claim.evidenceIDs })
                let claimIDs = Set(request.updates.map { $0.claim.id })
                withdrawn = withdrawn || !closure.evidenceIDs.isDisjoint(with: evidenceIDs)
                    || !closure.claimIDs.isDisjoint(with: claimIDs)
            }
            guard withdrawn else { continue }
            try db.execute(sql: "DELETE FROM brain_commit WHERE principal=? AND operation=?",
                           arguments: [row["principal"] as String, row["operation"] as String])
        }
    }

    /// Withdrawn content also hides in rows that survive: the unresolved alternatives a merge
    /// retains in `Node.extra`, an opaque legacy extra, and the consolidation cycle's focus line.
    private func scrubSurvivors(_ closure: BrainRetractionClosure, db: Database) throws {
        guard !closure.withdrawnTexts.isEmpty || !closure.nodeIDs.isEmpty else { return }
        for node in try Node.fetchAll(db) {
            guard let extra = node.extra, let data = extra.data(using: .utf8),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var changed = false
            if let legacy = object["legacyExtra"] as? String,
               contains(Self.normalizedContent(legacy), closure.withdrawnTexts) {
                object.removeValue(forKey: "legacyExtra"); changed = true
            }
            let conflicts = MemoryStore.mergeConflicts(in: node)
            let kept = conflicts.filter { !contains(Self.normalizedContent($0.label + " " + $0.body), closure.withdrawnTexts) }
            if kept.count != conflicts.count {
                changed = true
                if kept.isEmpty { object.removeValue(forKey: "mergeConflicts") }
                else if let encoded = try? JSONEncoder().encode(kept),
                        let values = try? JSONSerialization.jsonObject(with: encoded) {
                    object["mergeConflicts"] = values
                } else { throw BrainStoreError.invalid }
            }
            guard changed else { continue }
            let rewritten = object.isEmpty ? nil : String(
                decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            try db.execute(sql: "UPDATE node SET extra=?, dirty=1 WHERE id=?", arguments: [rewritten, node.id])
        }
        guard let row = try Row.fetchOne(db, sql: "SELECT episodeIds, focus FROM sleep_cycle WHERE id=1") else { return }
        let focus: String = row["focus"] ?? ""
        if contains(Self.normalizedContent(focus), closure.withdrawnTexts) {
            try db.execute(sql: "UPDATE sleep_cycle SET focus='' WHERE id=1")
        }
        let episodeIDs = (try? JSONDecoder().decode([String].self, from: Data((row["episodeIds"] as String).utf8))) ?? []
        let kept = episodeIDs.filter { !closure.nodeIDs.contains($0) }
        if kept.count != episodeIDs.count, let encoded = try? JSONEncoder().encode(kept) {
            try db.execute(sql: "UPDATE sleep_cycle SET episodeIds=? WHERE id=1",
                           arguments: [String(decoding: encoded, as: UTF8.self)])
        }
    }
}
