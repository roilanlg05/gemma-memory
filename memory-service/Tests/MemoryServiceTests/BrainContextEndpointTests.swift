import Foundation
import XCTest
import BrainContract
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import MemoryCore
@testable import MemoryService

final class BrainContextEndpointTests: XCTestCase {
    private static let uri = "/v1/brain/context"
    private static let authenticated: HTTPFields = [.authorization: "Bearer test-token", .contentType: "application/json"]

    private func makeApp() async throws -> (some ApplicationProtocol, TranscriptStore) {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let transcript = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: transcript,
                                      embedder: FakeEmbedder(dimension: 8), bearerToken: "test-token")
        return (try await buildApp(services: services, port: 0), transcript)
    }

    private static func requestBody(quoteIDs: [String], window: Int = 5500) throws -> ByteBuffer {
        let request = try BrainContextRequest(clientOperationID: "context-1", threadID: "context", query: "Cita",
                                              budget: .init(contextTokens: window, outputTokens: 64),
                                              quoteEvidenceIDs: quoteIDs)
        return ByteBuffer(bytes: try JSONEncoder().encode(request))
    }

    func testAuthenticatedCallerReceivesSelectedOriginalAndSeparateRecentPrefixOverHTTP() async throws {
        let (app, transcript) = try await makeApp()
        let exact = "Dije: «¡Ese columpio!» 🛝"
        let oversized = String(repeating: "Texto largo 🛝 ", count: 700)
        let foreign = "Solo en el otro hilo."
        try transcript.append(threadId: "context", turnIndex: 1, role: "user", text: oversized, now: 1)
        try transcript.append(threadId: "context", turnIndex: 2, role: "user", text: exact, now: 2)
        try transcript.append(threadId: "foreign", turnIndex: 1, role: "user", text: foreign, now: 3)
        let exactID = ConsolidationEvidenceAdapter.evidenceID(threadID: "context", seq: 2, text: exact)
        let oversizedID = ConsolidationEvidenceAdapter.evidenceID(threadID: "context", seq: 1, text: oversized)
        let foreignID = ConsolidationEvidenceAdapter.evidenceID(threadID: "foreign", seq: 1, text: foreign)
        let validBody = try Self.requestBody(quoteIDs: [exactID, oversizedID])
        let foreignBody = try Self.requestBody(quoteIDs: [foreignID])
        let tinyBody = try Self.requestBody(quoteIDs: [exactID], window: 256)
        let tooManyBody = try Self.requestBody(quoteIDs: Array(repeating: exactID, count: 65))
        try await app.test(.live) { client in
            try await client.execute(uri: Self.uri, method: .post, body: validBody) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
            try await client.execute(uri: Self.uri, method: .post, headers: Self.authenticated, body: foreignBody) { res in
                XCTAssertEqual(res.status, .forbidden)
                XCTAssertFalse(String(buffer: res.body).contains(foreign))
            }
            try await client.execute(uri: Self.uri, method: .post, headers: Self.authenticated, body: tinyBody) { res in
                XCTAssertEqual(res.status, .unprocessableContent)
                XCTAssertTrue(String(buffer: res.body).contains("insufficient_budget"))
            }
            try await client.execute(uri: Self.uri, method: .post, headers: Self.authenticated, body: tooManyBody) { res in
                XCTAssertEqual(res.status, .badRequest)
            }
            try await client.execute(uri: Self.uri, method: .post, headers: Self.authenticated, body: validBody) { res in
                XCTAssertEqual(res.status, .ok)
                let data = Data(res.body.readableBytesView)
                let bundle = try JSONDecoder().decode(BrainContextBundle.self, from: data)
                XCTAssertTrue(bundle.renderedContext.contains("[original quote source=\(exactID)]\n" + exact))
                XCTAssertFalse(bundle.renderedContext.contains("[original quote source=\(oversizedID)]"))
                XCTAssertFalse(bundle.sourceReferences.contains { $0.id == foreignID })
                let omission = try XCTUnwrap(bundle.truncations?.first { $0.reason == "quoteOmittedBudget" })
                XCTAssertEqual(omission.evidenceID, oversizedID)
                XCTAssertTrue(bundle.sourceReferences.contains { $0.id == omission.evidenceID })
                let prefix = try XCTUnwrap(bundle.recentMessageUnits.first { $0.id == oversizedID }?.text)
                XCTAssertFalse(prefix.isEmpty)
                XCTAssertTrue(oversized.hasPrefix(prefix))
                XCTAssertLessThan(prefix.utf8.count, oversized.utf8.count)
                XCTAssertEqual(bundle.sourceUses?[oversizedID], [.recentPrefix])
                XCTAssertEqual(bundle.sourceUses?[exactID], [.renderedQuote, .recentWhole])
                XCTAssertEqual(bundle.recentMessageUnits.first { $0.id == exactID }?.text, exact)
                XCTAssertEqual(bundle.exactCitationSourceReferences(includingRenderedContext: true, forwardedRecentUnitIDs: []).map(\.id), [exactID])
                XCTAssertTrue(bundle.exactCitationSourceReferences(includingRenderedContext: false, forwardedRecentUnitIDs: [oversizedID]).isEmpty)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(bundle.accounting).estimatedInputTokens, data.count + 4 + 64)
            }
        }
        XCTAssertEqual(try transcript.count(), 3)
    }
}
