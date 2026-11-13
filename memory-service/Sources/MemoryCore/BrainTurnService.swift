import Foundation
import BrainContract

public struct BrainGatewayAdmission: Codable, Equatable, Sendable {
    public let language: String?
    public let timezone: String

    public init(language: String?, timezone: String) {
        self.language = language
        self.timezone = timezone
    }
}

/// Captures admitted user turns once, learns before retrieval, and records only real output.
/// Passive IGNORE admission belongs to the caller; this service never classifies ambient text.
public final class BrainTurnService {
    public typealias Retrieval = (BrainTurnRequest, BrainEvidence) async throws -> BrainContextBundle?
    public typealias AfterLearning = (String, BrainEvidence) async -> Void
    private let brain: BrainStore
    private let journal: BrainTurnStore
    private let extractor: any BrainTurnExtractor
    private let sanitizer: any BrainOutcomeSanitizer
    private let clock: () -> Double
    private let retrieval: Retrieval?
    private let afterLearning: AfterLearning?

    public init(store: MemoryStore, authorization: BrainAuthorization, extractor: any BrainTurnExtractor,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                retrieval: Retrieval? = nil,
                afterLearning: AfterLearning? = nil,
                outcomeSanitizer: any BrainOutcomeSanitizer = BrainRedactingOutcomeSanitizer()) {
        let brain = BrainStore(store: store, authorization: authorization, clock: clock)
        self.brain = brain; self.journal = BrainTurnStore(brain: brain)
        self.extractor = extractor; self.clock = clock; self.retrieval = retrieval; self.sanitizer = outcomeSanitizer
        self.afterLearning = afterLearning
    }

    public func begin(_ request: BrainTurnRequest, useServerTimestamp: Bool = false,
                      gateway: BrainGatewayAdmission? = nil, onAdmission: (() async -> Void)? = nil) async throws -> BrainTurnResult {
        let capture = try journal.captureAdmitted(request, observedAt: useServerTimestamp ? clock() : nil, gateway: gateway)
        let id = capture.id
        if capture.new { await onAdmission?() }
        let initial = try journal.read(id)
        if gateway != nil {
            let reply = try journal.reply(id)
            if !reply.isEmpty {
                return .init(clientOperationID: request.clientOperationID, turnID: id, reply: reply,
                             completion: try completion(turnID: id))
            }
        }
        if brain.authorization.mayCommitClaims, initial.state == "captured", let text = initial.source.text,
           let name = SelfAssertionValidator.directName(in: text), try journal.validatedName(turnID: id, candidate: name) {
            for _ in 0..<3 {
                if try brain.commitAssertedIdentity(value: name, evidence: initial.source)?.disposition != .conflict { break }
            }
        }
        do {
            let updates = try await proposeUpdates(turnID: id)
            _ = try commitUpdates(updates, turnID: id)
        } catch {
            // The durable source remains retryable after extraction/validation/commit failure.
            // Erasure is different: re-reading below denies the withdrawn turn entirely.
        }
        let learned = try journal.read(id)
        if learned.state == "committed" { await afterLearning?(id, learned.source) }
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
    public func commitUpdates(_ updates: [BrainClaimUpdate], turnID: String, expectedRevision: Int64? = nil) throws -> BrainCommitResult {
        try journal.commit(updates, turnID: turnID, expectedRevision: expectedRevision)
    }

    /// Read-your-writes hook for context assembly, independent of embedding availability.
    public func currentClaims(turnID: String, asOf: Double) throws -> [BrainClaim] {
        try brain.store.dbQueue.read { db in
            let turn = try journal.load(turnID, db: db)
            return try brain.claims(subject: "self:user", asOf: asOf, scope: .user,
                                    threadID: turn.source.threadID, db: db)
        }
    }

    /// Resolve and revalidate a turn in its caller's authorized thread.
    public func completion(turnID: String) throws -> BrainTurnCompletion {
        let turn = try journal.read(turnID)
        return BrainTurnCompletion(state: turn.state == "committed" ? .committed : .pending,
                                   revision: try brain.revision(), evidenceIDs: [turn.source.id])
    }

    public func admittedUserEvidence(turnID: String) throws -> BrainEvidence {
        try journal.read(turnID).source
    }

    /// Resolve a stored turn reference to its thread without taking a thread grant from the wire.
    /// Only the single configured owner may do this lookup, and later reads still validate the source.
    public func owningThread(turnID: String, nativeOnly: Bool = false) throws -> String {
        try journal.owningThread(turnID: turnID, nativeOnly: nativeOnly)
    }

    /// An incomplete request with a dispatched mutation must not automatically execute it again.
    public func requireNoMutationAttempt(turnID: String) throws {
        try journal.requireNoMutationAttempt(turnID: turnID)
    }

    /// Record a durable, content-free fence before dispatching the first mutating tool.
    public func reserveMutationAttempt(turnID: String) throws {
        try journal.reserveMutationAttempt(turnID: turnID)
    }

    /// A source-bound, redacted report from the actual gateway dispatcher.
    public func recordGatewayObservation(turnID: String, status: BrainOutcomeStatus) throws {
        try journal.recordGatewayObservation(turnID: turnID, status: status, at: clock())
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
    /// Host ingestion path for tool outcomes: accepts no raw body, headers, or parameters.
    /// The observation is a report, not independent verification or action authorization.
    @discardableResult
    public func recordToolOutcome(id: String, status: BrainOutcomeStatus, recordedAt: Double,
                                  evidenceIDs: [String], observation: BrainToolObservation) throws -> BrainOutcome {
        try recordOutcome(.init(id: id, description: "", status: status, recordedAt: recordedAt,
                                evidenceIDs: evidenceIDs, observation: observation))
    }

}
