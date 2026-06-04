import Foundation
import GRDB

extension MemoryStore {
    /// Replace all tags for a node (overwrite). Empty/whitespace tags are skipped.
    public func setTags(nodeId: String, _ tags: [String]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM node_tags WHERE node_id = ?", arguments: [nodeId])
            for tag in Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !tag.isEmpty {
                try db.execute(sql: "INSERT OR IGNORE INTO node_tags(node_id, tag) VALUES (?, ?)", arguments: [nodeId, tag])
            }
        }
    }
    public func tagsFor(nodeId: String) throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT tag FROM node_tags WHERE node_id = ? ORDER BY tag", arguments: [nodeId]) }
    }
    public func nodesWithTag(_ tag: String) throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT node_id FROM node_tags WHERE tag = ? ORDER BY node_id", arguments: [tag]) }
    }
    public func distinctTags() throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT DISTINCT tag FROM node_tags ORDER BY tag") }
    }
}
