import Foundation
import GRDB
import BrainContract

public enum BrainAffectQualification: String, Codable, Equatable, Sendable {
    case firstPerson, thirdParty, quoted, negated, hypothetical, sarcastic, ambiguous
}

/// A provider proposal grounded in an exact UTF-8 span of the supplied user turn.
public struct BrainAffectCandidate: Codable, Equatable, Sendable {
    public let subjectID: String
    public let evidenceID: String
    public let span: BrainEvidenceSpan
    public let qualification: BrainAffectQualification
    public let basis: BrainAffectBasis
    public let label: BrainAffectLabel?
    public let certainty: BrainAffectCertainty
    public let interaction: BrainInteractionCues?

    public init(subjectID: String, evidenceID: String, span: BrainEvidenceSpan,
                qualification: BrainAffectQualification, basis: BrainAffectBasis,
                label: BrainAffectLabel? = nil, certainty: BrainAffectCertainty,
                interaction: BrainInteractionCues? = nil) {
        self.subjectID = subjectID
        self.evidenceID = evidenceID
        self.span = span
        self.qualification = qualification
        self.basis = basis
        self.label = label
        self.certainty = certainty
        self.interaction = interaction
    }
}

public struct BrainAffectInput: Codable, Equatable, Sendable {
    public let source: BrainEvidence
    /// A short exact-thread window of earlier committed user evidence, in transcript order.
    public let recent: [BrainEvidence]
}

/// An injected semantic classifier. An empty array abstains. There is no keyword fallback.
public protocol BrainAffectExtractor {
    func extract(_ input: BrainAffectInput) async throws -> [BrainAffectCandidate]
}

/// Initialize once at session infrastructure startup, before accepting new turns. Reopening the
/// store records a new transcript floor, so old turns cannot reconstitute affect after restart.
public final class AffectiveContextService {
    public static let advicePreferencePredicate = "preference.conversation.advice"

    private let brain: BrainStore
    private let store: AffectiveContextStore
    private let extractor: any BrainAffectExtractor

    public init(brain: BrainStore, extractor: any BrainAffectExtractor, ttl: Double = 900) throws {
        self.brain = brain
        self.extractor = extractor
        self.store = try AffectiveContextStore(brain: brain, ttl: ttl)
    }

    public func observe(turnID: String, now: Double) async throws -> [BrainAffectHypothesis] {
        let original: AffectiveContextStore.Observation
        switch try store.prepare(turnID: turnID, now: currentTime(now)) {
        case .cached(let context): return context.hypotheses
        case .extract(let observation): original = observation
        }
        let candidates: [BrainAffectCandidate]
        let input = BrainAffectInput(source: original.turn.source, recent: original.recent.map(\.source))
        do { candidates = try await extractor.extract(input) }
        catch {
            _ = try store.finish(original, context: nil, now: currentTime(now))
            throw error
        }
        let context = validate(candidates, input: input)
        return try store.finish(original, context: context, now: currentTime(now)).hypotheses
    }

    public func context(threadID: String, now: Double) throws -> BrainAffectiveContext {
        let time = try currentTime(now)
        return try brain.store.dbQueue.read { db in
            let inferred = try store.context(threadID: threadID, now: time, db: db)
            let claims = try brain.claims(subject: "self:user", asOf: time, scope: .user, threadID: threadID, db: db)
            let advice = try Self.advice(claims: claims, threadID: threadID) { ids in
                try brain.availableEvidence(ids, db: db)
            }
            return .init(hypotheses: inferred.hypotheses, interaction: inferred.interaction, advice: advice)
        }
    }

    public func correct(hypothesisID: String, operationID: String, correction: BrainAffectCorrection) throws {
        try store.correct(hypothesisID: hypothesisID, operationID: operationID, correction: correction)
    }

    public func endSession(threadID: String) throws {
        try store.endSession(threadID: threadID)
    }

    private func currentTime(_ now: Double) throws -> Double {
        let clock = brain.clock()
        guard now.isFinite, clock.isFinite else { throw BrainStoreError.invalid }
        return max(now, clock)
    }

    private func validate(_ candidates: [BrainAffectCandidate], input: BrainAffectInput) -> BrainAffectiveContext {
        let source = input.source
        // The classifier can depend on every supplied turn. Keep the attributed source first.
        let evidenceIDs = [source.id] + input.recent.map(\.id)
        let expiry = input.recent.reduce(store.expiry(for: source)) { min($0, store.expiry(for: $1)) }
        guard let text = source.text else { return .init() }
        let bytes = Array(text.utf8)
        var hypotheses = [BrainAffectHypothesis]()
        var interaction: BrainInteractionState?
        var seen = Set<BrainAffectLabel>()
        for candidate in candidates.prefix(8) {
            let span = candidate.span
            guard candidate.subjectID == source.speakerID, candidate.evidenceID == source.id,
                  candidate.qualification == .firstPerson, span.start >= 0, span.end > span.start,
                  span.end <= bytes.count,
                  let quote = String(bytes: bytes[span.start..<span.end], encoding: .utf8),
                  !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let admittedCue: Bool
            if interaction == nil, candidate.certainty != .low, let cues = candidate.interaction,
               cues.focus != nil || cues.interest != nil || cues.tension != nil {
                interaction = .init(cues: cues, observedAt: source.observedAt,
                                    expiresAt: expiry, evidenceIDs: evidenceIDs)
                admittedCue = true
            } else {
                admittedCue = false
            }
            // Cue-only guidance still needs a hypothesis ID so the user can dismiss it.
            if candidate.label.map({ seen.insert($0).inserted }) ?? admittedCue {
                hypotheses.append(.init(id: UUID().uuidString, subjectID: source.speakerID,
                    label: candidate.label?.rawValue, sessionID: source.threadID, observedAt: source.observedAt,
                    expiresAt: expiry, evidenceIDs: evidenceIDs, basis: candidate.basis, certainty: candidate.certainty))
            }
        }
        return .init(hypotheses: hypotheses, interaction: interaction)
    }

    func interaction(threadID: String, authorizedBy requester: BrainStore, db: Database) throws -> BrainInteractionState? {
        guard requester.store === brain.store,
              requester.authorization.principal == brain.authorization.principal,
              requester.authorization.owner == brain.authorization.owner,
              requester.authorization.scopes.contains(.user),
              requester.authorization.sourceSpeakers[.userMessage]?.contains("self:user") == true,
              brain.authorization.threads.contains(threadID) else { return nil }
        return try store.context(threadID: threadID, now: currentTime(requester.clock()), db: db).interaction
    }

    static func advice(claims: [BrainClaim], threadID: String, evidence: ([String]) throws -> [BrainEvidence]) rethrows
        -> BrainConversationAdvicePreference? {
        var durable: BrainConversationAdvicePreference?
        for claim in claims.reversed() where claim.predicate == advicePreferencePredicate {
            guard claim.subject == "self:user", claim.modality == .asserted,
                  case .string(let value) = claim.value, let mode = BrainConversationAdviceMode(rawValue: value) else { continue }
            let sources = try evidence(claim.evidenceIDs)
            guard !sources.isEmpty, sources.count == claim.evidenceIDs.count,
                  sources.allSatisfy({ source in
                      source.sourceKind == .userMessage && source.speakerID == "self:user"
                          && (source.threadID == threadID || (source.accessScope == .user && claim.validTo == nil))
                  }) else { continue }
            let preference = BrainConversationAdvicePreference(mode: mode, expiresAt: claim.validTo,
                                                                evidenceIDs: sources.map(\.id))
            if claim.validTo != nil { return preference }
            if durable == nil { durable = preference }
        }
        return durable
    }

    static func validateAdvice(_ claim: BrainClaim, source: BrainEvidence) throws {
        guard claim.subject == "self:user", claim.modality == .asserted,
              claim.evidenceIDs == [source.id], claim.recordedAt == source.recordedAt, claim.contradictsIDs.isEmpty,
              claim.validFrom == source.observedAt, case .string(let value) = claim.value,
              BrainConversationAdviceMode(rawValue: value) != nil else { throw BrainStoreError.invalid }
    }
}
