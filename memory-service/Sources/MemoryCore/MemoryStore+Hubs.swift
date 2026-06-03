import Foundation
import GRDB

/// Hub-and-spoke navigation on top of the existing node/edge tables. One synthetic "kind hub"
/// per `NodeKind`; every live node of that kind is linked back to its hub via `belongsToHub`.
/// Entity nodes (`person`, `place`, …) double as their own hubs for `mentionedIn` traversal.
///
/// Lets queries like "all pending tasks ordered by date" or "everything you know about Roilan"
/// start from a single anchor — much cheaper than full-table scan + filter, and more navigable
/// when the model walks the graph during recall.
public extension MemoryStore {

    /// Stable id for the kind hub. Deterministic so backfills/migrations are idempotent.
    private static func hubId(for kind: NodeKind) -> String { "hub:\(kind.rawValue)" }

    /// Creates one kind-hub node per NodeKind if missing, and links every existing live node
    /// to its kind hub via `belongsToHub` (idempotent — safe to call on every startup).
    @discardableResult
    func ensureKindHubs(now: Double = Date().timeIntervalSince1970) throws -> Int {
        var created = 0
        try dbQueue.write { db in
            for kind in NodeKind.allCases {
                let hubID = Self.hubId(for: kind)
                let existing = try Node.fetchOne(db, key: hubID)
                if existing == nil {
                    let hub = Node(id: hubID,
                                   kind: HubKind.hub.rawValue,
                                   label: kind.hubLabel,
                                   body: "Hub for \(kind.hubLabel.lowercased()) — auto-managed.",
                                   layer: .identity,
                                   createdAt: now, updatedAt: now, lastSeenAt: now,
                                   salience: 0, decayRate: 0, confidence: .sure,
                                   mentionCount: 0, ttlExpiresAt: nil, sourceRef: nil,
                                   origin: .explicit, serverId: nil, dirty: false, deleted: false,
                                   extra: #"{"managesKind":"\#(kind.rawValue)","hub":true}"#)
                    try hub.insert(db)
                    created += 1
                }
            }

            // Backfill belongsToHub edges for every live non-hub node.
            let live = try Node.fetchAll(db, sql:
                "SELECT * FROM node WHERE deleted = 0 AND kind != ?",
                arguments: [HubKind.hub.rawValue])
            for n in live {
                guard let kind = NodeKind(rawValue: n.kind) else { continue }   // free-form kinds skip
                let hubID = Self.hubId(for: kind)
                let exists = try Bool.fetchOne(db, sql:
                    "SELECT 1 FROM edge WHERE srcId = ? AND dstId = ? AND relation = ? AND deleted = 0 LIMIT 1",
                    arguments: [hubID, n.id, Relation.belongsToHub.rawValue]) ?? false
                if !exists {
                    try Edge(id: UUID().uuidString,
                             srcId: hubID, dstId: n.id,
                             relation: .belongsToHub, weight: 1, confidence: .sure,
                             createdAt: now, updatedAt: now,
                             dirty: false, deleted: false, extra: nil).insert(db)
                }
            }
        }
        return created
    }

    /// Add a `belongsToHub` edge from the kind hub to this node. Idempotent — no-op if the edge
    /// already exists. Called automatically from `upsert` / `upsertMergingSemantic` so callers
    /// don't have to remember.
    func linkToHub(nodeId: String, kindRaw: String,
                   now: Double = Date().timeIntervalSince1970) throws {
        guard let kind = NodeKind(rawValue: kindRaw) else { return }
        guard kindRaw != HubKind.hub.rawValue else { return }   // don't link hubs to themselves
        let hubID = Self.hubId(for: kind)
        try dbQueue.write { db in
            // Caller must have invoked ensureKindHubs (production: Services.init does this).
            // If the hub is missing, the auto-link is a no-op — keeps tests that never opted
            // into the hub schema unaffected (no synthetic rows leak into their counts).
            guard try Node.fetchOne(db, key: hubID) != nil else { return }
            let exists = try Bool.fetchOne(db, sql:
                "SELECT 1 FROM edge WHERE srcId = ? AND dstId = ? AND relation = ? AND deleted = 0 LIMIT 1",
                arguments: [hubID, nodeId, Relation.belongsToHub.rawValue]) ?? false
            if !exists {
                try Edge(id: UUID().uuidString,
                         srcId: hubID, dstId: nodeId,
                         relation: .belongsToHub, weight: 1, confidence: .sure,
                         createdAt: now, updatedAt: now,
                         dirty: false, deleted: false, extra: nil).insert(db)
            }
        }
    }

    /// All live nodes of `kind` reachable via belongsToHub edge.
    /// `extraFilter` is a SQL fragment applied to the node row (e.g.
    /// `"json_extract(extra,'$.status') = 'pending'"`); pass nil for no filter.
    /// `orderSQL` overrides the default newest-first ordering.
    func nodesByHub(kind: NodeKind,
                    extraFilter: String? = nil,
                    orderSQL: String = "n.updatedAt DESC",
                    limit: Int = 100) throws -> [Node] {
        try dbQueue.read { db in
            var sql = """
                SELECT n.* FROM node n
                JOIN edge e ON e.dstId = n.id
                WHERE e.srcId = ? AND e.relation = ? AND e.deleted = 0 AND n.deleted = 0
                """
            if let extraFilter { sql += " AND \(extraFilter)" }
            sql += " ORDER BY \(orderSQL) LIMIT ?"
            return try Node.fetchAll(db, sql: sql, arguments: [
                Self.hubId(for: kind), Relation.belongsToHub.rawValue, limit
            ])
        }
    }

    /// All live nodes connected to a named entity (person/place/etc) — both via
    /// `mentionedIn` (entity → mentioned-in node) and any other model-emitted relation
    /// (entity → liked thing, entity → place visited, …).
    func nodesByEntity(label: String, limit: Int = 100) throws -> [Node] {
        try dbQueue.read { db in
            // entity may be the src OR dst — collect both directions, dedupe.
            // Exclude hub anchors (they appear via belongsToHub but are structural, not memory).
            try Node.fetchAll(db, sql: """
                SELECT DISTINCT n.* FROM node n
                JOIN edge e ON (e.dstId = n.id OR e.srcId = n.id)
                JOIN node ent ON ((e.srcId = ent.id AND e.dstId = n.id)
                              OR (e.dstId = ent.id AND e.srcId = n.id))
                WHERE ent.label = ? AND ent.deleted = 0
                  AND n.deleted = 0 AND n.id != ent.id
                  AND n.kind != ?
                  AND e.deleted = 0
                ORDER BY n.updatedAt DESC LIMIT ?
                """, arguments: [label, HubKind.hub.rawValue, limit])
        }
    }
}
