import Foundation
import BrainContract

/// An injected extractor classifies meaning; turn learning never guesses intent from text regexes.
public protocol BrainTurnExtractor {
    func extract(source: BrainEvidence) async throws -> [BrainTurnProposal]
}
public enum BrainTurnIntent: Sendable { case explicit, candidate }
public enum BrainTurnQualification: Sendable { case firstPerson, quoted, hypothetical, thirdParty, uncertain, sarcastic }
public struct BrainTurnProposal: Sendable {
    public let update: BrainClaimUpdate
    public let span: BrainEvidenceSpan
    public let intent: BrainTurnIntent
    public let qualification: BrainTurnQualification
    public init(update: BrainClaimUpdate, span: BrainEvidenceSpan, intent: BrainTurnIntent,
                qualification: BrainTurnQualification = .firstPerson) {
        self.update = update; self.span = span; self.intent = intent; self.qualification = qualification
    }
}

/// Tool-observation sanitization is server-injected, never a client or model claim of safety.
/// Task 12/14 may supply the real sanitizer. The default retains status/provenance only.
public protocol BrainOutcomeSanitizer {
    func sanitizedDescription(_ description: String) throws -> String
}
public struct BrainRedactingOutcomeSanitizer: BrainOutcomeSanitizer {
    public init() {}
    public func sanitizedDescription(_ description: String) throws -> String { "" }
}

struct BrainTurnExtractionBatch {
    let updates: [BrainClaimUpdate]
    let hasPending: Bool
}

enum BrainTurnValidation {
    static func validate(_ proposals: [BrainTurnProposal], source: BrainEvidence,
                         authorization: BrainAuthorization) throws -> BrainTurnExtractionBatch {
        guard source.sourceKind == .userMessage, source.speakerID == "self:user",
              authorization.sourceSpeakers[.userMessage]?.contains(source.speakerID) == true,
              authorization.subjects.contains("self:user"), authorization.scopes.contains(source.accessScope),
              authorization.threads.contains(source.threadID), let text = source.text else {
            throw BrainStoreError.denied
        }
        let bytes = Array(text.utf8)
        var updates = [BrainClaimUpdate]()
        var pending = false
        var identifiers = Set<String>()
        for proposal in proposals {
            let claim = proposal.update.claim, span = proposal.span
            guard span.start >= 0, span.end > span.start, span.end <= bytes.count,
                  let excerpt = String(bytes: bytes[span.start..<span.end], encoding: .utf8),
                  claim.subject == "self:user", claim.evidenceIDs == [source.id],
                  !claim.id.isEmpty, !claim.predicate.isEmpty, identifiers.insert(claim.id).inserted,
                  claim.status == .active, claim.revision == 0,
                  claim.validFrom.isFinite, claim.recordedAt.isFinite,
                  claim.validTo.map({ $0.isFinite && $0 > claim.validFrom }) ?? true else {
                throw BrainStoreError.invalid
            }
            // Metadata constrains what the extractor may propose; it is not semantic proof.
            // Qualified statements retain their source as pending work, never factual promotion.
            guard proposal.qualification == .firstPerson else { pending = true; continue }
            switch claim.predicate {
            case TastePreferenceStore.predicate:
                guard (proposal.intent == .explicit && claim.modality == .asserted)
                    || (proposal.intent == .candidate && claim.modality == .inferred) else { pending = true; continue }
                try TastePreferenceStore.validate(claim, source: source, excerpt: excerpt)
            case AffectiveContextService.advicePreferencePredicate:
                guard proposal.intent == .explicit else { pending = true; continue }
                try AffectiveContextService.validateAdvice(claim, source: source)
            default:
                guard proposal.intent == .explicit,
                      claim.modality == .asserted || claim.modality == .negated,
                      claim.predicate.hasPrefix("preference.") || claim.supersedesID != nil else {
                    pending = true; continue
                }
            }
            // A correction must identify the exact revision it intends to replace.
            if claim.supersedesID != nil && proposal.update.expectedRevision == nil {
                throw BrainStoreError.invalid
            }
            updates.append(proposal.update)
        }
        return BrainTurnExtractionBatch(updates: updates, hasPending: pending)
    }
}
