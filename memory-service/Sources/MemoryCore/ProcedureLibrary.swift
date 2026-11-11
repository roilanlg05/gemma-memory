import Foundation
import BrainContract
import GRDB

public enum ProcedureState: Sendable { case validated, needsRevalidation }
public struct AvailableProcedure: Sendable {
    public let procedure: BrainProcedure
    public let state: ProcedureState
}

/// Proposals are inert descriptions. They do not execute or grant authorization to retry.
public final class ProcedureLibrary {
    let experience: ExperienceStore
    public init(experience: ExperienceStore) { self.experience = experience }
    public func proposeProcedure(sourceOutcomeIDs: [String]) async throws -> BrainProcedure {
        try await propose(id: UUID().uuidString, sourceOutcomeIDs: sourceOutcomeIDs, revising: false)
    }
    /// Creates a distinct immutable proposal version. Earlier validations never apply to it.
    public func reviseProcedure(id: String, sourceOutcomeIDs: [String]) async throws -> BrainProcedure {
        try await propose(id: id, sourceOutcomeIDs: sourceOutcomeIDs, revising: true)
    }
    private func propose(id: String, sourceOutcomeIDs: [String], revising: Bool) async throws -> BrainProcedure {
        guard !sourceOutcomeIDs.isEmpty, Set(sourceOutcomeIDs).count == sourceOutcomeIDs.count else { throw BrainStoreError.invalid }
        let brain = experience.brain
        return try await brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: true)
            let existing = try Int.fetchOne(db, sql: "SELECT MAX(version) FROM brain_procedure_version WHERE principal=? AND id=?", arguments: [brain.authorization.principal, id])
            let previous = try Int.fetchOne(db, sql: "SELECT last_version FROM brain_procedure_sequence WHERE principal=? AND id=?", arguments: [brain.authorization.principal, id])
            guard revising ? existing != nil : previous == nil else { throw BrainStoreError.denied }
            let items = try sourceOutcomeIDs.map { id -> RecalledExperience in
                guard let item = try self.experience.load(id, db: db) else { throw BrainStoreError.denied }; return item
            }
            let evidenceIDs = Array(Set(items.flatMap { $0.outcome.evidenceIDs })).sorted()
            let observations = items.filter { $0.outcome.status == .succeeded }.compactMap { $0.outcome.observation }
            let steps = observations.map { observation in
                switch observation.operation {
                case .httpCheck: return "Perform the recorded HTTP check."
                case .resourceCheck: return "Perform the recorded resource check."
                }
            }
            let label = Set(observations.map(\.operation)).count == 1 && observations.first?.operation == .httpCheck ? "HTTP check" : "Resource check"
            let failures = items.filter { $0.outcome.status != .succeeded && $0.outcome.observation != nil }.map { item in
                "A recorded \(item.outcome.observation!.operation == .httpCheck ? "HTTP" : "resource") check had outcome \(item.outcome.status.rawValue)."
            }
            let procedure = BrainProcedure(id: id, description: steps.isEmpty ? "Recorded check" : label, steps: steps,
                evidenceIDs: evidenceIDs, outcomeIDs: sourceOutcomeIDs, version: (previous ?? 0) + 1,
                preconditions: steps.isEmpty ? [] : ["Authorization and matching environment are required."],
                failureModes: steps.isEmpty ? [] : (failures.isEmpty ? ["A failed or inconclusive check does not establish success."] : failures))
            try db.execute(sql: "INSERT INTO brain_procedure_version(principal,id,version,payload) VALUES (?,?,?,?)", arguments: [brain.authorization.principal, procedure.id, procedure.version, try BrainStore.encode(procedure)])
            try db.execute(sql: "INSERT INTO brain_procedure_sequence(principal,id,last_version) VALUES (?,?,?) ON CONFLICT(principal,id) DO UPDATE SET last_version=excluded.last_version", arguments: [brain.authorization.principal, procedure.id, procedure.version])
            for ref in evidenceIDs { try db.execute(sql: "INSERT INTO brain_procedure_ref VALUES (?,?,?,?)", arguments: [brain.authorization.principal, procedure.id, procedure.version, ref]) }
            return procedure
        }
    }
    public func procedures(for query: String, environment: String, asOf: Double) throws -> [AvailableProcedure] {
        guard asOf.isFinite, !environment.isEmpty else { throw BrainStoreError.invalid }
        let brain = experience.brain
        return try brain.store.dbQueue.read { db in
            try brain.checkOwner(db, bind: false)
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM brain_procedure_version WHERE principal=? ORDER BY id, version DESC", arguments: [brain.authorization.principal])
            var result = [AvailableProcedure]()
            var seen = Set<String>()
            for row in rows {
                let p = try BrainStore.decode(BrainProcedure.self, row["payload"] as String)
                guard !seen.contains(p.id), query.isEmpty || p.description.localizedCaseInsensitiveContains(query) else { continue }
                let refs = try String.fetchAll(db, sql: "SELECT evidence_id FROM brain_procedure_ref WHERE principal=? AND id=? AND version=? ORDER BY evidence_id", arguments: [brain.authorization.principal, p.id, p.version])
                guard (try? brain.availableEvidence(refs, asOf: asOf, db: db)) != nil else { continue }
                let outcomes = try p.outcomeIDs.compactMap { id -> BrainOutcome? in
                    let key = try BrainTurnStore.key(id)
                    guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_turn_outcome WHERE principal=? AND operation_hash=?", arguments: [brain.authorization.principal, key]) else { return nil }
                    return try BrainStore.decode(BrainOutcome.self, payload)
                }
                guard outcomes.count == p.outcomeIDs.count, outcomes.allSatisfy({ $0.recordedAt <= asOf }) else { continue }
                let attestations = try Row.fetchAll(db, sql: "SELECT environment FROM brain_procedure_attestation WHERE principal=? AND id=? AND version=? AND validated_at<=?", arguments: [brain.authorization.principal, p.id, p.version, asOf])
                var available = Set<String>()
                for attestation in attestations {
                    let fingerprint: String = attestation["environment"]
                    let proof = try String.fetchAll(db, sql: "SELECT evidence_id FROM brain_procedure_attestation_ref WHERE principal=? AND id=? AND version=? AND environment=?", arguments: [brain.authorization.principal, p.id, p.version, fingerprint])
                    if (try? brain.availableEvidence(proof, asOf: asOf, db: db)) != nil { available.insert(fingerprint) }
                }
                guard !available.isEmpty else { continue }
                seen.insert(p.id)
                result.append(.init(procedure: p, state: available.contains(BrainStore.digest(environment)) ? .validated : .needsRevalidation))
            }
            return result
        }
    }
}
