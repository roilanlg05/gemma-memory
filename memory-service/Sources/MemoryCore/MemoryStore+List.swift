import Foundation
import GRDB

/// Paginated listing of live nodes — backs the read-only `/v1/nodes` inspector endpoint.
public extension MemoryStore {
    struct ListedNodes: Encodable, Sendable {
        public let nodes: [Node]
        public let total: Int
        public init(nodes: [Node], total: Int) {
            self.nodes = nodes
            self.total = total
        }
    }

    /// Newest-first slice of live nodes, optionally filtered by kind. `total` reflects the
    /// unpaged count under the same filter (for client-side pagination UI).
    func listNodes(limit: Int = 100, offset: Int = 0, kind: String? = nil,
                   includeHubs: Bool = false) throws -> ListedNodes {
        try dbQueue.read { db in
            var sql = "SELECT * FROM node WHERE deleted = 0"
            var args: StatementArguments = []
            if let kind {
                sql += " AND kind = ?"
                args.append(contentsOf: [kind])
            } else if !includeHubs {
                // exclude structural hub anchors from the default Lista view
                sql += " AND kind != ?"
                args.append(contentsOf: [HubKind.hub.rawValue])
            }
            sql += " ORDER BY updatedAt DESC LIMIT ? OFFSET ?"
            args.append(contentsOf: [limit, offset])
            let nodes = try Node.fetchAll(db, sql: sql, arguments: args)

            var countSQL = "SELECT COUNT(*) FROM node WHERE deleted = 0"
            var countArgs: StatementArguments = []
            if let kind {
                countSQL += " AND kind = ?"
                countArgs.append(contentsOf: [kind])
            } else if !includeHubs {
                countSQL += " AND kind != ?"
                countArgs.append(contentsOf: [HubKind.hub.rawValue])
            }
            let total = try Int.fetchOne(db, sql: countSQL, arguments: countArgs) ?? nodes.count
            return ListedNodes(nodes: nodes, total: total)
        }
    }
}
