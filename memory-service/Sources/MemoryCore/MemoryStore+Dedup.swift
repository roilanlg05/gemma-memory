import Foundation
import GRDB

/// An unresolved alternative is evidence to consider, never an accepted replacement.
/// Stored additively in Node.extra until source-bound claims become available.
struct MemoryMergeConflict: Codable, Equatable {
    var label: String
    var body: String
    var sourceRef: String?
    var origin: Origin
    var confidence: Confidence
    var updatedAt: Double
    var extra: String?
}

enum MemoryMergeError: Error {
    case incompatibleSubject(String)
}

/// Consolidation: dedup/merge on write (human memory consolidates, doesn't accumulate
/// duplicates) + a forgetting sweep. Built on the Phase 1 MemoryStore CRUD + Phase 2 Decay.
extension MemoryStore {
    /// Atomic memory kinds that can cross-deduplicate (e.g. preference vs fact for the same entity).
    public static let atomicKinds: Set<String> = [
        NodeKind.person.rawValue, NodeKind.place.rawValue, NodeKind.fact.rawValue,
        NodeKind.preference.rawValue, NodeKind.trait.rawValue
    ]

    private static func extraObject(_ extra: String?) -> [String: Any] {
        guard let data = extra?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func mergeConflicts(in node: Node) -> [MemoryMergeConflict] {
        guard let values = extraObject(node.extra)["mergeConflicts"],
              let data = try? JSONSerialization.data(withJSONObject: values),
              let conflicts = try? JSONDecoder().decode([MemoryMergeConflict].self, from: data) else { return [] }
        return conflicts
    }

    static func evidenceDate(for node: Node) -> Double {
        (extraObject(node.extra)["memoryEvidenceUpdatedAt"] as? Double) ?? node.updatedAt
    }

    private func revision(of node: Node) -> MemoryMergeConflict {
        var extra = node.extra
        var object = Self.extraObject(extra)
        if object["mergeConflicts"] != nil || object["memoryEvidenceUpdatedAt"] != nil {
            object.removeValue(forKey: "mergeConflicts")
            object.removeValue(forKey: "memoryEvidenceUpdatedAt")
            extra = object.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        return MemoryMergeConflict(label: node.label, body: node.body, sourceRef: node.sourceRef,
                                   origin: node.origin, confidence: node.confidence,
                                   updatedAt: Self.evidenceDate(for: node), extra: extra)
    }

    private func metadata(extra: String?, conflicts: [MemoryMergeConflict], evidenceDate: Double? = nil) -> String? {
        guard !conflicts.isEmpty || evidenceDate != nil else { return extra }
        var object = Self.extraObject(extra)
        // Preserve an opaque legacy extra rather than discard it when adding integrity metadata.
        if object.isEmpty, let extra, !extra.isEmpty, extra != "{}" { object["legacyExtra"] = extra }
        if !conflicts.isEmpty, let data = try? JSONEncoder().encode(conflicts),
           let values = try? JSONSerialization.jsonObject(with: data) { object["mergeConflicts"] = values }
        if let evidenceDate { object["memoryEvidenceUpdatedAt"] = evidenceDate }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Explicit scope is authoritative. Missing scope cannot fill in a known owner/subject.
    private func isSameSubject(existing: Node, candidate: Node) -> Bool {
        let reserved: Set<String> = [selfUserID, "self:agent", "relationship:user:agent"]
        if existing.id != candidate.id, reserved.contains(existing.id) || reserved.contains(candidate.id) { return false }
        func scope(_ node: Node, keys: [String]) -> (values: Set<String>, valid: Bool) {
            let object = Self.extraObject(node.extra)
            var values = Set<String>()
            for key in keys where object[key] != nil {
                guard let value = object[key] as? String, !value.isEmpty else { return ([], false) }
                values.insert(value)
            }
            return (values, values.count <= 1)
        }
        let subjects = ["subjectId", "subjectID", "subject"]
        let owners = ["ownerId", "ownerID", "owner"]
        let es = scope(existing, keys: subjects), cs = scope(candidate, keys: subjects)
        let eo = scope(existing, keys: owners), co = scope(candidate, keys: owners)
        guard es.valid, cs.valid, eo.valid, co.valid, es.values == cs.values, eo.values == co.values else { return false }
        // Shared ownership is not proof that two identity nodes describe the same subject.
        if existing.id != candidate.id, existing.layer == .identity || candidate.layer == .identity,
           es.values.isEmpty { return false }
        return true
    }

    private func sameIDTarget(for candidate: Node) throws -> Node? {
        guard let existing = try node(id: candidate.id) else { return nil }
        guard isSameSubject(existing: existing, candidate: candidate) else {
            throw MemoryMergeError.incompatibleSubject(candidate.id)
        }
        return existing.deleted ? nil : existing
    }

    /// Order evidence only when one valid range extends beyond the other in the same thread.
    /// Consolidation timestamps alone cannot establish which summary is faithful.
    private func summaryEvidenceOrder(existing: Node, candidate: Node) -> Int? {
        func range(_ node: Node) -> (String, [Int])? {
            let object = Self.extraObject(node.extra)
            guard let thread = object["threadId"] as? String, !thread.isEmpty,
                  let range = object["turnRange"] as? [Int], range.count == 2,
                  range[0] >= 0, range[1] >= range[0] else { return nil }
            return (thread, range)
        }
        guard let e = range(existing), let c = range(candidate), e.0 == c.0 else { return nil }
        if c.1[0] >= e.1[0], c.1[1] > e.1[1] { return 1 }
        if c.1[0] <= e.1[0], c.1[1] < e.1[1] { return -1 }
        return nil
    }

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
            return nodes.first { existing in
                MemoryText.dedupKey(existing.label) == key && isSameOccurrence(existing: existing, candidate: candidate)
                    && (candidate.map { isSameSubject(existing: existing, candidate: $0) } ?? true)
            }
        }
    }

    /// Upsert with dedup: if a duplicate exists, reinforce it (bump salience, mentionCount++,
    /// preserve deliberate identity); else insert the candidate. Returns the resulting node id.
    @discardableResult
    public func upsertMerging(_ candidate: Node) throws -> String {
        if let existing = try sameIDTarget(for: candidate)
            ?? findDuplicate(kind: candidate.kind, label: candidate.label, candidate: candidate) {
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
                if matchesKind && isSameOccurrence(existing: n, candidate: candidate)
                    && (candidate.map { isSameSubject(existing: n, candidate: $0) } ?? true) {
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

        var existing = try sameIDTarget(for: candidate)
        if existing == nil, let embedding { existing = try findSemanticDuplicate(kind: candidate.kind, embedding: embedding, threshold: threshold, candidate: candidate) }
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

    /// Salience may increase with repetition; authority and identity never do.
    private func mergeReinforced(existing: Node, candidate: Node) -> Node {
        var merged = existing
        if existing.kind == NodeKind.fact.rawValue && candidate.kind != NodeKind.fact.rawValue && Self.atomicKinds.contains(candidate.kind) {
            merged.kind = candidate.kind
        }
        merged.salience = Decay.reinforceEMA(current: existing.salience, beta: Decay.beta(for: existing.layer))
        merged.mentionCount = existing.mentionCount + 1
        merged.lastSeenAt = max(existing.lastSeenAt, candidate.lastSeenAt)
        merged.updatedAt = max(existing.updatedAt, candidate.updatedAt)
        var conflicts = Self.mergeConflicts(in: existing)
        func retain(_ alternative: MemoryMergeConflict) {
            // Repeated copies of one proposal do not create additional independent evidence.
            if !conflicts.contains(where: {
                $0.body == alternative.body && $0.label == alternative.label && $0.sourceRef == alternative.sourceRef
                    && $0.origin == alternative.origin && $0.confidence == alternative.confidence && $0.extra == alternative.extra
            }) { conflicts.append(alternative) }
        }
        for alternative in Self.mergeConflicts(in: candidate) { retain(alternative) }

        if existing.kind == NodeKind.summary.rawValue && candidate.kind == NodeKind.summary.rawValue {
            if summaryEvidenceOrder(existing: existing, candidate: candidate) == 1 {
                merged.label = candidate.label
                merged.body = candidate.body
                merged.extra = candidate.extra
                merged.sourceRef = candidate.sourceRef
                merged.origin = candidate.origin
                merged.confidence = candidate.confidence
                merged.updatedAt = candidate.updatedAt
            } else {
                merged.updatedAt = existing.updatedAt
                if summaryEvidenceOrder(existing: existing, candidate: candidate) == nil,
                   existing.body != candidate.body || existing.extra != candidate.extra || existing.sourceRef != candidate.sourceRef {
                    retain(revision(of: candidate))
                }
            }
            merged.extra = metadata(extra: merged.extra, conflicts: conflicts)
        } else {
            var evidenceDate = Self.evidenceDate(for: existing)
            if existing.body.isEmpty, !candidate.body.isEmpty {
                merged.body = candidate.body
                merged.extra = candidate.extra
                merged.sourceRef = candidate.sourceRef
                merged.origin = candidate.origin
                merged.confidence = candidate.confidence
                evidenceDate = Self.evidenceDate(for: candidate)
            } else if !candidate.body.isEmpty, candidate.body != existing.body {
                retain(revision(of: candidate))
            }
            merged.extra = metadata(extra: merged.extra, conflicts: conflicts, evidenceDate: evidenceDate)
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
        var kept: [(node: Node, emb: [Float])] = []
        var merged = 0
        let t = Date().timeIntervalSince1970
        for n in nodes {
            guard let emb = try embeddingFor(nodeId: n.id, label: n.label, embedder: embedder) else { continue }
            if let hit = kept.first(where: {
                Self.cosineDistance($0.emb, emb) <= threshold && isSameSubject(existing: $0.node, candidate: n)
                    && isSameOccurrence(existing: $0.node, candidate: n)
            }) {
                if let canonical = try node(id: hit.node.id) {
                    var canon = mergeReinforced(existing: canonical, candidate: n)
                    canon.mentionCount = canonical.mentionCount + n.mentionCount
                    canon.salience = max(canonical.salience, n.salience)
                    try upsert(canon)
                }
                try softDelete(nodeId: n.id)
                try upsert(Edge(id: UUID().uuidString, srcId: n.id, dstId: hit.node.id, relation: .sameAs,
                                weight: 1, confidence: .probable, createdAt: t, updatedAt: t,
                                dirty: true, deleted: false, extra: nil))
                merged += 1
            } else {
                try setEmbedding(nodeId: n.id, emb)
                kept.append((n, emb))
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
