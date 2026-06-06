import XCTest
@testable import MemoryService
@testable import MemoryCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ToolCallingClientTests: XCTestCase {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var json = "{}"
        nonisolated(unsafe) static var status = 200
        override class func canInit(with r: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let res = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.json.data(using: .utf8)!)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> ToolCallingClient {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        return ToolCallingClient(configStore: nil, defaultBaseURL: URL(string: "http://localhost:8080/v1")!,
                                 defaultModel: "m", session: URLSession(configuration: cfg))
    }

    func test_non2xx_throws_remoteFailed() async throws {
        Stub.status = 500; defer { Stub.status = 200 }
        Stub.json = "{}"
        do {
            _ = try await makeClient().complete(systemPrompt: "s", userPrompt: "hi", tools: [])
            XCTFail("expected throw")
        } catch RemoteModelClient.ModelClientError.remoteFailed(let status) {
            XCTAssertEqual(status, 500)
        }
    }

    func test_parses_text_reply() async throws {
        Stub.json = #"{"choices":[{"message":{"content":"hi there"}}]}"#
        let r = try await makeClient().complete(systemPrompt: "s", userPrompt: "hi", tools: [])
        XCTAssertEqual(r.text, "hi there")
        XCTAssertTrue(r.toolCalls.isEmpty)
    }

    func test_parses_tool_call() async throws {
        Stub.json = #"{"choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"current_time","arguments":"{}"}}]}}]}"#
        let r = try await makeClient().complete(systemPrompt: "s", userPrompt: "what time", tools: [])
        XCTAssertEqual(r.toolCalls.map { $0.name }, ["current_time"])
        XCTAssertEqual(r.toolCalls.first?.args, "{}")
    }
}
