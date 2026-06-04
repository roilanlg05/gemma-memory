import Foundation

/// Pure, deterministic embedding-graph clustering (no model/db). Builds a k-NN similarity
/// graph and runs label propagation for community detection.
public enum Clustering {
    /// Undirected k-NN adjacency: each node nominates its ≤k nearest neighbours within
    /// `maxDistance` (cosine); edges are made symmetric, so a node may end up with degree > k
    /// (inbound nominations from nodes outside its own top-k). O(N²) — fine for N in the hundreds.
    public static func knnGraph(_ embeddings: [(id: String, vec: [Float])], k: Int, maxDistance: Double) -> [String: Set<String>] {
        var adj: [String: Set<String>] = [:]
        for (id, _) in embeddings { adj[id] = [] }
        for (i, a) in embeddings.enumerated() {
            var dists: [(String, Double)] = []
            for (j, b) in embeddings.enumerated() where i != j {
                let d = MemoryStore.cosineDistance(a.vec, b.vec)
                if d <= maxDistance { dists.append((b.id, d)) }
            }
            for (nid, _) in dists.sorted(by: { $0.1 < $1.1 }).prefix(k) {
                adj[a.id, default: []].insert(nid)
                adj[nid, default: []].insert(a.id)
            }
        }
        return adj
    }

    /// Label-propagation community detection. Each node starts in its own community and adopts
    /// the most frequent neighbour label (ties → lexicographically smallest, for determinism),
    /// iterated to convergence. Returns communities of size ≥ `minSize`, each sorted, ordered by
    /// first member.
    public static func labelPropagation(_ adjacency: [String: Set<String>], minSize: Int = 2, maxIterations: Int = 20) -> [[String]] {
        var label: [String: String] = [:]
        let ids = adjacency.keys.sorted()
        for id in ids { label[id] = id }
        for _ in 0..<maxIterations {
            var changed = false
            for id in ids {
                let neighbours = adjacency[id] ?? []
                guard !neighbours.isEmpty else { continue }
                var counts: [String: Int] = [:]
                for n in neighbours { counts[label[n] ?? n, default: 0] += 1 }
                let best = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first!.key
                if label[id] != best { label[id] = best; changed = true }
            }
            if !changed { break }
        }
        var groups: [String: [String]] = [:]
        for (id, lab) in label { groups[lab, default: []].append(id) }
        return groups.values.map { $0.sorted() }.filter { $0.count >= minSize }.sorted { $0[0] < $1[0] }
    }
}
