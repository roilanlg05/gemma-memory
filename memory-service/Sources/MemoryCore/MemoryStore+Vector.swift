import Foundation
import GRDB

/// Embedding storage + KNN. v1 stores float32-LE BLOBs in `node_embedding` and computes
/// cosine distance in Swift (sqlite-vec deferred — see Phase 0). Adequate at personal-memory
/// scale (thousands of vectors). When sqlite-vec is integrated, swap `node_embedding` for a
/// vec0 virtual table and `nearest` for a MATCH query — this interface stays the same.
extension MemoryStore {
    public func setEmbedding(nodeId: String, _ vector: [Float]) throws {
        precondition(vector.count == embeddingDim, "embedding dim mismatch")
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO node_embedding(node_id, embedding) VALUES (?, ?)",
                           arguments: [nodeId, Self.floatsToBlob(vector)])
        }
    }

    /// KNN via cosine similarity. `distance` = 1 - cosine; returns ascending distance.
    public func nearest(to vector: [Float], k: Int) throws -> [(id: String, distance: Double)] {
        let rows: [(String, [Float])] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT node_id, embedding FROM node_embedding")
                .map { ($0["node_id"] as String, Self.blobToFloats($0["embedding"] as Data)) }
        }
        let qn = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        func cosineDistance(_ v: [Float]) -> Double {
            guard v.count == vector.count else { return 2 }
            var dot: Float = 0, n: Float = 0
            for i in 0..<v.count { dot += v[i] * vector[i]; n += v[i] * v[i] }
            let denom = Double(qn) * Double(sqrt(n))
            return denom > 0 ? 1.0 - Double(dot) / denom : 2.0
        }
        return rows.map { (id: $0.0, distance: cosineDistance($0.1)) }
            .sorted { $0.distance < $1.distance }
            .prefix(k)
            .map { $0 }
    }

    /// Cosine distance (1 - cosine) between two equal-length vectors. 2.0 if mismatched/zero.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = Double(sqrt(na)) * Double(sqrt(nb))
        return denom > 0 ? 1.0 - Double(dot) / denom : 2.0
    }

    public static func blobToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public func setTranscriptEmbedding(turnId: String, _ vector: [Float]) throws {
        precondition(vector.count == embeddingDim, "embedding dim mismatch")
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO transcript_embedding(turn_id, embedding) VALUES (?, ?)",
                           arguments: [turnId, Self.floatsToBlob(vector)])
        }
    }

    /// KNN over recent transcript-turn embeddings. distance = 1 - cosine, ascending.
    public func nearestTranscript(to vector: [Float], k: Int) throws -> [(turnId: String, distance: Double)] {
        let rows: [(String, [Float])] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT turn_id, embedding FROM transcript_embedding")
                .map { ($0["turn_id"] as String, Self.blobToFloats($0["embedding"] as Data)) }
        }
        return rows.map { (turnId: $0.0, distance: Self.cosineDistance($0.1, vector)) }
            .sorted { $0.distance < $1.distance }
            .prefix(k).map { $0 }
    }

    public func deleteTranscriptEmbeddings(turnIds: [String]) throws {
        guard !turnIds.isEmpty else { return }
        try dbQueue.write { db in
            let ph = turnIds.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM transcript_embedding WHERE turn_id IN (\(ph))",
                           arguments: StatementArguments(turnIds))
        }
    }
}
