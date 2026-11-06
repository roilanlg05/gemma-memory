import Foundation
import BrainContract

/// Captures admitted user turns once, learns before retrieval, and records only real output.
/// Passive IGNORE admission belongs to the caller; this service never classifies ambient text.
public final class BrainTurnService {
    public typealias Retrieval = (BrainTurnRequest, BrainEvidence) async throws -> BrainContextBundle
    private let brain: BrainStore
    private let journal: BrainTurnStore
    private let extractor: any BrainTurnExtractor
    private let sanitizer: any BrainOutcomeSanitizer
    private let clock: () -> Double
    private let retrieval: Retrieval?

    public init(store: MemoryStore, authorization: BrainAuthorization, extractor: any BrainTurnExtractor,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                retrieval: Retrieval? = nil,
                outcomeSanitizer: any BrainOutcomeSanitizer = BrainRedactingOutcomeSanitizer()) {
        let brain = BrainStore(store: store, authorization: authorization, clock: clock)
        self.brain = brain; self.journal = BrainTurnStore(brain: brain)
        self.extractor = extractor; self.clock = clock; self.retrieval = retrieval; self.sanitizer = outcomeSanitizer
    }

    public func begin(_ request: BrainTurnRequest) async throws -> BrainTurnResult {
        let id = try journal.capture(request)
        do {
            let updates = try await proposeUpdates(turnID: id)
            _ = try commitUpdates(updates, turnID: id)
        } catch {
            // The durable source remains retryable after extraction/validation/commit failure.
            // Erasure is different: re-reading below denies the withdrawn turn entirely.
        }
        let source = try journal.read(id).source
        let context = try await retrieval?(request, source)
        let turn = try journal.read(id)
        let state: BrainPersistenceState = turn.state == "committed" ? .committed : .pending
        return BrainTurnResult(clientOperationID: request.clientOperationID, turnID: id,
            reply: try journal.reply(id), completion: BrainTurnCompletion(state: state,
                revision: try brain.revision(), evidenceIDs: [turn.source.id]), context: context)
    }

    public func proposeUpdates(turnID: String) async throws -> [BrainClaimUpdate] {
        let turn = try journal.read(turnID)
        if let updates = turn.updates { return updates }
        let proposals = try await extractor.extract(source: turn.source)
        let batch = try BrainTurnValidation.validate(proposals, source: turn.source, authorization: brain.authorization)
        return try journal.stage(batch, turnID: turnID)
    }

    /// Only the exact server-validated durable proposal for this turn can be committed.
    public func commitUpdates(_ updates: [BrainClaimUpdate], turnID: String) throws -> BrainCommitResult {
        try journal.commit(updates, turnID: turnID)
    }

    /// Read-your-writes hook for context assembly, independent of embedding availability.
    public func currentClaims(turnID: String, asOf: Double) throws -> [BrainClaim] {
        _ = try journal.read(turnID)
        return try brain.claims(subject: "self:user", asOf: asOf, scope: .user)
    }

    @discardableResult
    public func recordAssistant(turnID: String, operationID: String, text: String) throws -> BrainEvidence {
        try journal.assistant(turnID: turnID, operationID: operationID, text: text, timestamp: clock())
    }

    /// Returns the sanitized receipt, not the original tool body. With the default sanitizer its
    /// description is empty; durable metadata explicitly marks the observation as redacted.
    @discardableResult
    public func recordOutcome(_ outcome: BrainOutcome) throws -> BrainOutcome {
        try brain.requirePrincipal()
        guard brain.authorization.owner == ConsolidationEvidenceAdapter.ownerID else { throw BrainStoreError.denied }
        let description = try sanitizer.sanitizedDescription(outcome.description)
        return try journal.outcome(outcome, sanitizedDescription: description)
    }
}
