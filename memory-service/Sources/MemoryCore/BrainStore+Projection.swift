import Foundation
import GRDB
import BrainContract

extension BrainStore {
    // The coordinator calls this before serving current legacy views. No scheduler is implied.
    public func reconcileProjections(now: Double) throws {
        try requirePrincipal()
        guard authorization.mayProject, authorization.scopes.contains(.user), now.isFinite else { throw BrainStoreError.denied }
        try store.dbQueue.write { db in
            try checkOwner(db, bind: false)
            try reconcile(db: db, now: now, claimIDs: nil, mayPublish: true)
        }
    }
    func project(_ claim: BrainClaim, evidence: [BrainEvidence], db: Database) throws {
        let bindings = authorization.legacyBindings.filter { $0.claimID == claim.id }
        for binding in bindings {
            guard authorization.mayProject, binding.subject == claim.subject, binding.predicate == claim.predicate else { throw BrainStoreError.denied }
        }
        // Global legacy APIs cannot enforce narrower scopes.
        guard authorization.mayProject, evidence.first?.accessScope == .user,
              claim.modality == .asserted, claim.status == .active else {
            guard bindings.isEmpty else { throw BrainStoreError.denied }
            return
        }
        for binding in bindings {
            for id in binding.nodeIDs {
                let managed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM brain_projection WHERE node_id=?)", arguments: [id]) ?? false
                guard !managed else { throw BrainStoreError.denied }
                guard let old = try Node.fetchOne(db, key: id), !old.deleted else { throw BrainStoreError.invalid }
                let object = old.extra.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                func matches(_ keys: [String], _ expected: String) -> Bool {
                    for key in keys where object[key] != nil {
                        guard let value = object[key] as? String, value == expected else { return false }
                    }
                    return true
                }
                guard matches(["subject", "subjectId", "subjectID"], claim.subject),
                      matches(["owner", "ownerId", "ownerID"], authorization.owner) else { throw BrainStoreError.denied }
                if let reserved = ["self:user", "self:agent", "relationship:user:agent"].first(where: { $0 == old.id }), reserved != claim.subject { throw BrainStoreError.denied }
                if let existing = try String.fetchOne(db, sql: "SELECT claim_id FROM brain_legacy_binding WHERE node_id=?", arguments: [id]), existing != claim.id { throw BrainStoreError.conflict }
                try db.execute(sql: "INSERT OR IGNORE INTO brain_legacy_binding(node_id, claim_id, subject, predicate, owner) VALUES (?, ?, ?, ?, ?)", arguments: [id, claim.id, claim.subject, claim.predicate, authorization.owner])
            }
        }
        let nodeID = "brain-claim:" + claim.id
        guard try Node.fetchOne(db, key: nodeID) == nil else { throw BrainStoreError.conflict }
        let body: String
        if case .string(let value) = claim.value { body = value } else { body = try Self.encode(claim.value) }
        let extra = try JSONSerialization.data(withJSONObject: ["claimID": claim.id, "subjectId": claim.subject, "ownerId": authorization.owner, "evidenceIDs": claim.evidenceIDs, "claimRevision": claim.revision], options: [.sortedKeys])
        let node = Node(id: nodeID, kind: NodeKind.fact.rawValue, label: claim.predicate, body: body, layer: .daily,
                        createdAt: claim.recordedAt, updatedAt: claim.recordedAt, lastSeenAt: claim.recordedAt,
                        salience: 1, decayRate: 0, confidence: .maybe, mentionCount: 1, ttlExpiresAt: claim.validTo,
                        sourceRef: claim.evidenceIDs.first, origin: .extracted, serverId: nil, dirty: true, deleted: true,
                        extra: String(decoding: extra, as: UTF8.self))
        try node.insert(db)
        try db.execute(sql: "INSERT INTO brain_projection(node_id, claim_id) VALUES (?, ?)", arguments: [nodeID, claim.id])
    }
    // claimIDs limits commit-time work to that commit. Public reconciliation may
    // publish only subjects and the user scope granted by the trusted context.
    func reconcile(db: Database, now: Double, claimIDs: Set<String>?, mayPublish: Bool) throws {
        guard now.isFinite else { throw BrainStoreError.invalid }
        let payloads = try String.fetchAll(db, sql: "SELECT payload FROM brain_claim")
        let claims = try payloads.map { try Self.decode(BrainClaim.self, $0) }
        let byID = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        let superseded = Set(claims.filter { $0.validFrom <= now }.compactMap(\.supersedesID))
        let rows = try Row.fetchAll(db, sql: "SELECT node_id, claim_id, suppressed FROM brain_projection")
        for row in rows {
            let nodeID: String = row["node_id"]
            let claimID: String = row["claim_id"]
            let suppressed: Bool = row["suppressed"]
            guard let claim = byID[claimID], let node = try Node.fetchOne(db, key: nodeID) else { throw BrainStoreError.invalid }
            guard authorization.subjects.contains(claim.subject), claimIDs.map({ $0.contains(claimID) }) ?? true else { continue }
            let active = !suppressed && claim.validFrom <= now && (claim.validTo.map { now < $0 } ?? true) && !superseded.contains(claimID)
            if active == node.deleted && (mayPublish || !active) {
                try db.execute(sql: "UPDATE node SET deleted=?, dirty=1 WHERE id=?", arguments: [!active, nodeID])
                try db.execute(sql: "DELETE FROM node_fts WHERE node_id=?", arguments: [nodeID])
                if active { try db.execute(sql: "INSERT INTO node_fts(node_id,label,body) VALUES (?,?,?)", arguments: [nodeID, node.label, node.body]) }
            }
            if active && mayPublish {
                let oldIDs = try String.fetchAll(db, sql: "SELECT node_id FROM brain_legacy_binding WHERE claim_id=? AND retired=0", arguments: [claimID])
                for oldID in oldIDs {
                    try db.execute(sql: "UPDATE node SET deleted=1, dirty=1 WHERE id=?", arguments: [oldID])
                    try db.execute(sql: "DELETE FROM node_fts WHERE node_id=?", arguments: [oldID])
                    try db.execute(sql: "UPDATE brain_legacy_binding SET retired=1 WHERE node_id=?", arguments: [oldID])
                }
            }
        }
    }
}
