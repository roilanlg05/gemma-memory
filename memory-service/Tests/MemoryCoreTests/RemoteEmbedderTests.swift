import XCTest
import Foundation
@testable import MemoryCore

final class RemoteEmbedderTests: XCTestCase {
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var stub: (URLRequest) -> (HTTPURLResponse, Data) = { _ in
            (HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (res, data) = Self.stub(request)
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    func test_embed_posts_to_embed_endpoint_and_decodes_vectors() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/embed")
            // Read body — URLProtocol stubs receive httpBodyStream for streamed bodies
            let body = req.httpBody ?? (req.httpBodyStream.flatMap { Data(reading: $0) } ?? Data())
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["texts"] as? [String], ["hola"])
            let payload = #"{"vectors":[[0.1, 0.2, 0.3]]}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!
            return (res, payload)
        }
        let e = RemoteEmbedder(baseURL: URL(string: "http://embedder:8000")!,
                                session: makeSession())
        let vecs = try await e.embed(["hola"])
        XCTAssertEqual(vecs, [[0.1, 0.2, 0.3]])
    }

    func test_embed_throws_on_5xx() async throws {
        StubProtocol.stub = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (res, Data())
        }
        let e = RemoteEmbedder(baseURL: URL(string: "http://embedder:8000")!,
                                session: makeSession())
        do {
            _ = try await e.embed(["hola"])
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    func test_versioned_embedder_requires_exact_response_identity_and_shape() async throws {
        let expected = EmbeddingIndexVersion(modelID: "test/a", dimension: 3, revision: "one")
        let embedder = RemoteEmbedder(baseURL: URL(string: "http://embedder:8000")!, dimension: 3,
                                      indexVersion: expected, session: makeSession())
        let cases: [(String, Bool)] = [
            (#"{"version":{"modelID":"test/a","dimension":3,"revision":"one"},"vectors":[[1,0,0]]}"#, true),
            (#"{"version":{"modelID":"test/b","dimension":3,"revision":"one"},"vectors":[[1,0,0]]}"#, false),
            (#"{"version":{"modelID":"test/a","dimension":3,"revision":"two"},"vectors":[[1,0,0]]}"#, false),
            (#"{"vectors":[[1,0,0]]}"#, false),
            (#"{"version":{"modelID":"test/a","dimension":3,"revision":"one"},"vectors":[[1,0]]}"#, false),
            (#"{"version":{"modelID":"test/a","dimension":3,"revision":"one"},"vectors":[]}"#, false)
        ]
        for (body, shouldSucceed) in cases {
            StubProtocol.stub = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            do {
                let vectors = try await embedder.embed(["hello"])
                XCTAssertTrue(shouldSucceed, "Unexpectedly accepted \(body)")
                XCTAssertEqual(vectors, [[1, 0, 0]])
            } catch {
                XCTAssertFalse(shouldSucceed, "Unexpected error \(error)")
            }
        }
    }
}

private extension Data {
    init(reading stream: InputStream) {
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        self = data
    }
}
