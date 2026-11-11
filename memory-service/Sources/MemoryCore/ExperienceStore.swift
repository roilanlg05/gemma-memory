import Foundation
import BrainContract
import GRDB

public enum ExperienceAttribution: Sendable { case reported, userConfirmed, independentlyVerified }
public struct RecalledExperience: Sendable {
    public let outcome: BrainOutcome
    public let attribution: ExperienceAttribution
}

/// Host-only authority. Implementations must consult authoritative host execution records bound
/// to the exact outcome/evidence and operation; payload status or tool text alone is not proof.
/// This is injected by trusted code, never decoded from a client or model request.
public protocol ExperienceAuthority {
    func attribution(for outcome: BrainOutcome, evidence: [BrainEvidence]) -> ExperienceAttribution
    func approves(procedure: BrainProcedure, outcomes: [BrainOutcome], evidence: [BrainEvidence], environment: String) -> Bool
}
public struct DenyExperienceAuthority: ExperienceAuthority {
    public init() {}
    public func attribution(for outcome: BrainOutcome, evidence: [BrainEvidence]) -> ExperienceAttribution { .reported }
    public func approves(procedure: BrainProcedure, outcomes: [BrainOutcome], evidence: [BrainEvidence], environment: String) -> Bool { false }
}

/// Reads the canonical turn outcome journal; it never creates a second outcome source.
public final class ExperienceStore {
    let brain: BrainStore
    let authority: any ExperienceAuthority
    public init(store: MemoryStore, authorization: BrainAuthorization, authority: any ExperienceAuthority = DenyExperienceAuthority(), clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.brain = BrainStore(store: store, authorization: authorization, clock: clock); self.authority = authority
    }
    func load(_ id: String, db: Database) throws -> RecalledExperience? {
        let key = try BrainTurnStore.key(id)
        guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_turn_outcome WHERE principal=? AND operation_hash=?", arguments: [brain.authorization.principal, key]) else { return nil }
        let outcome = try BrainStore.decode(BrainOutcome.self, payload)
        let evidence = try brain.availableEvidence(outcome.evidenceIDs, db: db)
        var attribution = authority.attribution(for: outcome, evidence: evidence)
        if attribution == .userConfirmed && !evidence.contains(where: { $0.sourceKind == .userMessage && $0.speakerID == "self:user" }) { attribution = .reported }
        return .init(outcome: outcome, attribution: attribution)
    }
    public func outcome(id: String) throws -> RecalledExperience? {
        try brain.store.dbQueue.read { db in try brain.checkOwner(db, bind: false); return try load(id, db: db) }
    }
}
