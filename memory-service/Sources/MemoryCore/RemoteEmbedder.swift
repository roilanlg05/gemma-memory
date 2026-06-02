import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client to the BGE-M3 embedder sidecar. Replaces the Apple-only
/// `NLContextualEmbedder` from the iOS/macOS app: in the Docker memory-service
/// the embeddings come from a Python FastAPI sidecar (POST /embed).
///
/// Conforms to ``Embedder`` so the existing dedup/retriever/consolidation
/// callsites work unchanged. The natural unit on the wire is *batched*
/// (`embed(_ texts: [String])`); the single-text method is provided to
/// satisfy the protocol and delegates to the batched one.
public final class RemoteEmbedder: Embedder, @unchecked Sendable {
    public let dimension: Int
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - baseURL: e.g. `http://embedder:8000` (sidecar) or `http://localhost:8000` (dev).
    ///   - dimension: vector dimension produced by the model. BGE-M3 = 1024.
    ///   - session: injectable for tests (URLProtocol stubs).
    ///   - timeout: per-request timeout; the sidecar can be slow on cold start.
    public init(baseURL: URL,
                dimension: Int = 1024,
                session: URLSession = .shared,
                timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.dimension = dimension
        self.session = session
        self.timeout = timeout
    }

    /// Batched embed — the natural transport unit. POSTs `{"texts":[...]}`
    /// to `/embed` and decodes `{"vectors":[[Float]]}`.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        var req = URLRequest(url: baseURL.appendingPathComponent("/embed"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONEncoder().encode(EmbedRequest(texts: texts))
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EmbedderError.remoteFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let payload = try JSONDecoder().decode(EmbedResponse.self, from: data)
        return payload.vectors
    }

    /// Synchronous single-text — required by the existing `Embedder` protocol
    /// (used by dedup/retriever/consolidation). Bridges to the async batched
    /// method via a `DispatchSemaphore`. Callers running on a cooperative
    /// thread should prefer the batched async method directly.
    public func embed(_ text: String) throws -> [Float] {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<[Float], Error> = .failure(EmbedderError.emptyResponse)
        Task {
            do {
                let vs = try await self.embed([text])
                guard let v = vs.first else {
                    result = .failure(EmbedderError.emptyResponse)
                    sem.signal()
                    return
                }
                result = .success(v)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    public enum EmbedderError: Error, Equatable {
        case remoteFailed(status: Int)
        case emptyResponse
    }
    private struct EmbedRequest: Encodable { let texts: [String] }
    private struct EmbedResponse: Decodable { let vectors: [[Float]] }
}
