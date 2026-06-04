import Foundation
import GRDB

extension MemoryStore {
    /// Hard-delete all `cluster` anchor nodes and every edge touching them (rebuilt each cycle).
    /// Removes ALL incident edges — `belongsToCluster` (anchor→member) AND the `belongsToHub`
    /// edge the auto-linker creates (hub:cluster→anchor) — so no dangling edges accumulate.
    /// node_fts is NOT trigger-maintained (manually managed — see upsert/softDelete/deleteConversationNodes),
    /// so cluster node rows are explicitly removed from node_fts before deleting from node.
    public func clearClusters() throws {
        try dbQueue.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM node WHERE kind = ?", arguments: [NodeKind.cluster.rawValue])
            guard !ids.isEmpty else { return }
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM edge WHERE srcId IN (\(ph)) OR dstId IN (\(ph))",
                           arguments: StatementArguments(ids + ids))
            try db.execute(sql: "DELETE FROM node_embedding WHERE node_id IN (\(ph))", arguments: StatementArguments(ids))
            try db.execute(sql: "DELETE FROM node_tags WHERE node_id IN (\(ph))", arguments: StatementArguments(ids))
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id IN (\(ph))", arguments: StatementArguments(ids))
            try db.execute(sql: "DELETE FROM node WHERE kind = ?", arguments: [NodeKind.cluster.rawValue])
        }
    }
}
