import Foundation
import GRDB
import BrainContract

/// Identifier classes carried by persistent exclusion markers. Markers hold identifiers only —
/// never withdrawn content — so a restore from a stale backup can be scrubbed by id without the
/// store retaining what it erased. Only row identifiers are marked: the scope a retraction named
/// is recorded in `brain_forget_operations`, and marking a whole thread or subject would also
/// sweep up turns recorded after that decision.
enum BrainExclusionKind: String, CaseIterable {
    case evidence, claim, node, transcript
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

    var identifiers: [(BrainExclusionKind, Set<String>)] {
        [(.evidence, evidenceIDs), (.claim, claimIDs), (.node, nodeIDs), (.transcript, transcriptIDs)]
    }
}

extension BrainStore {
    /// Content matching is a backstop for derived rows that carry no provenance link (most
    /// consolidation output has a nil `sourceRef`). A short fragment is not distinctive enough to
    /// attribute to the withdrawn source, so only normalized texts of at least this length take
    /// part in it. Rows reachable through recorded provenance are purged regardless of length.
    static let minimumDistinctiveTextLength = 12

    static func normalizedContent(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func isExcluded(_ db: Database, kind: BrainExclusionKind, id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM brain_exclusion WHERE kind=? AND id=?)",
                          arguments: [kind.rawValue, id]) ?? false
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

    /// Re-applies exclusion markers so a restored or re-synced store cannot serve withdrawn rows.
    /// Purges strictly by recorded identifier: every row an earlier retraction removed carries a
    /// marker, so a thread is never re-swept in bulk and turns recorded after that decision
    /// survive. No revision is minted: this re-applies an earlier decision, it does not make one.
    func applyExclusions(_ receipts: [BrainForgetReceipt]) throws {
        try requirePrincipal()
        guard authorization.mayForget, authorization.scopes.contains(.user) else { throw BrainStoreError.denied }
        try store.dbQueue.write { db in
            try checkOwner(db, bind: false)
            var closure = BrainRetractionClosure()
            for row in try Row.fetchAll(db, sql: "SELECT kind, id FROM brain_exclusion") {
                let id: String = row["id"]
                switch BrainExclusionKind(rawValue: row["kind"]) {
                case .evidence: closure.evidenceIDs.insert(id)
                case .claim: closure.claimIDs.insert(id)
                case .node: closure.nodeIDs.insert(id)
                case .transcript: closure.transcriptIDs.insert(id)
                case nil: continue
                }
            }
            // A restore can also lose the marker table itself, so trust the caller's receipts for
            // identifiers, never for content: an affected id is matched against both tables.
            for receipt in receipts {
                closure.evidenceIDs.formUnion(receipt.forgottenEvidenceIDs)
                closure.evidenceIDs.formUnion(receipt.sourceEvidenceIDs ?? [])
                closure.claimIDs.formUnion(receipt.forgottenClaimIDs)
                for id in receipt.affectedIDs ?? [] {
                    let isTranscript = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM transcript WHERE id=?)", arguments: [id]) ?? false
                    if isTranscript { closure.transcriptIDs.insert(id) } else { closure.nodeIDs.insert(id) }
                }
            }
            let revision = try Self.revision(db)
            try purge(closure, db: db, revision: revision)
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
        for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM brain_claim") {
            if let decoded = try? Self.decode(BrainClaim.self, row["payload"] as String) { claims[row["id"] as String] = decoded }
        }

        switch kind {
        case .all:
            closure.purgeEverything = true
            closure.evidenceIDs = Set(evidence.keys).union(opaqueEvidence.keys)
            closure.claimIDs = Set(claims.keys)
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

        // Dependency fixpoint. Derived observations rooted in a withdrawn source go with it, a
        // claim that loses any of its sources can no longer be verified, and a source kept alive
        // only by purged claims is orphaned. Each round can feed the next.
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
            let supportingSurvivors = Set(claims.filter { !closure.claimIDs.contains($0.key) }.values.flatMap(\.evidenceIDs))
            let supportingPurged = Set(claims.filter { closure.claimIDs.contains($0.key) }.values.flatMap(\.evidenceIDs))
            for id in supportingPurged.subtracting(supportingSurvivors) where !closure.evidenceIDs.contains(id) {
                closure.evidenceIDs.insert(id); changed = true
            }
            // Content backstop over source rows: an overlapping body is the same withdrawn text.
            let texts = distinctiveTexts(closure.evidenceIDs.compactMap { evidence[$0]?.text })
            if !texts.isEmpty {
                for (id, item) in evidence where !closure.evidenceIDs.contains(id) {
                    guard let text = item.text, contains(Self.normalizedContent(text), texts) else { continue }
                    closure.evidenceIDs.insert(id); changed = true
                }
                for (id, payload) in opaqueEvidence where !closure.evidenceIDs.contains(id) {
                    guard contains(Self.normalizedContent(payload), texts) else { continue }
                    closure.evidenceIDs.insert(id); changed = true
                }
            }
        }
        closure.rootEvidenceIDs = Set(closure.evidenceIDs.filter { evidence[$0]?.sourceKind != .derived })
        closure.withdrawnTexts = distinctiveTexts(closure.evidenceIDs.compactMap { evidence[$0]?.text })

        // Raw turns: the whole thread when the thread is withdrawn, otherwise the turns of the
        // withdrawn source's own thread that reproduce its text. An evidence body IS the sanitized
        // source content, so a turn carrying it is the same content in its other home.
        var purgedSeqs = [String: Set<Int>]()
        let sourceThreads = Set(closure.evidenceIDs.compactMap { evidence[$0]?.threadID })
        for row in try TranscriptRow.fetchAll(db) {
            let withdrawnThread = closure.purgeEverything || closure.threadIDs.contains(row.threadId)
            let reproducesSource = sourceThreads.contains(row.threadId)
                && contains(Self.normalizedContent(row.text), closure.withdrawnTexts)
            guard withdrawnThread || reproducesSource else { continue }
            closure.transcriptIDs.insert(row.id)
            purgedSeqs[row.threadId, default: []].insert(row.seq)
            closure.withdrawnTexts.formUnion(distinctiveTexts([row.text]))
        }

        if closure.purgeEverything {
            closure.nodeIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM node"))
            return closure
        }

        // Legacy graph: managed projections and bindings of withdrawn claims, rows whose recorded
        // source is withdrawn, summaries over withdrawn turns, nodes a withdrawn subject owns, and
        // — for the derived rows consolidation writes without provenance — verbatim content.
        for claimID in closure.claimIDs {
            closure.nodeIDs.formUnion(try String.fetchAll(db, sql: "SELECT node_id FROM brain_projection WHERE claim_id=?", arguments: [claimID]))
            closure.nodeIDs.formUnion(try String.fetchAll(db, sql: "SELECT node_id FROM brain_legacy_binding WHERE claim_id=?", arguments: [claimID]))
        }
        for subject in closure.subjectIDs {
            closure.nodeIDs.formUnion(try String.fetchAll(db, sql: "SELECT node_id FROM brain_legacy_binding WHERE subject=?", arguments: [subject]))
        }
        let withdrawnSources = closure.evidenceIDs.union(closure.threadIDs)
        for node in try Node.fetchAll(db) where !closure.nodeIDs.contains(node.id) {
            if let sourceRef = node.sourceRef, withdrawnSources.contains(sourceRef) {
                closure.nodeIDs.insert(node.id); continue
            }
            if closure.subjectIDs.contains(node.id) || declaresSubject(node, in: closure.subjectIDs) {
                closure.nodeIDs.insert(node.id); continue
            }
            if node.kind == NodeKind.summary.rawValue, summaryCovers(node, purgedSeqs: purgedSeqs, threads: closure.threadIDs) {
                closure.nodeIDs.insert(node.id); continue
            }
            if contains(Self.normalizedContent(node.label + " " + node.body), closure.withdrawnTexts) {
                closure.nodeIDs.insert(node.id)
            }
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
        guard !subjects.isEmpty, let data = node.extra?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return ["subject", "subjectId", "subjectID"].contains { key in
            (object[key] as? String).map { subjects.contains($0) } ?? false
        }
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
        for (kind, ids) in closure.identifiers {
            for id in ids {
                try db.execute(sql: "INSERT OR IGNORE INTO brain_exclusion(kind, id, revision, owner) VALUES (?, ?, ?, ?)",
                               arguments: [kind.rawValue, id, revision, authorization.owner])
            }
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
