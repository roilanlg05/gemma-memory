import Foundation
import GRDB
import BrainContract

final class TastePreferenceStore {
    static let predicate = "preference.taste"
    private let brain: BrainStore

    init(brain: BrainStore) { self.brain = brain }

    static func record(_ claim: BrainClaim) throws -> BrainTasteRecord {
        try BrainStore.decode(BrainTasteRecord.self, BrainStore.encode(claim.value))
    }

    private struct Stance: Hashable {
        let kind: BrainTasteKind
        let target: String
        let domain: String?
        let context: String?
        let criterion: String?
        let alternatives: Set<String>

        init(_ record: BrainTasteRecord) {
            kind = record.kind
            target = TastePreferenceStore.key(record.target)
            domain = record.domain.map(TastePreferenceStore.key)
            context = record.context.map(TastePreferenceStore.key)
            criterion = record.criterion.map(TastePreferenceStore.key)
            alternatives = Set((record.alternatives ?? []).map(TastePreferenceStore.key))
        }
    }

    static func sameStance(_ first: BrainTasteRecord, _ second: BrainTasteRecord) -> Bool {
        Stance(first) == Stance(second)
    }

    /// Earlier versions could create multiple claims for the same enduring stance. Apply every
    /// surviving, authorized correction edge before selecting the active representative, so a
    /// subsequent correction cannot bring an old duplicate back into learning or the profile.
    static func effectiveClaims(_ active: [BrainClaim], history: [BrainClaim]) -> [BrainClaim] {
        let enduring = history.compactMap { claim -> (BrainClaim, Stance)? in
            guard claim.predicate == predicate, claim.status == .active, claim.validTo == nil,
                  let record = try? record(claim), record.isEnduringTaste else { return nil }
            return (claim, Stance(record))
        }
        let stances = Dictionary(uniqueKeysWithValues: enduring.map { ($0.0.id, $0.1) })
        var replacedBefore = [Stance: Int64]()
        for (claim, _) in enduring {
            guard let previous = claim.supersedesID, let stance = stances[previous] else { continue }
            replacedBefore[stance] = max(replacedBefore[stance] ?? 0, claim.revision)
        }
        var seen = Set<Stance>()
        let newestFirst = active.reversed().filter { claim in
            guard let stance = stances[claim.id] else { return true }
            return claim.revision >= (replacedBefore[stance] ?? 0) && seen.insert(stance).inserted
        }
        return Array(newestFirst.reversed())
    }

    private static func profileRecord(_ taste: BrainTasteRecord, claim: BrainClaim) -> BrainTasteRecord {
        .init(id: taste.id, subjectID: taste.subjectID, kind: taste.kind, target: taste.target,
              alternatives: taste.alternatives, criterion: taste.criterion, domain: taste.domain, context: taste.context,
              provenance: taste.provenance, durability: taste.durability, recordedAt: taste.recordedAt,
              evidenceIDs: taste.evidenceIDs, intensity: taste.intensity, modality: taste.modality,
              attribution: taste.attribution, validFrom: claim.validFrom, validTo: claim.validTo)
    }

    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func validText(_ text: String, maximum: Int = 160) -> Bool {
        !key(text).isEmpty && text.utf8.count <= maximum
            && text.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    }

    static func validate(_ claim: BrainClaim, source: BrainEvidence, excerpt: String? = nil) throws {
        let taste: BrainTasteRecord
        do { taste = try record(claim) } catch { throw BrainStoreError.invalid }
        let declared = taste.provenance == .explicit
        let alternatives = taste.alternatives ?? []
        let targets = Set(alternatives.map(key))
        guard claim.subject == "self:user", source.sourceKind == .userMessage, source.speakerID == claim.subject,
              taste.attribution == .direct, taste.id == claim.id, taste.subjectID == claim.subject,
              claim.evidenceIDs == [source.id], taste.evidenceIDs == claim.evidenceIDs,
              taste.recordedAt == claim.recordedAt, claim.recordedAt == source.recordedAt,
              claim.validFrom == source.observedAt, claim.contradictsIDs.isEmpty,
              taste.validFrom.map({ $0 == claim.validFrom }) ?? true,
              taste.validTo.map({ $0 == claim.validTo }) ?? true,
              claim.modality == (declared ? .asserted : .inferred),
              taste.modality.map({ $0 == claim.modality }) ?? true,
              let domain = taste.domain, validText(domain, maximum: 64), validText(taste.target),
              taste.context.map({ validText($0) }) ?? true, taste.criterion.map({ validText($0) }) ?? true,
              alternatives.count <= 12, alternatives.allSatisfy({ validText($0) }),
              targets.count == alternatives.count, !targets.contains(key(taste.target)),
              (taste.kind == .comparativePreference || (taste.alternatives == nil && taste.criterion == nil)),
              (taste.kind != .comparativePreference || !alternatives.isEmpty || taste.criterion.map(key) == "favorite"),
              (taste.kind == .liking || taste.kind == .disliking || taste.intensity == nil),
              (taste.durability != .enduring || (declared && claim.validTo == nil)),
              (declared || (claim.supersedesID == nil && taste.kind != .variety)) else { throw BrainStoreError.invalid }
        if !declared || taste.kind.isCurrentIntent {
            guard taste.durability == .contextual, let end = claim.validTo,
                  end > claim.validFrom, end - claim.validFrom <= 86_400 else { throw BrainStoreError.invalid }
        }
        if let excerpt, taste.kind != .variety {
            // A bare reaction cannot anchor a named taste, even if the extractor proposes one.
            // This binds the entities to the attributed text; the extractor classifies meaning.
            let normalized = key(excerpt)
            guard normalized.contains(key(taste.target)), targets.allSatisfy({ normalized.contains($0) })
            else { throw BrainStoreError.invalid }
        }
    }

    static func validateCorrection(_ replacement: BrainClaim, previous: BrainClaim) throws {
        let new = try record(replacement), old = try record(previous)
        guard previous.predicate == predicate, new.domain.map(key) == old.domain.map(key),
              new.context.map(key) == old.context.map(key), new.durability == old.durability,
              new.provenance == .explicit, !new.kind.isCurrentIntent, !old.kind.isCurrentIntent,
              replacement.validTo == nil || previous.validTo != nil else { throw BrainStoreError.invalid }
        if new.kind == .comparativePreference, old.kind == .comparativePreference {
            let newCriterion = new.criterion.map(key), oldCriterion = old.criterion.map(key)
            let oldChoices = Set(([old.target] + (old.alternatives ?? [])).map(key))
            let newChoices = Set(([new.target] + (new.alternatives ?? [])).map(key))
            guard oldCriterion == newCriterion,
                  oldChoices == newChoices || (newCriterion == "favorite" && new.alternatives == nil && old.alternatives == nil)
            else { throw BrainStoreError.invalid }
        } else {
            guard new.kind != .comparativePreference, old.kind != .comparativePreference,
                  key(new.target) == key(old.target) else { throw BrainStoreError.invalid }
        }
    }

    func profile(subject: String, domain: String, context: BrainTasteContext?, now: Double) throws -> BrainTasteProfile {
        try brain.requireAccess(subject: subject, scope: .user)
        if let thread = context?.threadID, !brain.authorization.threads.contains(thread) { throw BrainStoreError.denied }
        guard now.isFinite, Self.validText(domain, maximum: 64),
              context?.situation.map({ Self.validText($0) }) ?? true else { throw BrainStoreError.invalid }
        let domainKey = Self.key(domain), situationKey = context?.situation.map(Self.key)
        return try brain.store.dbQueue.read { db in
            try brain.checkOwner(db, bind: false)
            let revision = try BrainStore.revision(db)
            let claims = try brain.claims(subject: subject, asOf: now, scope: .user, knownAtRevision: revision,
                                          threadID: context?.threadID, includingExpiredPredicate: Self.predicate, db: db)
            var records = [BrainTasteRecord]()
            var intent: (record: BrainTasteRecord, claim: BrainClaim, sequence: Int)?
            for claim in claims where claim.predicate == Self.predicate {
                guard let taste = try? Self.record(claim), taste.domain.map(Self.key) == domainKey,
                      taste.context.map({ situationKey == nil || Self.key($0) == situationKey }) ?? true else { continue }
                let sources = try brain.availableEvidence(claim.evidenceIDs, db: db)
                if taste.kind.isCurrentIntent || claim.validTo != nil || taste.provenance == .inferred {
                    guard let thread = context?.threadID, sources.allSatisfy({ $0.threadID == thread }) else { continue }
                }
                if taste.kind.isCurrentIntent {
                    guard taste.provenance == .explicit,
                          taste.context.map({ Self.key($0) == situationKey }) ?? true,
                          sources.count == 1, let source = sources.first,
                          let sequence = try Int.fetchOne(db, sql: """
                              SELECT t.seq FROM brain_turn b JOIN transcript t ON t.id=b.transcript_id
                              WHERE b.principal=? AND b.source_id=? AND b.thread_id=?
                                AND t.threadId=b.thread_id AND t.role='user'
                              """, arguments: [brain.authorization.principal, source.id, source.threadID]) else { continue }
                    // Event time governs the profile. Admission order breaks equal event times.
                    if intent.map({ ($0.claim.validFrom, $0.sequence) <= (claim.validFrom, sequence) }) ?? true {
                        intent = (taste, claim, sequence)
                    }
                } else if claim.validTo.map({ now < $0 }) ?? true {
                    records.append(Self.profileRecord(taste, claim: claim))
                }
            }
            var missing = [BrainTasteInformationGap]()
            if !records.contains(where: { $0.provenance == .explicit && $0.kind != .comparativePreference }) { missing.append(.taste) }
            if !records.contains(where: { $0.provenance == .explicit && $0.kind == .comparativePreference }) { missing.append(.comparativePreference) }
            // An expired newest request leaves no current intent. Earlier requests stay historical.
            let currentIntent: [BrainTasteRecord]
            if let intent, let expiry = intent.claim.validTo, now < expiry {
                currentIntent = [Self.profileRecord(intent.record, claim: intent.claim)]
            } else {
                currentIntent = []
            }
            return .init(subjectID: subject, revision: revision, records: records,
                         currentIntent: currentIntent, missingInformation: missing)
        }
    }
}
