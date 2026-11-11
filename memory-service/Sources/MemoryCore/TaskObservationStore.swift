import Foundation
import GRDB
import BrainContract

public enum TaskStatus: String, Codable, Sendable { case pending, proposed, inProgress = "in-progress", blocked, done, cancelled, unknown }
public enum TaskObservationAttribution: String, Sendable { case userReported, external }
public enum TaskObservationDisposition: String, Sendable { case applied, conflict }
public struct TaskObservation: Sendable {
    public let sourceID: String
    public let sourceVersion: Int64
    public let observedAt: Double
    public let status: TaskStatus
    public let evidenceID: String
    public let attribution: TaskObservationAttribution
    public let disposition: TaskObservationDisposition
}
/// Trusted host code binds an observation to this exact task, source, version and evidence.
/// A source kind, user-supplied version, or tool text never grants authority by itself.
public protocol TaskObservationAuthority {
    func approves(id: String, sourceID: String, sourceVersion: Int64, observedAt: Double, status: TaskStatus, evidence: BrainEvidence) -> Bool
    func approvesReopening(id: String, sourceID: String, status: TaskStatus, evidence: BrainEvidence) -> Bool
}
public extension TaskObservationAuthority {
    func approvesReopening(id: String, sourceID: String, status: TaskStatus, evidence: BrainEvidence) -> Bool { false }
}
public struct DenyTaskObservationAuthority: TaskObservationAuthority {
    public init() {}
    public func approves(id: String, sourceID: String, sourceVersion: Int64, observedAt: Double, status: TaskStatus, evidence: BrainEvidence) -> Bool { false }
}
public final class TaskObservationStore {
    let brain: BrainStore
    let authority: any TaskObservationAuthority
    public init(store: MemoryStore, authorization: BrainAuthorization, authority: any TaskObservationAuthority = DenyTaskObservationAuthority()) {
        brain = BrainStore(store: store, authorization: authorization); self.authority = authority
    }
    public func observeTask(id: String, sourceID: String, sourceVersion: Int64, observedAt: Double, status: TaskStatus, evidenceID: String, operationID: String) throws {
        guard brain.authorization.principal == brain.authorization.owner, !id.isEmpty, !sourceID.isEmpty, !operationID.isEmpty, sourceVersion >= 0, observedAt.isFinite, brain.authorization.mayCommitClaims, brain.authorization.scopes.contains(.user), brain.authorization.subjects.contains("self:user") else { throw BrainStoreError.invalid }
        try brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: true)
            let evidence = try brain.availableEvidence([evidenceID], db: db)[0]
            guard evidence.accessScope == .user, evidence.observedAt == observedAt, authority.approves(id: id, sourceID: sourceID, sourceVersion: sourceVersion, observedAt: observedAt, status: status, evidence: evidence) else { throw BrainStoreError.denied }
            guard var node = try Node.fetchOne(db, key: id), !node.deleted, node.kind == NodeKind.task.rawValue else { throw BrainStoreError.invalid }
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM task_observation WHERE principal=? AND operation=?", arguments: [brain.authorization.principal, operationID]) {
                guard (row["task_id"] as String) == id, (row["source_id"] as String) == sourceID, (row["source_version"] as Int64) == sourceVersion, (row["observed_at"] as Double) == observedAt, (row["status"] as String) == status.rawValue, (row["evidence_id"] as String) == evidenceID else { throw BrainStoreError.conflict }
                return
            }
            let previous = try Row.fetchOne(db, sql: "SELECT source_version FROM task_observation WHERE principal=? AND task_id=? AND source_id=? ORDER BY source_version DESC LIMIT 1", arguments: [brain.authorization.principal, id, sourceID])
            let lastRow = try Row.fetchOne(db, sql: "SELECT observed_at,source_id FROM task_observation WHERE principal=? AND task_id=? AND disposition='applied' ORDER BY observed_at DESC,rowid DESC LIMIT 1", arguments: [brain.authorization.principal, id])
            let lastApplied: Double? = lastRow?["observed_at"]
            let lastSource: String? = lastRow?["source_id"]
            let stale = previous.map { sourceVersion <= ($0["source_version"] as Int64) } ?? false
            let oldStatus = NodeAttributes.from(node.extra).status ?? "pending"
            let terminal = ["done", "cancelled"].contains(oldStatus)
            // Reopening a terminal record requires a separate, explicit correction protocol.
            let conflict = stale || (lastApplied.map { observedAt <= $0 } ?? false) || (terminal && status.rawValue != oldStatus && !authority.approvesReopening(id: id, sourceID: sourceID, status: status, evidence: evidence))
                || (attributionIsExternal(evidence) && lastSource != nil && lastSource != sourceID && status.rawValue != oldStatus)
            let attribution: TaskObservationAttribution = evidence.sourceKind == .userMessage && evidence.speakerID == "self:user" ? .userReported : .external
            try db.execute(sql: "INSERT INTO task_observation VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [brain.authorization.principal, operationID, id, sourceID, sourceVersion, observedAt, status.rawValue, evidenceID, attribution.rawValue, conflict ? "conflict" : "applied"])
            try BrainStore.advanceRevision(db)
            if !conflict {
                node.extra = NodeAttributes.settingStatus(status.rawValue, in: node.extra); node.updatedAt = Date().timeIntervalSince1970; node.dirty = true
                try node.update(db)
            }
        }
    }
    private func attributionIsExternal(_ evidence: BrainEvidence) -> Bool {
        evidence.sourceKind != .userMessage || evidence.speakerID != "self:user"
    }
    public func history(id: String) throws -> [TaskObservation] {
        guard brain.authorization.principal == brain.authorization.owner, brain.authorization.scopes.contains(.user), brain.authorization.subjects.contains("self:user") else { throw BrainStoreError.denied }
        return try brain.store.dbQueue.read { db in
            try brain.checkOwner(db, bind: false)
            let rows = try Row.fetchAll(db, sql: "SELECT source_id, source_version, observed_at, status, attribution, disposition, evidence_id FROM task_observation WHERE principal=? AND task_id=? ORDER BY rowid", arguments: [brain.authorization.principal, id])
            return try rows.compactMap { row in
                let evidenceID: String = row["evidence_id"]
                guard (try? brain.availableEvidence([evidenceID], db: db)) != nil,
                      let attribution = TaskObservationAttribution(rawValue: row["attribution"]), let disposition = TaskObservationDisposition(rawValue: row["disposition"]) else { return nil }
                guard let status = TaskStatus(rawValue: row["status"]) else { return nil }
                return TaskObservation(sourceID: row["source_id"], sourceVersion: row["source_version"], observedAt: row["observed_at"], status: status, evidenceID: evidenceID, attribution: attribution, disposition: disposition)
            }
        }
    }
}
