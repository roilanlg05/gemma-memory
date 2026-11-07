import Foundation
import BrainContract

/// The agent's own identity: who it is, how it was configured to come across, and what it actually
/// did. The public entry point for reading and revising it.
///
/// Three boundaries hold here, and all three are the point of the type:
///
/// - **The core is not configurable by recall.** Revising the identity needs the explicit
///   `mayReviseIdentity` grant and a user message as its source. `mayCommitClaims` does not reach
///   it, so neither a quoted page, a recalled claim nor a model proposal can rewrite who the
///   assistant is — the worst a committed `identity.*` claim achieves is to sit in the claim store
///   unread by this service.
/// - **The agent is not the user.** `identity()` answers only for `self:agent`, and asking it for
///   `self:user` is refused rather than served from the user's subject. The shared relationship is
///   read through `relationship()` and is never merged into either self.
/// - **Experience is not aspiration.** The autobiography is projected live from recorded
///   utterances and sanitised outcome receipts, so a proposal never becomes a completed action.
///
/// Provider or process restarts change nothing: the identity is stored, so reopening the same
/// database returns the same name, the same character and the same history.
public final class AgentIdentityService {
    private let brain: BrainStore
    private let store: AgentIdentityStore

    /// `capabilityAddenda` are the lines the native host contributes about what this installation
    /// can actually do. They are supplied by the server that constructs this service, never stored
    /// and never model-authored, and they travel with the profile so a custom character cannot
    /// displace them.
    public init(brain: BrainStore, capabilityAddenda: [String] = []) {
        self.brain = brain
        self.store = AgentIdentityStore(brain: brain, capabilityAddenda: capabilityAddenda)
    }

    /// The agent's identity, resolved from the surviving revisions. The `agentID` parameter exists
    /// so a caller names the subject it means; any subject other than `self:agent` is refused.
    public func identity(agentID: String = BrainIdentity.agentID) throws -> BrainIdentity {
        try store.requireAgentRead(agentID)
        return try brain.store.dbQueue.read { try store.identity(agentID: agentID, db: $0) }
    }

    /// The shared relationship subject, which belongs to neither self.
    public func relationship() throws -> BrainIdentity {
        try store.requireRelationshipRead()
        return try brain.store.dbQueue.read { try store.relationship(db: $0) }
    }

    /// Applies one explicit identity operation and returns the resulting identity.
    ///
    /// `expectedRevision` is the brain revision the caller believes it is changing, so a stale
    /// revision is a `conflict` rather than a silent overwrite. Replaying the same `operationID`
    /// with the same change returns the identity that operation produced; replaying it with a
    /// different change, or after the operation has been withdrawn by an erasure, is refused.
    @discardableResult
    public func reviseIdentity(expectedRevision: Int64, operationID: String, change: BrainIdentityChange,
                               agentID: String = BrainIdentity.agentID) throws -> BrainIdentity {
        try store.revise(agentID: agentID, expectedRevision: expectedRevision,
                         operationID: operationID, change: change)
    }
}
