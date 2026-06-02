import Foundation
import GRDB

/// Nodes + edges snapshot for the graph view. Backs the read-only `/v1/graph`
/// inspector endpoint (consumed by the macOS `MemoryGraphView`).
public extension MemoryStore {
    struct LoadedGraph: Encodable, Sendable {
        public let nodes: [Node]
        public let edges: [Edge]
        public init(nodes: [Node], edges: [Edge]) {
            self.nodes = nodes
            self.edges = edges
        }
    }

    /// Returns the most recently updated `nodeLimit` live nodes plus every live edge
    /// between them. Defaults sized so the force-directed view is responsive
    /// (~300 nodes is the practical ceiling for the existing layout in the app).
    func loadGraph(nodeLimit: Int = 300) throws -> LoadedGraph {
        try dbQueue.read { db in
            let nodes = try Node.fetchAll(db, sql: """
                SELECT * FROM node WHERE deleted = 0
                ORDER BY updatedAt DESC LIMIT ?
                """, arguments: [nodeLimit])
            let nodeIds = nodes.map(\.id)
            guard !nodeIds.isEmpty else { return LoadedGraph(nodes: [], edges: []) }
            // Edges between live nodes only — IN (?, ?, ?, ...) lets SQLite pick the index.
            let placeholders = Array(repeating: "?", count: nodeIds.count).joined(separator: ",")
            let dbArgs: [any DatabaseValueConvertible] = (nodeIds + nodeIds).map { $0 as any DatabaseValueConvertible }
            let edges = try Edge.fetchAll(db, sql: """
                SELECT * FROM edge WHERE deleted = 0
                AND srcId IN (\(placeholders))
                AND dstId IN (\(placeholders))
                """, arguments: StatementArguments(dbArgs))
            return LoadedGraph(nodes: nodes, edges: edges)
        }
    }
}
