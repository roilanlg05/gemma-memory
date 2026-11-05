import Foundation
import GRDB
import BrainContract

extension BrainStore {
    func availableEvidence(_ ids: [String], db: Database) throws -> [BrainEvidence] {
        guard !ids.isEmpty, Set(ids).count == ids.count else { throw BrainStoreError.invalid }
        return try ids.map { id in
            let evidence = try loadEvidence(id, db: db)
            guard canRead(evidence) else { throw BrainStoreError.denied }
            guard !(try roots(of: evidence, db: db)).isEmpty else { throw BrainStoreError.invalid }
            return evidence
        }
    }
    public func commit(_ request: BrainCommitRequest) throws -> BrainCommitResult {
        try requirePrincipal()
        guard authorization.mayCommitClaims else { throw BrainStoreError.denied }
        guard let expected = request.expectedRevision, expected >= 0, request.tastes?.isEmpty != false else { throw BrainStoreError.invalid }
        let payload = try Self.encode(request)
        do {
            return try store.dbQueue.write { db in
            try checkOwner(db, bind: false)
            let current = try Self.revision(db)
            if let row = try Row.fetchOne(db, sql: "SELECT payload, result FROM brain_commit WHERE principal=? AND operation=?", arguments: [authorization.principal, request.clientOperationID]) {
                guard (row["payload"] as String) == payload else {
                    return BrainCommitResult(clientOperationID: request.clientOperationID, state: .pending, revision: current, claimIDs: [], disposition: .conflict)
                }
                for update in request.updates {
                    guard authorization.subjects.contains(update.claim.subject) else { throw BrainStoreError.denied }
                    _ = try availableEvidence(update.claim.evidenceIDs, db: db)
                }
                let old = try Self.decode(BrainCommitResult.self, row["result"] as String)
                return BrainCommitResult(clientOperationID: old.clientOperationID, state: old.state, revision: old.revision, claimIDs: old.claimIDs, disposition: .idempotent)
            }
            guard expected == current else {
                return BrainCommitResult(clientOperationID: request.clientOperationID, state: .pending, revision: current, claimIDs: [], disposition: .conflict)
            }
            guard current < Int64.max else { throw BrainStoreError.invalid }
            try checkOwner(db, bind: true)
            for evidence in request.evidence { try insertEvidence(evidence, db: db) }
            let next = current + 1
            var ids = [String]()
            for update in request.updates {
                let claim = update.claim
                guard authorization.subjects.contains(claim.subject), !claim.subject.isEmpty, !claim.predicate.isEmpty,
                      !claim.id.isEmpty, claim.validFrom.isFinite, claim.recordedAt.isFinite,
                      claim.validTo.map({ $0.isFinite && $0 > claim.validFrom }) ?? true,
                      claim.status == .active, !ids.contains(claim.id) else { throw BrainStoreError.invalid }
                let sources = try availableEvidence(claim.evidenceIDs, db: db)
                guard let scope = sources.first?.accessScope, let thread = sources.first?.threadID,
                      sources.allSatisfy({ $0.accessScope == scope && (scope != .thread || $0.threadID == thread) }) else { throw BrainStoreError.invalid }
                try requireAccess(subject: claim.subject, scope: scope)
                guard Set(claim.contradictsIDs).count == claim.contradictsIDs.count,
                      !claim.contradictsIDs.contains(claim.id) else { throw BrainStoreError.invalid }
                for targetID in claim.contradictsIDs {
                    guard let targetPayload = try String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id=?", arguments: [targetID]) else { throw BrainStoreError.invalid }
                    let target = try Self.decode(BrainClaim.self, targetPayload)
                    guard target.subject == claim.subject else { throw BrainStoreError.denied }
                    let targetSources = try availableEvidence(target.evidenceIDs, db: db)
                    guard targetSources.allSatisfy({ $0.accessScope == scope && (scope != .thread || $0.threadID == thread) }) else { throw BrainStoreError.denied }
                }
                if let previousID = claim.supersedesID {
                    guard let oldPayload = try String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id=?", arguments: [previousID]) else { throw BrainStoreError.invalid }
                    let previous = try Self.decode(BrainClaim.self, oldPayload)
                    let factual: [BrainClaimModality] = [.asserted, .negated]
                    guard !factual.contains(previous.modality) || factual.contains(claim.modality) else { throw BrainStoreError.invalid }
                    let successorPayloads = try String.fetchAll(db, sql: "SELECT payload FROM brain_claim WHERE subject=? AND predicate=?", arguments: [claim.subject, claim.predicate])
                    let successors = try successorPayloads.map { try Self.decode(BrainClaim.self, $0) }
                    guard previous.subject == claim.subject, previous.predicate == claim.predicate,
                          previous.status == .active, claim.validFrom >= previous.validFrom,
                          !successors.contains(where: { $0.supersedesID == previousID }),
                          update.expectedRevision.map({ $0 == previous.revision }) ?? true else { throw BrainStoreError.conflict }
                    let oldSources = try availableEvidence(previous.evidenceIDs, db: db)
                    guard oldSources.allSatisfy({ $0.accessScope == scope && (scope != .thread || $0.threadID == thread) }) else { throw BrainStoreError.denied }
                } else if let expectedClaim = update.expectedRevision, expectedClaim != 0 { throw BrainStoreError.conflict }
                let saved = BrainClaim(id: claim.id, revision: next, subject: claim.subject, predicate: claim.predicate, value: claim.value,
                    modality: claim.modality, status: claim.status, validFrom: claim.validFrom, validTo: claim.validTo,
                    recordedAt: claim.recordedAt, evidenceIDs: claim.evidenceIDs, supersedesID: claim.supersedesID,
                    contradictsIDs: claim.contradictsIDs)
                try db.execute(sql: "INSERT INTO brain_claim(id, subject, predicate, revision, payload) VALUES (?, ?, ?, ?, ?)", arguments: [saved.id, saved.subject, saved.predicate, next, try Self.encode(saved)])
                try project(saved, evidence: sources, db: db)
                ids.append(saved.id)
            }
            // A commit may withdraw its own superseded projection without publishing unrelated rows.
            let affected = Set(ids).union(request.updates.compactMap { $0.claim.supersedesID })
            let mayPublish = authorization.mayProject && authorization.scopes.contains(.user)
            try reconcile(db: db, now: clock(), claimIDs: affected, mayPublish: mayPublish)
            try db.execute(sql: "UPDATE brain_meta SET revision=? WHERE id=1", arguments: [next])
            let result = BrainCommitResult(clientOperationID: request.clientOperationID, state: .committed, revision: next, claimIDs: ids, disposition: .committed)
            try db.execute(sql: "INSERT INTO brain_commit VALUES (?, ?, ?, ?)", arguments: [authorization.principal, request.clientOperationID, payload, try Self.encode(result)])
            return result
            }
        } catch BrainStoreError.conflict {
            // The database write rolled back before returning a typed concurrency conflict.
            return BrainCommitResult(clientOperationID: request.clientOperationID, state: .pending,
                                     revision: try revision(), claimIDs: [], disposition: .conflict)
        }
    }
    /// asOf is event-valid time; knownAtRevision limits knowledge available to the query.
    public func claims(subject: String, asOf: Double, scope: BrainAccessScope, knownAtRevision: Int64? = nil) throws -> [BrainClaim] {
        try requireAccess(subject: subject, scope: scope)
        guard asOf.isFinite, knownAtRevision.map({ $0 >= 0 }) ?? true else { throw BrainStoreError.invalid }
        return try store.dbQueue.read { db in
            try checkOwner(db, bind: false)
            let known: Int64
            if let knownAtRevision { known = knownAtRevision } else { known = try Self.revision(db) }
            let payloads = try String.fetchAll(db, sql: "SELECT payload FROM brain_claim WHERE subject=? AND revision<=? ORDER BY revision, id", arguments: [subject, known])
            var visible = [BrainClaim]()
            for payload in payloads {
                let claim = try Self.decode(BrainClaim.self, payload)
                let sources = try claim.evidenceIDs.map { try loadEvidence($0, db: db) }
                guard sources.allSatisfy({ $0.accessScope == scope && canRead($0) }), claim.validFrom <= asOf else { continue }
                visible.append(claim)
            }
            let superseded = Set(visible.compactMap(\.supersedesID))
            return visible.filter { $0.status == .active && !superseded.contains($0.id) && ($0.validTo.map { asOf < $0 } ?? true) }
        }
    }
}
