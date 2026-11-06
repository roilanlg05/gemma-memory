import Foundation
import BrainContract

/// The source-bound claim consolidation writes when the user states who they are.
///
/// The legacy `self:user` node stays exactly as it was — this is the durable, versioned record
/// *behind* it: a claim on subject `self:user`, citing the raw turn that asserted it as its
/// evidence root, superseding the previous name rather than overwriting it.
///
/// Everything here is deterministic. The claim id, the client operation id and every field of the
/// claim derive from the supporting evidence and the asserted value, so replaying the same
/// extraction is recognised as a replay (`idempotent`) rather than mistaken for a competing write
/// (`conflict`).
public enum ConsolidationIdentityClaim {
    /// One predicate per identity attribute. A later name supersedes the earlier one under this
    /// same predicate, which is what makes the history readable as a correction rather than as two
    /// competing facts.
    public static let namePredicate = "name"

    public static func claimID(evidenceID: String, value: String) -> String {
        "claim:\(selfUserID):\(namePredicate):" + ConsolidationDigest.hex(evidenceID + "\u{1}" + value)
    }

    public static func operationID(evidenceID: String, value: String) -> String {
        "self-name:" + ConsolidationDigest.hex(evidenceID + "\u{1}" + value)
    }

    /// Build the claim asserting `value` for the user, supported by `evidence`.
    ///
    /// `validFrom` is when the user said it, never when consolidation ran, and is clamped to be no
    /// earlier than the claim it supersedes (the store requires a non-regressing event time).
    /// `recordedAt` comes from the evidence for the same reason the evidence's own does: so the
    /// payload is stable across attempts.
    static func claim(value: String, evidence: BrainEvidence, superseding previous: BrainClaim?) -> BrainClaim {
        let validFrom = max(evidence.observedAt, previous?.validFrom ?? -Double.greatestFiniteMagnitude)
        return BrainClaim(id: claimID(evidenceID: evidence.id, value: value),
                          revision: 0,                        // stamped by the store at commit
                          subject: selfUserID,
                          predicate: namePredicate,
                          value: .string(value),
                          modality: .asserted,                // the user asserted it; see SelfAssertionValidator
                          status: .active,
                          validFrom: validFrom,
                          validTo: nil,
                          recordedAt: evidence.recordedAt,
                          evidenceIDs: [evidence.id],
                          supersedesID: previous?.id,
                          contradictsIDs: [])
    }
}

extension BrainStore {
    /// Commit the user's asserted identity as a source-bound claim.
    ///
    /// Returns the commit result, or nil when there is nothing to assert because an active claim
    /// already carries this exact value. The caller supplies a trusted authorization with
    /// `mayCommitClaims` and **`mayProject: false`**, so the claim never enters the legacy
    /// projection and `self:user` is never captured as a managed node — the legacy identity node
    /// keeps being written by `upsertSelf` exactly as before.
    ///
    /// No model or embedding call happens inside the transaction: the value and its evidence are
    /// already decided by the time this is called, and the expected revision is read first so the
    /// store can refuse a racing write instead of silently clobbering it.
    func commitAssertedIdentity(value: String, evidence: BrainEvidence) throws -> BrainCommitResult? {
        let asOf = max(evidence.observedAt, clock())
        let active = try claims(subject: selfUserID, asOf: asOf, scope: evidence.accessScope)
            .filter { $0.predicate == ConsolidationIdentityClaim.namePredicate }
        if active.contains(where: { $0.value == .string(value) }) { return nil }
        let previous = active.last
        let claim = ConsolidationIdentityClaim.claim(value: value, evidence: evidence, superseding: previous)
        let request = try BrainCommitRequest(
            clientOperationID: ConsolidationIdentityClaim.operationID(evidenceID: evidence.id, value: value),
            evidence: [evidence],
            updates: [BrainClaimUpdate(claim: claim, expectedRevision: previous?.revision)],
            expectedRevision: try revision())
        return try commit(request)
    }
}
