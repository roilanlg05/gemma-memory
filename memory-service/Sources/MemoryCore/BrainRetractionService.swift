import Foundation
import BrainContract

/// Retraction and forgetting across derived memory: the public entry point for erasing a scope
/// and everything the brain derived from it.
///
/// Forgetting is a distinct mechanism from salience decay. Decay soft-deletes a node whose
/// importance faded and leaves the row revivable; retraction erases the content, records a
/// persistent exclusion marker so stale inputs cannot reintroduce it, and mints a revision.
/// The two never substitute for each other.
///
/// Erasure requires the explicit `mayForget` capability on a trusted `BrainAuthorization`, the
/// user scope, and authorization over the named subject, thread, evidence or claim. Whole-store
/// erasure additionally requires the bound owner as principal.
public final class BrainRetractionService {
    private let brain: BrainStore

    public init(brain: BrainStore) {
        self.brain = brain
    }

    /// Erases `scope` and its derived closure in one transaction, returning a receipt that
    /// reports the new revision and the affected identifiers — never the forgotten content.
    ///
    /// Replaying the same `operationID` with the same scope returns the stored receipt without
    /// purging again; reusing it for a different scope is a `BrainStoreError.conflict`, as is a
    /// stale `expectedRevision`. Every failure rolls the transaction back and throws, so a
    /// receipt is never issued for an erasure that only partly happened.
    @discardableResult
    public func forget(scope: BrainForgetScope, expectedRevision: Int64, operationID: String) throws -> BrainForgetReceipt {
        try brain.forget(scope: scope, expectedRevision: expectedRevision, operationID: operationID)
    }

    /// Re-applies persistent exclusion markers, plus the identifiers in `receipts`, so a store
    /// that was restored or re-synced from stale inputs cannot serve withdrawn rows. The caller
    /// invokes this before restored reads; nothing schedules it.
    public func applyExclusions(_ receipts: [BrainForgetReceipt]) throws {
        try brain.applyExclusions(receipts)
    }
}
