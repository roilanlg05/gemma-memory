import Foundation
import BrainContract
import GRDB

extension ProcedureLibrary {
    /// Validation requires an exact host attestation and independently verified outcome support.
    public func validateProcedure(id: String, version: Int, verificationEvidenceIDs: [String], environment: String) throws {
        guard !environment.isEmpty, environment.utf8.count <= 256, !verificationEvidenceIDs.isEmpty else { throw BrainStoreError.invalid }
        let brain = experience.brain
        try brain.store.dbQueue.write { db in
            try brain.checkOwner(db, bind: false)
            guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_procedure_version WHERE principal=? AND id=? AND version=?", arguments: [brain.authorization.principal, id, version]) else { throw BrainStoreError.denied }
            let procedure = try BrainStore.decode(BrainProcedure.self, payload)
            guard !procedure.steps.isEmpty, !procedure.preconditions.isEmpty, !procedure.failureModes.isEmpty else { throw BrainStoreError.denied }
            let items = try procedure.outcomeIDs.compactMap { try experience.load($0, db: db) }
            guard items.count == procedure.outcomeIDs.count, items.allSatisfy({ $0.attribution == .independentlyVerified && $0.outcome.observation != nil && $0.outcome.recordedAt <= brain.clock() }), items.contains(where: { $0.outcome.status == .succeeded }), items.allSatisfy({ item in
                guard item.outcome.status == .succeeded, let status = item.outcome.observation?.httpStatus else { return true }
                return status < 400
            }) else { throw BrainStoreError.denied }
            let evidence = try brain.availableEvidence(verificationEvidenceIDs, asOf: brain.clock(), db: db)
            _ = try brain.availableEvidence(procedure.evidenceIDs, asOf: brain.clock(), db: db)
            guard experience.authority.approves(procedure: procedure, outcomes: items.map(\.outcome), evidence: evidence, environment: environment) else { throw BrainStoreError.denied }
            let fingerprint = BrainStore.digest(environment)
            let previous = try Row.fetchOne(db, sql: "SELECT validated_at FROM brain_procedure_attestation WHERE principal=? AND id=? AND version=? AND environment=?", arguments: [brain.authorization.principal, id, version, fingerprint])
            if previous != nil {
                let savedRefs = Set(try String.fetchAll(db, sql: "SELECT evidence_id FROM brain_procedure_attestation_ref WHERE principal=? AND id=? AND version=? AND environment=?", arguments: [brain.authorization.principal, id, version, fingerprint]))
                guard savedRefs == Set(verificationEvidenceIDs) else { throw BrainStoreError.conflict }
                return
            }
            try db.execute(sql: "INSERT INTO brain_procedure_attestation VALUES (?,?,?,?,?)", arguments: [brain.authorization.principal, id, version, fingerprint, brain.clock()])
            for ref in verificationEvidenceIDs {
                try db.execute(sql: "INSERT INTO brain_procedure_attestation_ref VALUES (?,?,?,?,?)", arguments: [brain.authorization.principal, id, version, fingerprint, ref])
            }
        }
    }
}
