import Foundation
import BrainContract

/// Builds typed taste updates for an evidence-bearing BrainTurnProposal, and reads the temporal
/// profile. Only the validated turn pipeline can commit these updates as BrainCommitRequests.
public final class TastePreferenceService {
    private let store: TastePreferenceStore

    public init(brain: BrainStore) {
        self.store = TastePreferenceStore(brain: brain)
    }

    public static func update(_ record: BrainTasteRecord, validTo: Double? = nil,
                              superseding previous: BrainClaim? = nil) throws -> BrainClaimUpdate {
        let value = try BrainStore.decode(BrainValue.self, BrainStore.encode(record))
        let claim = BrainClaim(id: record.id, revision: 0, subject: record.subjectID,
            predicate: TastePreferenceStore.predicate, value: value,
            modality: record.modality ?? (record.provenance == .explicit ? .asserted : .inferred),
            status: .active, validFrom: record.recordedAt, validTo: validTo,
            recordedAt: record.recordedAt, evidenceIDs: record.evidenceIDs, supersedesID: previous?.id)
        return .init(claim: claim, expectedRevision: previous?.revision)
    }

    public func profile(subject: String, domain: String, context: BrainTasteContext?, now: Double) throws -> BrainTasteProfile {
        try store.profile(subject: subject, domain: domain, context: context, now: now)
    }
}
