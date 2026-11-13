import Foundation
import GRDB

/// Embedding storage + KNN. v1 stores float32-LE BLOBs in `node_embedding` and computes
/// cosine distance in Swift (sqlite-vec deferred — see Phase 0). Adequate at personal-memory
/// scale (thousands of vectors). When sqlite-vec is integrated, swap `node_embedding` for a
/// vec0 virtual table and `nearest` for a MATCH query — this interface stays the same.
extension MemoryStore {
    public func setEmbedding(nodeId: String, _ vector: [Float]) throws {
        try Self.validateEmbedding(vector, dimension: embeddingDim)
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO node_embedding(node_id, embedding) VALUES (?, ?)",
                           arguments: [nodeId, Self.floatsToBlob(vector)])
        }
    }

    public static func nodeEmbeddingText(_ node: Node) -> String {
        if node.body.isEmpty || node.body.utf8.elementsEqual(node.label.utf8) { return node.label }
        return node.label + "\n" + node.body
    }

    public func setEmbedding(nodeId: String, _ vector: [Float], version: EmbeddingIndexVersion,
                             sourceText: String) throws {
        try setVersionedEmbedding(.init(kind: .node, id: nodeId, text: sourceText), vector, version: version)
    }

    public func setEmbedding(nodeId: String, _ embedding: IndexEmbedding, sourceText: String) throws {
        if let version = embedding.version {
            try setEmbedding(nodeId: nodeId, embedding.values, version: version, sourceText: sourceText)
        } else {
            try setLiveLegacyEmbedding(.init(kind: .node, id: nodeId, text: sourceText), embedding.values)
        }
    }

    /// KNN via cosine similarity. `distance` = 1 - cosine; returns ascending distance.
    public func nearest(to vector: [Float], k: Int) throws -> [(id: String, distance: Double)] {
        try nearest(to: vector, k: k, version: nil)
    }

    public func nearest(to vector: [Float], k: Int, version: EmbeddingIndexVersion?) throws -> [(id: String, distance: Double)] {
        try nearestEmbeddings(to: vector, k: k, version: version, kind: .node)
    }

    public func nearest(to embedding: IndexEmbedding, k: Int) throws -> [(id: String, distance: Double)] {
        try nearest(to: embedding.values, k: k, version: embedding.version)
    }

    /// Cosine distance (1 - cosine) between two equal-length vectors. 2.0 if mismatched/zero.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for (lhs, rhs) in zip(a, b) {
            let x = Double(lhs), y = Double(rhs)
            dot += x * y
            na += x * x
            nb += y * y
        }
        let denom = sqrt(na) * sqrt(nb)
        return denom.isFinite && denom > 0 ? 1 - min(1, max(-1, dot / denom)) : 2
    }

    public static func blobToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public func setTranscriptEmbedding(turnId: String, _ vector: [Float]) throws {
        try Self.validateEmbedding(vector, dimension: embeddingDim)
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO transcript_embedding(turn_id, embedding) VALUES (?, ?)",
                           arguments: [turnId, Self.floatsToBlob(vector)])
        }
    }

    public func setTranscriptEmbedding(turnId: String, _ vector: [Float], version: EmbeddingIndexVersion,
                                       sourceText: String) throws {
        try setVersionedEmbedding(.init(kind: .transcript, id: turnId, text: sourceText), vector, version: version)
    }

    public func setTranscriptEmbedding(turnId: String, _ embedding: IndexEmbedding, sourceText: String) throws {
        if let version = embedding.version {
            try setTranscriptEmbedding(turnId: turnId, embedding.values, version: version, sourceText: sourceText)
        } else {
            try setLiveLegacyEmbedding(.init(kind: .transcript, id: turnId, text: sourceText), embedding.values)
        }
    }

    /// KNN over recent transcript-turn embeddings. distance = 1 - cosine, ascending.
    public func nearestTranscript(to vector: [Float], k: Int) throws -> [(turnId: String, distance: Double)] {
        try nearestTranscript(to: vector, k: k, version: nil)
    }

    public func nearestTranscript(to vector: [Float], k: Int, version: EmbeddingIndexVersion?) throws -> [(turnId: String, distance: Double)] {
        try nearestEmbeddings(to: vector, k: k, version: version, kind: .transcript).map { ($0.id, $0.distance) }
    }

    public func nearestTranscript(to embedding: IndexEmbedding, k: Int) throws -> [(turnId: String, distance: Double)] {
        try nearestEmbeddings(to: embedding.values, k: k, version: embedding.version, kind: .transcript,
                              liveLegacyTranscriptOnly: true).map { ($0.id, $0.distance) }
    }

    /// All stored node embeddings (one query) — input for clustering.
    public func allEmbeddings(version: EmbeddingIndexVersion? = nil) throws -> [(id: String, vec: [Float])] {
        try dbQueue.read { db in
            try Self.embeddingRows(.node, version: version, db: db)
        }
    }

    func storedEmbedding(nodeID: String, version: EmbeddingIndexVersion?) throws -> [Float]? {
        try dbQueue.read { db in
            try Self.embeddingRows(.node, version: version, sourceID: nodeID, db: db).first?.vec
        }
    }

    public func canUseEmbeddingIndex(_ version: EmbeddingIndexVersion?) throws -> Bool {
        guard let version else { return true }
        return try dbQueue.read { db in try Self.activeEmbeddingIndexID(version, db: db) != nil }
    }

    private func setVersionedEmbedding(_ source: EmbeddingSource, _ values: [Float], version: EmbeddingIndexVersion) throws {
        try Self.validateEmbedding(values, dimension: version.dimension)
        try dbQueue.write { db in
            guard let indexID = try Self.activeEmbeddingIndexID(version, db: db) else { throw EmbeddingIndexError.indexNotActive }
            try source.write(values, indexID: indexID, db: db)
        }
    }

    private func setLiveLegacyEmbedding(_ source: EmbeddingSource, _ values: [Float]) throws {
        try Self.validateEmbedding(values, dimension: embeddingDim)
        try dbQueue.write { db in
            try source.requireCurrent(in: db)
            try db.execute(sql: """
                INSERT OR REPLACE INTO \(source.kind.legacyTable)(\(source.kind.idColumn), embedding) VALUES (?, ?)
                """, arguments: [source.id, Self.floatsToBlob(values)])
        }
    }

    private func nearestEmbeddings(to vector: [Float], k: Int, version: EmbeddingIndexVersion?,
                                   kind: EmbeddingSource.Kind,
                                   liveLegacyTranscriptOnly: Bool = false) throws -> [(id: String, distance: Double)] {
        try Self.validateEmbedding(vector, dimension: version?.dimension ?? embeddingDim)
        guard k > 0 else { return [] }
        let rows = try dbQueue.read { db in
            try Self.embeddingRows(kind, version: version, liveLegacyTranscriptOnly: liveLegacyTranscriptOnly, db: db)
        }
        return rows.filter { $0.vec.count == vector.count && $0.vec.allSatisfy(\.isFinite) }
            .map { (id: $0.id, distance: Self.cosineDistance($0.vec, vector)) }
            .sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
            .prefix(k).map { $0 }
    }

    private static func embeddingRows(_ kind: EmbeddingSource.Kind, version: EmbeddingIndexVersion?,
                                      sourceID: String? = nil, liveLegacyTranscriptOnly: Bool = false,
                                      db: Database) throws -> [(id: String, vec: [Float])] {
        let idFilter = sourceID == nil ? "" : " AND e.\(kind.idColumn) = ?"
        let sourceArguments = sourceID.map { StatementArguments([$0]) } ?? StatementArguments()
        let rows: [Row]
        if let version {
            guard let indexID = try activeEmbeddingIndexID(version, db: db) else { return [] }
            rows = try Row.fetchAll(db, sql: """
                SELECT e.\(kind.idColumn) AS id, e.embedding FROM \(kind.indexedTable) e
                JOIN \(kind.sourceView) s ON s.id = e.\(kind.idColumn) WHERE e.index_id = ?\(idFilter)
                """, arguments: StatementArguments([indexID]) + sourceArguments)
        } else {
            let liveFilter: String
            switch kind {
            case .node:
                liveFilter = " JOIN node n ON n.id = e.node_id WHERE n.deleted = 0"
            case .transcript:
                liveFilter = liveLegacyTranscriptOnly ? " JOIN embedding_transcript_source s ON s.id = e.turn_id WHERE 1" : " WHERE 1"
            }
            rows = try Row.fetchAll(db, sql: """
                SELECT e.\(kind.idColumn) AS id, e.embedding FROM \(kind.legacyTable) e\(liveFilter)\(idFilter)
                """, arguments: sourceArguments)
        }
        return rows.map { ($0["id"], blobToFloats($0["embedding"])) }
    }

    public func deleteTranscriptEmbeddings(turnIds: [String]) throws {
        guard !turnIds.isEmpty else { return }
        try dbQueue.write { db in
            let ph = turnIds.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM transcript_embedding WHERE turn_id IN (\(ph))",
                           arguments: StatementArguments(turnIds))
            try db.execute(sql: "DELETE FROM indexed_transcript_embedding WHERE turn_id IN (\(ph))",
                           arguments: StatementArguments(turnIds))
        }
    }
}
