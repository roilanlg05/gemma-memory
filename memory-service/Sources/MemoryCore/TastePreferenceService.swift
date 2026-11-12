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

    /// A direct enduring correction replaces the newest representative in the same typed taste
    /// slot. Distinct prior stances remain ambiguous. The turn commit validates the exact revision.
    public static func correction(_ record: BrainTasteRecord, candidates: [BrainClaim]) throws -> BrainClaimUpdate {
        let draft = try update(record)
        let matches = candidates.filter { previous in
            previous.validTo == nil && previous.validFrom <= record.recordedAt
                && (try? TastePreferenceStore.validateCorrection(draft.claim, previous: previous)) != nil
        }
        guard let prior = matches.max(by: { ($0.validFrom, $0.revision, $0.id) < ($1.validFrom, $1.revision, $1.id) }),
              let stance = try? TastePreferenceStore.record(prior),
              matches.allSatisfy({ candidate in
                  guard let record = try? TastePreferenceStore.record(candidate) else { return false }
                  return TastePreferenceStore.sameStance(record, stance)
              }) else { return draft }
        return try update(record, superseding: prior)
    }

    public static func repeatsEnduringStance(_ record: BrainTasteRecord, candidates: [BrainClaim]) -> Bool {
        guard record.isEnduringTaste else { return false }
        return candidates.contains { prior in
            guard prior.validTo == nil, let priorTaste = try? TastePreferenceStore.record(prior),
                  priorTaste.isEnduringTaste, priorTaste.intensity == record.intensity else { return false }
            return TastePreferenceStore.sameStance(record, priorTaste)
        }
    }

    public func profile(subject: String, domain: String, context: BrainTasteContext?, now: Double) throws -> BrainTasteProfile {
        try store.profile(subject: subject, domain: domain, context: context, now: now)
    }
}
