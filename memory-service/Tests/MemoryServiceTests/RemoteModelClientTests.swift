import XCTest
@testable import MemoryService
@testable import MemoryCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLProtocol stub that captures the outgoing request (URL/headers/body) and returns a canned
/// OpenAI chat-completions JSON. URLProtocol strips `httpBody`, so the body is read from
/// `httpBodyStream`.
final class CaptureStub: URLProtocol {
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    static func reset() { lastRequest = nil; lastBody = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CaptureStub.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            CaptureStub.lastBody = data
        } else {
            CaptureStub.lastBody = request.httpBody
        }

        let json = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: json)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CaptureStub.self]
    return URLSession(configuration: config)
}

final class RemoteModelClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CaptureStub.reset()
    }

    func test_cloudConfig_addsAuth_andNoQuirk() async throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        try cfg.save(provider: "groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-x", apiKey: "K")
        let session = makeStubSession()
        let client = RemoteModelClient(configStore: cfg, defaultBaseURL: URL(string: "http://localhost:8080/v1")!,
                                       defaultModel: "gemma", session: session)
        _ = try await client.generate(prompt: "hi", options: .init())
        let req = CaptureStub.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer K")
        let body = try JSONSerialization.jsonObject(with: CaptureStub.lastBody!) as! [String: Any]
        XCTAssertNil(body["chat_template_kwargs"])
        XCTAssertEqual(body["model"] as? String, "llama-x")
    }

    func test_emptyConfig_usesDefaultLocal_withQuirk_noAuth() async throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        let session = makeStubSession()
        let client = RemoteModelClient(configStore: cfg, defaultBaseURL: URL(string: "http://localhost:8080/v1")!,
                                       defaultModel: "gemma", session: session)
        _ = try await client.generate(prompt: "hi", options: .init())
        let req = CaptureStub.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:8080/v1/chat/completions")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONSerialization.jsonObject(with: CaptureStub.lastBody!) as! [String: Any]
        XCTAssertNotNil(body["chat_template_kwargs"])
    }
}
