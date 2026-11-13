import Foundation

/// Produces a fixed-dim sentence embedding. In the Docker memory-service the production
/// implementation is `RemoteEmbedder` (HTTP call to the BGE-M3 sidecar — added in Task 6).
/// `FakeEmbedder` here keeps unit tests deterministic and dependency-free.
public protocol Embedder: Sendable {
    var dimension: Int { get }
    var indexVersion: EmbeddingIndexVersion? { get }
    func embed(_ text: String) throws -> [Float]
}

public extension Embedder {
    var indexVersion: EmbeddingIndexVersion? { nil }

    func embedForIndex(_ text: String) throws -> IndexEmbedding {
        let version = indexVersion
        let values = try embed(text)
        try MemoryStore.validateEmbedding(values, dimension: version?.dimension ?? dimension)
        return IndexEmbedding(values: values, version: version)
    }
}

public struct IndexEmbedding: Sendable {
    public let values: [Float]
    public let version: EmbeddingIndexVersion?

    public init(values: [Float], version: EmbeddingIndexVersion?) {
        self.values = values
        self.version = version
    }
}

public enum MemoryError: Error { case embedderUnavailable }

/// Deterministic fake for unit tests (no model assets, no network).
public final class FakeEmbedder: Embedder, @unchecked Sendable {
    public let dimension: Int
    public init(dimension: Int = 4) { self.dimension = dimension }
    public func embed(_ text: String) throws -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for (i, ch) in text.unicodeScalars.enumerated() { v[i % dimension] += Float(ch.value % 17) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
