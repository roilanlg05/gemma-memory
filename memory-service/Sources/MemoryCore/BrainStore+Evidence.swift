import Foundation
import GRDB
import BrainContract

extension BrainStore {
    public func recordEvidence(_ evidence: BrainEvidence, idempotencyKey: String) throws -> BrainEvidence {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrainStoreError.invalid }
        return try store.dbQueue.write { db in
            try checkOwner(db, bind: true)
            try validateEvidence(evidence, db: db)
            let payload = try Self.encode(evidence)
            if let old = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence_operations WHERE principal=? AND operation=?", arguments: [authorization.principal, idempotencyKey]) {
                guard old == payload else { throw BrainStoreError.conflict }
                return evidence
            }
            try insertEvidence(evidence, db: db)
            try db.execute(sql: "INSERT INTO brain_evidence_operations VALUES (?, ?, ?, ?)", arguments: [authorization.principal, idempotencyKey, payload, evidence.id])
            return evidence
        }
    }
    func loadEvidence(_ id: String, db: Database) throws -> BrainEvidence {
        guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [id]) else { throw BrainStoreError.invalid }
        return try Self.decode(BrainEvidence.self, payload)
    }
    func insertEvidence(_ evidence: BrainEvidence, db: Database) throws {
        try validateEvidence(evidence, db: db)
        let payload = try Self.encode(evidence)
        if let old = try String.fetchOne(db, sql: "SELECT payload FROM brain_evidence WHERE id=?", arguments: [evidence.id]) {
            guard old == payload else { throw BrainStoreError.conflict }
        } else {
            try db.execute(sql: "INSERT INTO brain_evidence(id, payload) VALUES (?, ?)", arguments: [evidence.id, payload])
        }
    }
    func validateEvidence(_ evidence: BrainEvidence, db: Database) throws {
        try requirePrincipal()
        guard authorization.scopes.contains(evidence.accessScope), authorization.threads.contains(evidence.threadID),
              authorization.sourceSpeakers[evidence.sourceKind]?.contains(evidence.speakerID) == true else { throw BrainStoreError.denied }
        guard !evidence.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !evidence.threadID.isEmpty, !evidence.speakerID.isEmpty,
              evidence.observedAt.isFinite, evidence.recordedAt.isFinite,
              let text = evidence.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrainStoreError.invalid }
        if let span = evidence.span {
            let bytes = Array(text.utf8)
            guard span.start >= 0, span.end > span.start, span.end <= bytes.count,
                  String(bytes: bytes[span.start..<span.end], encoding: .utf8) != nil else { throw BrainStoreError.invalid }
        }
        let parents = evidence.parentEvidenceIDs ?? []
        guard Set(parents).count == parents.count, !parents.contains(evidence.id) else { throw BrainStoreError.invalid }
        if evidence.sourceKind == .derived {
            guard !parents.isEmpty else { throw BrainStoreError.invalid }
        } else if !parents.isEmpty { throw BrainStoreError.invalid }
        for id in parents {
            let parent = try loadEvidence(id, db: db)
            guard canRead(parent), parent.accessScope == evidence.accessScope,
                  evidence.accessScope != .thread || parent.threadID == evidence.threadID else { throw BrainStoreError.denied }
            _ = try roots(of: parent, db: db, visiting: [evidence.id])
        }
    }
    // Root IDs, not derived summaries, are independent units of support.
    func roots(of evidence: BrainEvidence, db: Database, visiting: Set<String> = []) throws -> Set<String> {
        guard !visiting.contains(evidence.id) else { throw BrainStoreError.invalid }
        if evidence.sourceKind != .derived {
            guard (evidence.parentEvidenceIDs ?? []).isEmpty, evidence.text?.isEmpty == false else { throw BrainStoreError.invalid }
            return [evidence.id]
        }
        let parents = evidence.parentEvidenceIDs ?? []
        guard !parents.isEmpty else { throw BrainStoreError.invalid }
        var path = visiting; path.insert(evidence.id)
        var result = Set<String>()
        for id in parents {
            let parent = try loadEvidence(id, db: db)
            guard parent.accessScope == evidence.accessScope,
                  evidence.accessScope != .thread || parent.threadID == evidence.threadID else { throw BrainStoreError.denied }
            result.formUnion(try roots(of: parent, db: db, visiting: path))
        }
        return result
    }
}
