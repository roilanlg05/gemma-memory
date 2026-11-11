import Foundation
import GRDB
import BrainContract

public enum ProspectiveDeliveryState: String, Sendable { case sent, read, failed }
public protocol ProspectiveResolutionAuthority {
    func approves(candidateID: String, evidence: BrainEvidence) -> Bool
}
public struct DenyProspectiveResolutionAuthority: ProspectiveResolutionAuthority {
    public init() {}
    public func approves(candidateID: String, evidence: BrainEvidence) -> Bool { false }
}
/// Read-only proposals, separate follow-up state and receipts. This store never sends anything.
public final class ProspectiveMemoryStore {
    let brain: BrainStore
    let resolutionAuthority: any ProspectiveResolutionAuthority
    public init(store: MemoryStore, authorization: BrainAuthorization, resolutionAuthority: any ProspectiveResolutionAuthority = DenyProspectiveResolutionAuthority(), clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        brain = BrainStore(store: store, authorization: authorization, clock: clock); self.resolutionAuthority = resolutionAuthority
    }
    private func eligible(_ node: Node) -> Bool {
        guard !node.deleted, node.origin == .explicit else { return false }
        let status = NodeAttributes.from(node.extra).status ?? "pending"
        if node.kind == NodeKind.task.rawValue { return ["pending", "proposed", "in-progress", "blocked"].contains(status) }
        return [NodeKind.followUp.rawValue, NodeKind.clarification.rawValue].contains(node.kind) && status == "pending"
    }
    private struct CandidateProof: Encodable {
        let node: String
        let operation: String?
        let sourceID: String?
        let sourceVersion: Int64?
        let evidenceID: String?
        let evidenceFingerprint: String?
    }
    /// Both candidate reads and receipt writes bind the same live source and proof.
    private func proof(_ node: Node, db: Database) throws -> (snapshot: String, evidenceIDs: [String]) {
        let row = try Row.fetchOne(db, sql: "SELECT operation,source_id,source_version,evidence_id FROM task_observation WHERE principal=? AND task_id=? AND disposition='applied' ORDER BY observed_at DESC,rowid DESC LIMIT 1", arguments: [brain.authorization.principal, node.id])
        let evidenceID: String? = row?["evidence_id"]
        var accessibleEvidence: BrainEvidence?
        if let evidenceID, let evidence = try? brain.availableEvidence([evidenceID], db: db).first, evidence.accessScope == .user {
            accessibleEvidence = evidence
        }
        let fingerprint = try accessibleEvidence.map { BrainStore.digest(try BrainStore.encode($0)) }
        let value = CandidateProof(node: MemoryStore.prospectiveFingerprint(node) ?? "", operation: row?["operation"], sourceID: row?["source_id"], sourceVersion: row?["source_version"], evidenceID: evidenceID, evidenceFingerprint: fingerprint)
        return (BrainStore.digest(try BrainStore.encode(value)), accessibleEvidence.map { [$0.id] } ?? [])
    }
    public func candidates(scope: BrainAccessScope, revision: Int64) throws -> [BrainProspectiveCandidate] {
        guard brain.authorization.principal == brain.authorization.owner, scope == .user, brain.authorization.scopes.contains(scope), brain.authorization.subjects.contains("self:user") else { throw BrainStoreError.denied }
        return try brain.store.dbQueue.read { db in
            try brain.checkOwner(db, bind: false)
            guard try BrainStore.revision(db) == revision else { throw BrainStoreError.conflict }
            let nodes = try Node.filter(Column("deleted") == false).fetchAll(db)
            return try nodes.filter { node in
                guard eligible(node) else { return false }
                let row = try Row.fetchOne(db, sql: "SELECT deferred_until, resolution_evidence FROM prospective_state WHERE principal=? AND candidate_id=?", arguments: [brain.authorization.principal, node.id])
                if let evidence: String = row?["resolution_evidence"], (try? brain.availableEvidence([evidence], db: db)) != nil { return false }
                if let until: Double = row?["deferred_until"], until > brain.clock() { return false }
                return true
            }.map { node in
                let source = try proof(node, db: db)
                let kind = node.kind == NodeKind.clarification.rawValue ? "doubt" : (NodeAttributes.from(node.extra).status == "proposed" ? "proposal" : "task")
                return BrainProspectiveCandidate(id: node.id, description: node.label, evidenceIDs: source.evidenceIDs, kind: kind, sourceRevision: source.snapshot, expiresAt: node.ttlExpiresAt)
            }.filter { $0.expiresAt.map { $0 > brain.clock() } ?? true }.sorted { $0.id < $1.id }
        }
    }
    public func revalidate(_ candidate: BrainProspectiveCandidate, scope: BrainAccessScope, revision: Int64) throws -> Bool {
        try candidates(scope: scope, revision: revision).contains { $0.id == candidate.id && $0.sourceRevision == candidate.sourceRevision }
    }
    public func deferFollowUp(id: String, until: Double) throws {
        guard brain.authorization.principal == brain.authorization.owner, until.isFinite, brain.authorization.mayCommitClaims, brain.authorization.subjects.contains("self:user") else { throw BrainStoreError.invalid }
        try brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: true)
            guard let node = try Node.fetchOne(db, key: id), eligible(node), brain.authorization.scopes.contains(.user) else { throw BrainStoreError.denied }
            let previous = try Double.fetchOne(db, sql: "SELECT deferred_until FROM prospective_state WHERE principal=? AND candidate_id=?", arguments: [brain.authorization.principal, id])
            if previous == until { return }
            try BrainStore.advanceRevision(db)
            try db.execute(sql: "INSERT INTO prospective_state(principal,candidate_id,deferred_until) VALUES (?,?,?) ON CONFLICT(principal,candidate_id) DO UPDATE SET deferred_until=excluded.deferred_until", arguments: [brain.authorization.principal, id, until])
        }
    }
    public func resolveCandidate(id: String, evidenceID: String) throws {
        try brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: true)
            guard brain.authorization.principal == brain.authorization.owner, brain.authorization.subjects.contains("self:user"), let node = try Node.fetchOne(db, key: id), eligible(node), node.kind != NodeKind.task.rawValue else { throw BrainStoreError.denied }
            let evidence = try brain.availableEvidence([evidenceID], db: db)[0]
            guard evidence.sourceKind == .userMessage, evidence.speakerID == "self:user", brain.authorization.mayCommitClaims, resolutionAuthority.approves(candidateID: id, evidence: evidence) else { throw BrainStoreError.denied }
            let previous = try String.fetchOne(db, sql: "SELECT resolution_evidence FROM prospective_state WHERE principal=? AND candidate_id=?", arguments: [brain.authorization.principal, id])
            if previous == evidenceID { return }
            try BrainStore.advanceRevision(db)
            try db.execute(sql: "INSERT INTO prospective_state(principal,candidate_id,resolution_evidence) VALUES (?,?,?) ON CONFLICT(principal,candidate_id) DO UPDATE SET resolution_evidence=excluded.resolution_evidence", arguments: [brain.authorization.principal, id, evidenceID])
        }
    }
    public func recordDelivery(id: String, deliveryID: String, state: ProspectiveDeliveryState) throws {
        try recordDelivery(id: id, expectedSnapshot: nil, deliveryID: deliveryID, state: state)
    }
    /// For a new delivery, bind the receipt to the exact candidate that the coordinator read.
    public func recordDelivery(candidate: BrainProspectiveCandidate, deliveryID: String, state: ProspectiveDeliveryState) throws {
        guard let snapshot = candidate.sourceRevision else { throw BrainStoreError.invalid }
        try recordDelivery(id: candidate.id, expectedSnapshot: snapshot, deliveryID: deliveryID, state: state)
    }
    private func recordDelivery(id: String, expectedSnapshot: String?, deliveryID: String, state: ProspectiveDeliveryState) throws {
        guard brain.authorization.principal == brain.authorization.owner, !deliveryID.isEmpty, brain.authorization.scopes.contains(.user), brain.authorization.subjects.contains("self:user"), brain.authorization.mayCommitClaims else { throw BrainStoreError.denied }
        try brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: true)
            let prior = try String.fetchOne(db, sql: "SELECT state FROM prospective_delivery WHERE principal=? AND candidate_id=? AND delivery_id=?", arguments: [brain.authorization.principal, id, deliveryID])
            if prior == nil {
                guard let node = try Node.fetchOne(db, key: id), eligible(node), node.ttlExpiresAt.map({ $0 > brain.clock() }) ?? true else { throw BrainStoreError.conflict }
                if let expectedSnapshot, try proof(node, db: db).snapshot != expectedSnapshot { throw BrainStoreError.conflict }
                let stateRow = try Row.fetchOne(db, sql: "SELECT deferred_until,resolution_evidence FROM prospective_state WHERE principal=? AND candidate_id=?", arguments: [brain.authorization.principal,id])
                if let until: Double = stateRow?["deferred_until"], until > brain.clock() { throw BrainStoreError.conflict }
                if let evidence: String = stateRow?["resolution_evidence"], (try? brain.availableEvidence([evidence], db: db)) != nil { throw BrainStoreError.conflict }
            }
            if let prior {
                if prior == state.rawValue { return }
                guard prior == "sent" && state == .read else { throw BrainStoreError.conflict }
            }
            try db.execute(sql: "INSERT INTO prospective_delivery VALUES (?,?,?,?) ON CONFLICT(principal,candidate_id,delivery_id) DO UPDATE SET state=excluded.state", arguments: [brain.authorization.principal,id,deliveryID,state.rawValue])
        }
    }
}
