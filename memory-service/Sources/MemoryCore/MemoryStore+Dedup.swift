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
        let accessScopes = ["scope", "accessScope", "access_scope"]
        let threads = ["threadID", "threadId", "thread_id", "chatId", "chat_id"]
        let es = scope(existing, keys: subjects), cs = scope(candidate, keys: subjects)
        let eo = scope(existing, keys: owners), co = scope(candidate, keys: owners)
        guard es.valid, cs.valid, eo.valid, co.valid, es.values == cs.values, eo.values == co.values else { return false }
        let ea = scope(existing, keys: accessScopes), ca = scope(candidate, keys: accessScopes)
        let et = scope(existing, keys: threads), ct = scope(candidate, keys: threads)
        guard ea.valid, ca.valid, ea.values == ca.values else { return false }
        // Legacy summaries use threadId as a provenance locator and keep unordered revisions
        // as conflicts. A declared access scope still fences those summaries like other records.
        let unscopedSummaries = ea.values.isEmpty && existing.kind == NodeKind.summary.rawValue && candidate.kind == NodeKind.summary.rawValue
        if !unscopedSummaries, (!et.valid || !ct.valid || et.values != ct.values) { return false }
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

    private static func managedNodeIDs(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT node_id FROM brain_projection UNION SELECT node_id FROM brain_legacy_binding"))
    }

    /// Find an existing non-deleted node to merge into, by (kind, canonical label). Uses
    /// MemoryText.dedupKey so "Sushi", "sushi" and "me gusta el sushi" all collapse together —
    /// the cause of the duplicate "Juan ×3 / sushi ×N" rows seen on device.
    /// For atomic kinds (person, place, fact, preference, trait), matches across atomic kinds.
    public func findDuplicate(kind: String, label: String, candidate: Node? = nil) throws -> Node? {
        let key = MemoryText.dedupKey(label)
        let isAtomic = Self.atomicKinds.contains(kind)
        return try dbQueue.read { db in
            let managed = try Self.managedNodeIDs(db)
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
                !managed.contains(existing.id) && MemoryText.dedupKey(existing.label) == key && isSameOccurrence(existing: existing, candidate: candidate)
                    && (candidate.map { isSameSubject(existing: existing, candidate: $0) } ?? true)
            }
        }
    }

    /// Upsert with dedup: if a duplicate exists, reinforce it (bump salience, mentionCount++,
    /// preserve deliberate identity); else insert the candidate. Returns the resulting node id.
    @discardableResult
    public func upsertMerging(_ candidate: Node,
                              checkpoint: ConsolidationCheckpoint? = nil) throws -> String {
        if let existing = try sameIDTarget(for: candidate)
            ?? findDuplicate(kind: candidate.kind, label: candidate.label, candidate: candidate) {
            let merged = mergeReinforced(existing: existing, candidate: candidate)
            try upsert(merged, checkpoint: checkpoint)
            return merged.id
        } else {
            try upsert(candidate, checkpoint: checkpoint)
            return candidate.id
        }
    }

    /// Nearest same-kind (or atomic-kind), non-deleted node within `threshold` cosine distance, or nil.
    /// Fetches a generous candidate set (k=64) and filters AFTER, so a duplicate ranked beyond top-8
    /// isn't silently missed.
    public func findSemanticDuplicate(kind: String, embedding: [Float], threshold: Double, candidate: Node? = nil) throws -> Node? {
        try findSemanticDuplicate(kind: kind, embedding: IndexEmbedding(values: embedding, version: nil),
                                  threshold: threshold, candidate: candidate)
    }

    private func findSemanticDuplicate(kind: String, embedding: IndexEmbedding,
                                       threshold: Double, candidate: Node?) throws -> Node? {
        let isAtomic = Self.atomicKinds.contains(kind)
        let managed = try dbQueue.read { try Self.managedNodeIDs($0) }
        // Managed vectors must not crowd eligible legacy candidates out of the top 64.
        for hit in try nearest(to: embedding, k: 64 + managed.count) where hit.distance <= threshold && !managed.contains(hit.id) {
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
                                      threshold: Double = 0.2,
                                      checkpoint: ConsolidationCheckpoint? = nil) throws -> String {
        let candidateText = Self.nodeEmbeddingText(candidate)
        let version = embedder?.indexVersion
        let queryEmbedding: IndexEmbedding?
        if let version {
            // The old precomputed argument has no model identity. Obtain named vectors directly
            // from the compatible embedder and the same source text used by a rebuild.
            queryEmbedding = (try? canUseEmbeddingIndex(version)) == true ? try? embedder?.embedForIndex(candidateText) : nil
        } else if let embedding {
            queryEmbedding = .init(values: embedding, version: nil)
        } else {
            queryEmbedding = try? embedder?.embedForIndex(candidate.label)
        }

        var existing = try sameIDTarget(for: candidate)
        var embeddingRevision: Int64?
        if existing == nil, let queryEmbedding {
            if let version = queryEmbedding.version {
                if let state = try? embeddingIndexState(), state.version == version {
                    existing = try? findSemanticDuplicate(kind: candidate.kind, embedding: queryEmbedding,
                                                          threshold: threshold, candidate: candidate)
                    if existing != nil { embeddingRevision = state.revision }
                }
            } else {
                existing = try? findSemanticDuplicate(kind: candidate.kind, embedding: queryEmbedding,
                                                      threshold: threshold, candidate: candidate)
            }
        }
        if existing == nil { existing = try findDuplicate(kind: candidate.kind, label: candidate.label, candidate: candidate) }

        let retained = existing.map { mergeReinforced(existing: $0, candidate: candidate) } ?? candidate
        do {
            try upsert(retained, checkpoint: checkpoint, embeddingRevision: embeddingRevision)
        } catch EmbeddingIndexError.staleRevision {
            return try upsertMerging(candidate, checkpoint: checkpoint)
        }
        if let queryEmbedding {
            let retainedText = Self.nodeEmbeddingText(retained)
            let retainedEmbedding: IndexEmbedding?
            if queryEmbedding.version == nil || retainedText.utf8.elementsEqual(candidateText.utf8) {
                retainedEmbedding = queryEmbedding
            } else {
                retainedEmbedding = try? embedder?.embedForIndex(retainedText)
            }
            if let retainedEmbedding {
                try? setEmbedding(nodeId: retained.id, retainedEmbedding, sourceText: retainedText)
            }
        }
        return retained.id
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
                // Compare source metadata without internal conflict bookkeeping or JSON key order.
                func normalizedExtra(_ node: Node) -> String? {
                    let extra = revision(of: node).extra
                    guard let data = extra?.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data),
                          JSONSerialization.isValidJSONObject(object),
                          let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    else { return extra }
                    return String(data: normalized, encoding: .utf8)
                }
                if summaryEvidenceOrder(existing: existing, candidate: candidate) == nil,
                   existing.body != candidate.body || normalizedExtra(existing) != normalizedExtra(candidate) || existing.sourceRef != candidate.sourceRef {
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
        let version = embedder?.indexVersion
        let revision: Int64?
        if let version {
            let state = try embeddingIndexState()
            guard state.version == version else { return 0 }
            revision = state.revision
        } else {
            revision = nil
        }
        let nodes = try allNodes()
            .filter { $0.kind == kind && !$0.deleted }
            .sorted { ($0.salience, Double($0.mentionCount)) > ($1.salience, Double($1.mentionCount)) }
        var kept: [(node: Node, emb: [Float])] = []
        var merged = 0
        let t = Date().timeIntervalSince1970
        for n in nodes {
            let sourceText = Self.nodeEmbeddingText(n)
            let stored = try storedEmbedding(nodeID: n.id, version: version)
            let fresh = stored == nil ? try? embedder?.embedForIndex(version == nil ? n.label : sourceText) : nil
            guard let emb = stored ?? fresh.flatMap({ $0.version == version ? $0.values : nil }) else { continue }
            if let hit = kept.first(where: {
                Self.cosineDistance($0.emb, emb) <= threshold && isSameSubject(existing: $0.node, candidate: n)
                    && isSameOccurrence(existing: $0.node, candidate: n)
            }) {
                do {
                    let didMerge = try dbQueue.write { db in
                        try Self.requireEmbeddingRevision(revision, db: db)
                        guard let canonical = try Node.fetchOne(db, key: hit.node.id), !canonical.deleted,
                              let duplicate = try Node.fetchOne(db, key: n.id), !duplicate.deleted,
                              Self.nodeEmbeddingText(canonical).utf8.elementsEqual(Self.nodeEmbeddingText(hit.node).utf8),
                              Self.nodeEmbeddingText(duplicate).utf8.elementsEqual(sourceText.utf8),
                              isSameSubject(existing: canonical, candidate: duplicate),
                              isSameOccurrence(existing: canonical, candidate: duplicate),
                              try !Self.managedNodeIDs(db).contains(duplicate.id)
                        else { return false }
                        var canon = mergeReinforced(existing: canonical, candidate: duplicate)
                        canon.mentionCount = canonical.mentionCount + duplicate.mentionCount
                        canon.salience = max(canonical.salience, duplicate.salience)
                        try Self.writeNode(canon, db: db)
                        try Self.softDelete(nodeId: duplicate.id, db: db)
                        try Edge(id: UUID().uuidString, srcId: duplicate.id, dstId: canonical.id, relation: .sameAs,
                                 weight: 1, confidence: .probable, createdAt: t, updatedAt: t,
                                 dirty: true, deleted: false, extra: nil).save(db)
                        return true
                    }
                    if didMerge {
                        try? linkToHub(nodeId: hit.node.id, kindRaw: hit.node.kind)
                        merged += 1
                    }
                } catch EmbeddingIndexError.staleRevision {
                    return merged
                }
            } else {
                try? setEmbedding(nodeId: n.id, IndexEmbedding(values: emb, version: version), sourceText: sourceText)
                kept.append((n, emb))
            }
        }
        return merged
    }

    /// Upsert the singleton self/user identity node (fixed id "self:user"). Always exactly one.
    /// Subsequent calls reinforce the existing node; the id never changes.
    ///
    /// `sourceRef` binds the identity to the evidence that established it. Consolidation always
    /// supplies it (see `SelfAssertionValidator`); a direct user edit through `/v1/memory/save`
    /// is its own authority and may leave it nil.
    @discardableResult
    public func upsertSelf(name: String, detail: String? = nil, embedder: Embedder? = nil,
                           now: Double = Date().timeIntervalSince1970,
                           sourceRef: String? = nil) throws -> String {
        let id = selfUserID
        let label = MemoryText.canonicalEntityLabel(name)
        if var existing = try node(id: id) {
            if !label.isEmpty { existing.label = label }
            if let detail, !detail.isEmpty { existing.body = detail }
            if let sourceRef { existing.sourceRef = sourceRef }
            existing.updatedAt = now; existing.lastSeenAt = now; existing.deleted = false; existing.dirty = true
            existing.mentionCount += 1   // reinforce like every other "seen again" path
            try upsert(existing)
        } else {
            let newNode = Node(id: id, kind: NodeKind.selfUser.rawValue, label: label,
                               body: detail ?? "", layer: .identity, createdAt: now,
                               updatedAt: now, lastSeenAt: now, salience: 10, decayRate: 0,
                               confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                               sourceRef: sourceRef, origin: .explicit, serverId: nil,
                               dirty: true, deleted: false, extra: nil)
            try upsert(newNode)
        }
        if let embedder, (try? canUseEmbeddingIndex(embedder.indexVersion)) == true,
           let saved = try node(id: id) {
            let sourceText = Self.nodeEmbeddingText(saved)
            if let emb = try? embedder.embedForIndex(embedder.indexVersion == nil ? label : sourceText) {
                try? setEmbedding(nodeId: id, emb, sourceText: sourceText)
            }
        }
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
