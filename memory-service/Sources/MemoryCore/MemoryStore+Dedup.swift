import Foundation
import GRDB

/// Consolidation: dedup/merge on write (human memory consolidates, doesn't accumulate
/// duplicates) + a forgetting sweep. Built on the Phase 1 MemoryStore CRUD + Phase 2 Decay.
extension MemoryStore {
    /// Atomic memory kinds that can cross-deduplicate (e.g. preference vs fact for the same entity).
    public static let atomicKinds: Set<String> = [
        NodeKind.person.rawValue, NodeKind.place.rawValue, NodeKind.fact.rawValue,
        NodeKind.preference.rawValue, NodeKind.trait.rawValue
    ]

    /// Helper to prevent merging distinct occurrences (e.g. tasks/events with explicitly different dates).
    private func isSameOccurrence(existing: Node, candidate: Node?) -> Bool {
        guard let candidate else { return true }
        let eDate = NodeAttributes.from(existing.extra).date
        let cDate = NodeAttributes.from(candidate.extra).date
        if let eDate, let cDate, eDate != cDate {
            return false
        }
        return true
    }

    /// Find an existing non-deleted node to merge into, by (kind, canonical label). Uses
    /// MemoryText.dedupKey so "Sushi", "sushi" and "me gusta el sushi" all collapse together —
    /// the cause of the duplicate "Juan ×3 / sushi ×N" rows seen on device.
    /// For atomic kinds (person, place, fact, preference, trait), matches across atomic kinds.
    public func findDuplicate(kind: String, label: String, candidate: Node? = nil) throws -> Node? {
        let key = MemoryText.dedupKey(label)
        let isAtomic = Self.atomicKinds.contains(kind)
        return try dbQueue.read { db in
            let nodes: [Node]
            if isAtomic {
                nodes = try Node.filter(Column("deleted") == false)
                    .fetchAll(db)
                    .filter { Self.atomicKinds.contains($0.kind) }
            } else {
                nodes = try Node.filter(Column("kind") == kind && Column("deleted") == false)
                    .fetchAll(db)
            }
            return nodes.first { MemoryText.dedupKey($0.label) == key && isSameOccurrence(existing: $0, candidate: candidate) }
        }
    }

    /// Upsert with dedup: if a duplicate exists, reinforce it (bump salience, mentionCount++,
    /// maybe promote to identity); else insert the candidate. Returns the resulting node id.
    @discardableResult
    public func upsertMerging(_ candidate: Node) throws -> String {
        if let existing = try findDuplicate(kind: candidate.kind, label: candidate.label, candidate: candidate) {
            let merged = mergeReinforced(existing: existing, candidate: candidate)
            try upsert(merged)
            return merged.id
        } else {
            try upsert(candidate)
            return candidate.id
        }
    }

    /// Nearest same-kind (or atomic-kind), non-deleted node within `threshold` cosine distance, or nil.
    /// Fetches a generous candidate set (k=64) and filters AFTER, so a duplicate ranked beyond top-8
    /// isn't silently missed.
    public func findSemanticDuplicate(kind: String, embedding: [Float], threshold: Double, candidate: Node? = nil) throws -> Node? {
        let isAtomic = Self.atomicKinds.contains(kind)
        for hit in try nearest(to: embedding, k: 64) where hit.distance <= threshold {
            if let n = try node(id: hit.id), !n.deleted {
                let matchesKind = (n.kind == kind) || (isAtomic && Self.atomicKinds.contains(n.kind) && candidate != nil && MemoryText.dedupKey(n.label) == MemoryText.dedupKey(candidate!.label))
                if matchesKind && isSameOccurrence(existing: n, candidate: candidate) {
                    return n
                }
            }
        }
        return nil
    }

    /// Upsert with SEMANTIC dedup (falls back to string dedup): merge into the nearest same-kind
    /// node within `threshold`, else the canonical-label match, else insert. Reinforces via EMA.
    @discardableResult
    public func upsertMergingSemantic(_ candidate: Node, embedding: [Float]?, embedder: Embedder?,
                                      threshold: Double = 0.2) throws -> String {
        // Fix 2: accept either a precomputed embedding OR an embedder — if no embedding was
        // passed but we have an embedder, compute one from the candidate label.
        var embedding = embedding
        if embedding == nil, let embedder { embedding = try? embedder.embed(candidate.label) }

        var existing: Node? = nil
        if let embedding { existing = try findSemanticDuplicate(kind: candidate.kind, embedding: embedding, threshold: threshold, candidate: candidate) }
        if existing == nil { existing = try findDuplicate(kind: candidate.kind, label: candidate.label, candidate: candidate) }

        if let existing {
            let merged = mergeReinforced(existing: existing, candidate: candidate)
            try upsert(merged)
            // Fix 3: don't leave a merged node embedding-less. Re-setting a vector for the same
            // cluster is harmless, so always store the embedding on merge when we have one —
            // this lets future semantic dedup find a node first seen via string-only match.
            if let embedding { try setEmbedding(nodeId: merged.id, embedding) }
            return merged.id
        } else {
            try upsert(candidate)
            if let embedding { try setEmbedding(nodeId: candidate.id, embedding) }
            return candidate.id
        }
    }

    /// Shared merge: EMA-reinforce salience, bump mentionCount, refresh times, promote if due.
    private func mergeReinforced(existing: Node, candidate: Node) -> Node {
        var merged = existing
        // Upgrade generic `fact` to a more specific atomic kind if candidate is specific
        if existing.kind == NodeKind.fact.rawValue && candidate.kind != NodeKind.fact.rawValue && Self.atomicKinds.contains(candidate.kind) {
            merged.kind = candidate.kind
        }
        merged.salience = Decay.reinforceEMA(current: existing.salience, beta: Decay.beta(for: existing.layer))
        merged.mentionCount = existing.mentionCount + 1
        merged.lastSeenAt = candidate.lastSeenAt
        merged.updatedAt = candidate.updatedAt
        if merged.body.isEmpty { merged.body = candidate.body }
        if Decay.shouldPromote(mentionCount: merged.mentionCount, origin: merged.origin,
                               permanent: merged.layer == .identity) {
            merged.layer = .identity
            merged.ttlExpiresAt = nil
            merged.decayRate = Decay.defaultDecayRate(for: .identity)
        }
        // Summaries: adopt the latest segment's reference so expand_context drill-down points at
        // the most recent conversation behind the topic (extra holds threadId/turnRange/concepts).
        // Scoped to summary kind — entity `extra` (NodeAttributes) must keep the existing value.
        if merged.kind == NodeKind.summary.rawValue, let e = candidate.extra, !e.isEmpty {
            merged.extra = e
        }
        merged.dirty = true
        return merged
    }

    /// Sweep existing insight, task, follow_up, and summary nodes, and merge near-duplicates (cosine distance <= threshold).
    /// Keeps the highest-salience node as canonical, sums mentionCount, soft-deletes the rest with a
    /// `sameAs` edge to the canonical. Non-destructive. Idempotent. Returns the total number merged.
    @discardableResult
    public func compressInsights(embedder: Embedder?, threshold: Double = 0.15) throws -> Int {
        let kindsToCompress: [String] = [
            NodeKind.insight.rawValue,
            NodeKind.task.rawValue,
            NodeKind.followUp.rawValue,
            NodeKind.summary.rawValue
        ]
        var totalMerged = 0
        for kind in kindsToCompress {
            let t = (kind == NodeKind.summary.rawValue) ? 0.10 : threshold
            totalMerged += try compressKind(kind, embedder: embedder, threshold: t)
        }
        return totalMerged
    }

    private func compressKind(_ kind: String, embedder: Embedder?, threshold: Double) throws -> Int {
        let nodes = try allNodes()
            .filter { $0.kind == kind && !$0.deleted }
            .sorted { ($0.salience, Double($0.mentionCount)) > ($1.salience, Double($1.mentionCount)) }
        var kept: [(id: String, emb: [Float])] = []
        var merged = 0
        let t = Date().timeIntervalSince1970
        for n in nodes {
            guard let emb = try embeddingFor(nodeId: n.id, label: n.label, embedder: embedder) else { continue }
            if let hit = kept.first(where: { Self.cosineDistance($0.emb, emb) <= threshold }) {
                if var canon = try node(id: hit.id) {
                    canon.mentionCount += n.mentionCount
                    canon.salience = max(canon.salience, n.salience)
                    canon.updatedAt = t; canon.dirty = true
                    try upsert(canon)
                }
                try softDelete(nodeId: n.id)
                try upsert(Edge(id: UUID().uuidString, srcId: n.id, dstId: hit.id, relation: .sameAs,
                                weight: 1, confidence: .probable, createdAt: t, updatedAt: t,
                                dirty: true, deleted: false, extra: nil))
                merged += 1
            } else {
                try setEmbedding(nodeId: n.id, emb)
                kept.append((n.id, emb))
            }
        }
        return merged
    }

    /// Stored embedding for a node, else freshly embedded from its label, else nil.
    private func embeddingFor(nodeId: String, label: String, embedder: Embedder?) throws -> [Float]? {
        let stored: Data? = try dbQueue.read { db -> Data? in
            guard let row = try Row.fetchOne(db, sql: "SELECT embedding FROM node_embedding WHERE node_id = ?",
                                             arguments: [nodeId]) else { return nil }
            return row["embedding"] as Data
        }
        if let stored { return Self.blobToFloats(stored) }
        return try embedder?.embed(label)
    }

    /// Upsert the singleton self/user identity node (fixed id "self:user"). Always exactly one.
    /// Subsequent calls reinforce the existing node; the id never changes.
    @discardableResult
    public func upsertSelf(name: String, detail: String? = nil, embedder: Embedder? = nil,
                           now: Double = Date().timeIntervalSince1970) throws -> String {
        let id = selfUserID
        let label = MemoryText.canonicalEntityLabel(name)
        if var existing = try node(id: id) {
            if !label.isEmpty { existing.label = label }
            if let detail, !detail.isEmpty { existing.body = detail }
            existing.updatedAt = now; existing.lastSeenAt = now; existing.deleted = false; existing.dirty = true
            existing.mentionCount += 1   // reinforce like every other "seen again" path
            try upsert(existing)
        } else {
            let newNode = Node(id: id, kind: NodeKind.selfUser.rawValue, label: label,
                               body: detail ?? "", layer: .identity, createdAt: now,
                               updatedAt: now, lastSeenAt: now, salience: 10, decayRate: 0,
                               confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                               sourceRef: nil, origin: .explicit, serverId: nil,
                               dirty: true, deleted: false, extra: nil)
            try upsert(newNode)
        }
        if let embedder, let emb = try? embedder.embed(label) { try? setEmbedding(nodeId: id, emb) }
        return id
    }

    /// Returns the singleton self/user identity node, or nil if not yet created.
    public func selfNode() throws -> Node? { try node(id: selfUserID) }

    /// Forgetting sweep: soft-delete nodes whose effective salience fell below the floor
    /// or whose TTL expired (identity is never forgotten).
    public func sweep(now: Double = Date().timeIntervalSince1970) throws {
        for n in try allNodes() {
            let eff = Decay.effectiveSalience(base: n.salience, decayRate: n.decayRate,
                                              elapsedSeconds: now - n.lastSeenAt)
            if Decay.shouldForget(layer: n.layer, effectiveSalience: eff,
                                  ttlExpiresAt: n.ttlExpiresAt, now: now) {
                try softDelete(nodeId: n.id)
            }
        }
    }
}
