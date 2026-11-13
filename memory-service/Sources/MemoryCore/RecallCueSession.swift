import Foundation
import BrainContract

public struct RecallTurnCue: Sendable {
    public let connectionID: String
    public let turnID: String
    public let text: String
    public let isStable: Bool

    public init(connectionID: String, turnID: String, text: String, isStable: Bool) {
        self.connectionID = connectionID
        self.turnID = turnID
        self.text = text
        self.isStable = isStable
    }
}

public struct RecallPrefetch: Sendable {
    public let episodeIDs: [String]
    fileprivate let token: UUID
}

fileprivate final class RecallAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var live = true

    func revoke() { lock.withLock { live = false } }
    func isLive() -> Bool { lock.withLock { live } }
}

public struct RecallFinalization: Sendable {
    public let candidates: [BrainRecallCandidate]
    fileprivate let owner: String
    fileprivate let principal: String
    fileprivate let brainID: ObjectIdentifier
    fileprivate let connectionID: String
    fileprivate let turnID: String
    fileprivate let threadID: String
    fileprivate let scope: BrainAccessScope
    fileprivate let queryDigest: String
    fileprivate let lease: RecallAdmission
    let vector: IndexEmbedding?

    func matches(brain: BrainStore, connectionID: String, turnID: String, threadID: String, scope: BrainAccessScope, query: String) -> Bool {
        self.connectionID == connectionID && self.turnID == turnID && self.threadID == threadID && self.scope == scope
            && brainID == ObjectIdentifier(brain) && owner == brain.authorization.owner && principal == brain.authorization.principal
            && queryDigest == BrainStore.digest(query) && lease.isLive()
    }
}

/// Active-input recall for one authenticated connection. The host supplies unique turn IDs and
/// drops the session when the connection ends. Candidate selection never writes a conversation.
public actor RecallCueSession {
    private struct Pending {
        let token: UUID
        let turnID: String
        let digest: String
        var vector: IndexEmbedding?
    }

    private let retriever: AssociativeRetriever
    private let connectionID: String
    private let threadID: String
    private let scope: BrainAccessScope
    private var pending: Pending?
    private var finalized: (turnID: String, lease: RecallAdmission)?
    private var retired = [String]()
    private var closed = false

    fileprivate init(retriever: AssociativeRetriever, connectionID: String, threadID: String, scope: BrainAccessScope) {
        self.retriever = retriever; self.connectionID = connectionID; self.threadID = threadID; self.scope = scope
    }

    deinit { finalized?.lease.revoke() }

    public func prefetch(_ cue: RecallTurnCue, asOf: Double, budget: BrainRecallBudget) async throws -> RecallPrefetch? {
        guard accepts(cue) else { return nil }
        revokePreviousTurn(for: cue)
        guard cue.isStable, !RecallCue(cue.text).terms.isEmpty else {
            if pending?.turnID == cue.turnID { pending = nil }
            return nil
        }
        let token = start(cue)
        do {
            let vector = try await retriever.queryVector(cue.text, threadID: threadID, scope: scope)
            guard pending?.token == token, !Task.isCancelled else { return nil }
            let result = try rank(cue.text, asOf: asOf, budget: budget, vector: vector)
            guard pending?.token == token, !Task.isCancelled else { return nil }
            pending?.vector = vector
            return .init(episodeIDs: result.candidates.map(\.episodeID), token: token)
        } catch {
            if pending?.token == token { pending = nil }
            throw error
        }
    }

    /// Final input can also be submitted directly for text turns that had no partial cue.
    public func finalize(_ handle: RecallPrefetch? = nil, final: RecallTurnCue, asOf: Double,
                         budget: BrainRecallBudget) async throws -> RecallFinalization? {
        guard accepts(final) else { return nil }
        revokePreviousTurn(for: final)
        guard final.isStable, !RecallCue(final.text).terms.isEmpty else {
            if pending?.turnID == final.turnID { pending = nil }
            return nil
        }
        let digest = BrainStore.digest(final.text)
        var vector: IndexEmbedding?
        let token: UUID
        if let handle {
            guard let pending, pending.token == handle.token, pending.turnID == final.turnID else { return nil }
            token = pending.token
            if pending.digest == digest { vector = pending.vector }
        } else {
            token = start(final)
            do { vector = try await retriever.queryVector(final.text, threadID: threadID, scope: scope) }
            catch {
                if pending?.token == token { pending = nil }
                throw error
            }
        }
        guard pending?.token == token, !Task.isCancelled else { return nil }
        pending = nil
        retire(final.turnID)
        let result = try rank(final.text, asOf: asOf, budget: budget, vector: vector)
        guard !Task.isCancelled else { return nil }
        let lease = RecallAdmission()
        finalized = (final.turnID, lease)
        return .init(candidates: result.candidates, owner: retriever.brain.authorization.owner,
            principal: retriever.brain.authorization.principal, brainID: ObjectIdentifier(retriever.brain), connectionID: connectionID,
            turnID: final.turnID, threadID: threadID, scope: scope, queryDigest: digest, lease: lease, vector: vector)
    }

    public func cancel(connectionID: String, turnID: String) {
        guard connectionID == self.connectionID, !turnID.isEmpty else { return }
        if pending?.turnID == turnID { pending = nil }
        if finalized?.turnID == turnID { finalized?.lease.revoke(); finalized = nil }
        retire(turnID)
    }

    public func close() {
        closed = true
        pending = nil
        finalized?.lease.revoke()
        finalized = nil
    }

    private func accepts(_ cue: RecallTurnCue) -> Bool {
        !closed && cue.connectionID == connectionID && !connectionID.isEmpty && !cue.turnID.isEmpty && !retired.contains(cue.turnID)
    }

    private func revokePreviousTurn(for cue: RecallTurnCue) {
        if let old = pending, old.turnID != cue.turnID {
            retire(old.turnID)
            pending = nil
        }
        if let old = finalized, old.turnID != cue.turnID {
            old.lease.revoke()
            finalized = nil
        }
    }

    private func start(_ cue: RecallTurnCue) -> UUID {
        if let pending, pending.turnID != cue.turnID { retire(pending.turnID) }
        finalized?.lease.revoke()
        finalized = nil
        let token = UUID()
        pending = .init(token: token, turnID: cue.turnID, digest: BrainStore.digest(cue.text), vector: nil)
        return token
    }

    private func retire(_ turnID: String) {
        guard !retired.contains(turnID) else { return }
        retired.append(turnID)
        if retired.count > 32 { retired.removeFirst() }
    }

    private func rank(_ query: String, asOf: Double, budget: BrainRecallBudget, vector: IndexEmbedding?) throws -> BrainRecallResult {
        try retriever.brain.store.dbQueue.read { db in
            try retriever.retrieve(query: query, threadID: threadID, scope: scope, asOf: asOf, budget: budget, vector: vector, db: db)
        }
    }
}

extension AssociativeRetriever {
    public func makeCueSession(connectionID: String, threadID: String, scope: BrainAccessScope) -> RecallCueSession {
        .init(retriever: self, connectionID: connectionID, threadID: threadID, scope: scope)
    }
}
