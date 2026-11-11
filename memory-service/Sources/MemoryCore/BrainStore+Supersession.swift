import Foundation
import GRDB
import BrainContract

extension BrainStore {
    /// Identity of this assertion, not just its reusable database ID. Revision is excluded
    /// so a restored assertion still matches; modality and its temporal identity are included
    /// so a later assertion under the same ID is not treated as the withdrawn predecessor.
    static func supersessionFingerprint(_ claim: BrainClaim) -> String {
        digest(claimFingerprint(subject: claim.subject, predicate: claim.predicate, value: claim.value)
            + "|" + claim.modality.rawValue + "|" + String(claim.validFrom) + "|" + String(claim.recordedAt))
    }

    /// Called before correction erasure, including exclusion replay after a stale restore.
    /// A newer reuse of the predecessor ID cannot acquire an old correction's disposition.
    static func preserveSupersession(of correctionIDs: Set<String>, db: Database) throws {
        for id in correctionIDs {
            guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id=?", arguments: [id]),
                  let correction = try? decode(BrainClaim.self, payload),
                  let predecessorID = correction.supersedesID,
                  let oldPayload = try String.fetchOne(db, sql: "SELECT payload FROM brain_claim WHERE id=?", arguments: [predecessorID]),
                  let predecessor = try? decode(BrainClaim.self, oldPayload),
                  predecessor.subject == correction.subject, predecessor.predicate == correction.predicate,
                  predecessor.revision <= correction.revision, predecessor.validFrom <= correction.validFrom else { continue }
            try db.execute(sql: """
                INSERT OR IGNORE INTO brain_supersession_disposition
                    (predecessor_id, assertion_fingerprint, effective_at, recorded_at, revision)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [predecessor.id, supersessionFingerprint(predecessor), correction.validFrom,
                                  correction.recordedAt, correction.revision])
        }
    }

    /// Callers supply only predecessors in their authorized snapshot. This contains no
    /// correction identity, source, value or authorization metadata. Event time and optional
    /// knowledge cutoffs retain historical reads without resurrecting current assertions.
    static func disposedPredecessors(_ claims: [BrainClaim], asOf: Double, knownAtRevision: Int64 = .max,
                                     recordedBy: Double = .greatestFiniteMagnitude, db: Database) throws -> Set<String> {
        let fingerprints = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, supersessionFingerprint($0)) })
        var result = Set<String>()
        for row in try Row.fetchAll(db, sql: """
            SELECT predecessor_id, assertion_fingerprint FROM brain_supersession_disposition
            WHERE effective_at<=? AND recorded_at<=? AND revision<=?
            """, arguments: [asOf, recordedBy, knownAtRevision]) {
            let id: String = row["predecessor_id"]
            if fingerprints[id] == (row["assertion_fingerprint"] as String) { result.insert(id) }
        }
        return result
    }
}
