import Foundation
import BrainContract
import GRDB

extension BrainTurnStore {
    static let gatewayToolSpeaker = "tool:gateway"

    /// This is called only after host dispatch. The persisted record cannot contain tool args,
    /// headers, body, or user/model-selected metadata.
    func recordGatewayObservation(turnID: String, status: BrainOutcomeStatus, at timestamp: Double) throws {
        let outcomeID = "gateway-tool:" + UUID().uuidString
        let sourceID = outcomeID + ":source"
        let safeResult: SafeToolObservation.Result
        switch status {
        case .succeeded: safeResult = .succeeded
        case .failed: safeResult = .failed
        case .partial: safeResult = .partial
        case .unknown, .cancelled: safeResult = .unknown
        }
        let safeText = SafeToolObservation(result: safeResult).rendered
        try brain.store.dbQueue.write { db in
            let turn = try load(turnID, db: db)
            guard brain.authorization.principal == brain.authorization.owner, timestamp.isFinite,
                  try operation("gateway-admission", key: Self.key(turnID), db: db) != nil else { throw BrainStoreError.denied }
            let observation = BrainEvidence(id: sourceID, sourceKind: .toolObservation, speakerID: Self.gatewayToolSpeaker,
                threadID: turn.source.threadID, observedAt: timestamp, recordedAt: timestamp,
                accessScope: .user, text: safeText)
            try brain.insertEvidence(observation, db: db)
            try db.execute(sql: "INSERT INTO brain_turn_ref VALUES (?, ?, ?)", arguments: [turnID, sourceID, turn.transcriptID])
            let outcome = BrainOutcome(id: outcomeID, description: "", status: status, recordedAt: timestamp,
                evidenceIDs: [turn.source.id, sourceID], observation: .init(operation: .resourceCheck))
            let key = try Self.key(outcomeID)
            try db.execute(sql: "INSERT INTO brain_turn_outcome(principal, operation_hash, payload, redacted) VALUES (?, ?, ?, 1)",
                           arguments: [brain.authorization.principal, key, try BrainStore.encode(outcome)])
            for id in outcome.evidenceIDs {
                try db.execute(sql: "INSERT INTO brain_turn_outcome_ref VALUES (?, ?, ?)",
                               arguments: [brain.authorization.principal, key, id])
            }
            try insertOperation("outcome", key: key, digest: BrainStore.digest(try BrainStore.encode(outcome)),
                                turnID: turnID, resultID: nil, db: db)
        }
    }
}
