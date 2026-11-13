import Foundation
import XCTest
import BrainContract
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import MemoryCore
@testable import MemoryService

final class BrainWorkflowEndpointTests: XCTestCase {
    private static let auth: HTTPFields = [.authorization: "Bearer test-token", .contentType: "application/json"]

    private func makeApp() async throws -> (some ApplicationProtocol, Services) {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let services = await Services(store: store, transcript: TranscriptStore(dbQueue: store.dbQueue),
                                      embedder: FakeEmbedder(dimension: 8), bearerToken: "test-token")
        return (try await buildApp(services: services, port: 0), services)
    }

    private static func bytes<T: Encodable>(_ value: T) throws -> ByteBuffer {
        ByteBuffer(bytes: try JSONEncoder().encode(value))
    }

    func testCompletionAndTypedOutcomesAreBoundToTheAdmittedTurn() async throws {
        let (app, services) = try await makeApp()
        let begin = try BrainTurnRequest(clientOperationID: "operation-begin", threadID: "chat",
            message: .init(id: "message", speakerID: "self:user", text: "Recordemos el plano.", observedAt: 20, evidenceIDs: []),
            budget: .init(contextTokens: 5500, outputTokens: 128))
        try await app.test(.live) { client in
            let begun = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth, body: Self.bytes(begin))
            let turn = try JSONDecoder().decode(BrainTurnResult.self, from: Data(begun.body.readableBytesView))
            let completion = try BrainTurnCompletionRequest(clientOperationID: "operation-reply", turnID: turn.turnID,
                assistantText: "Me acuerdo del plano.", evidenceIDs: turn.completion.evidenceIDs)
            let bogus = try BrainTurnCompletionRequest(clientOperationID: "forged-reply", turnID: turn.turnID,
                assistantText: "Esto no debe guardarse.", evidenceIDs: ["forged-evidence"])
            try await client.execute(uri: "/v1/brain/turns/complete", method: .post, body: Self.bytes(completion)) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/brain/turns/complete", method: .post, headers: Self.auth, body: Self.bytes(bogus)) { res in
                XCTAssertEqual(res.status, .forbidden)
            }
            for _ in 0..<2 {
                try await client.execute(uri: "/v1/brain/turns/complete", method: .post, headers: Self.auth, body: Self.bytes(completion)) { res in
                    XCTAssertEqual(res.status, .ok)
                    if res.status == .ok {
                        let result = try JSONDecoder().decode(BrainTurnResult.self, from: Data(res.body.readableBytesView))
                        XCTAssertEqual(result.turnID, turn.turnID)
                        XCTAssertEqual(result.reply, completion.assistantText)
                    }
                }
            }
            struct OutcomeBody: Encodable { let turnID: String; let outcome: BrainOutcome }
            let reported = BrainOutcome(id: "outcome", description: "RAW_DESCRIPTION", status: .unknown, recordedAt: 21,
                                        evidenceIDs: turn.completion.evidenceIDs)
            let forged = BrainOutcome(id: "fabricated", description: "", status: .succeeded, recordedAt: 21,
                                      evidenceIDs: turn.completion.evidenceIDs, observation: .init(operation: .httpCheck, httpStatus: 200))
            try await client.execute(uri: "/v1/brain/outcomes", method: .post, headers: Self.auth,
                body: Self.bytes(OutcomeBody(turnID: turn.turnID, outcome: reported))) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertFalse(String(buffer: res.body).contains("RAW_DESCRIPTION"))
            }
            try await client.execute(uri: "/v1/brain/outcomes", method: .post, headers: Self.auth,
                body: Self.bytes(OutcomeBody(turnID: turn.turnID, outcome: forged))) { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        }
        XCTAssertEqual(try services.transcript.range(threadId: "chat", from: 1, to: 9).map(\.text),
                       ["Recordemos el plano.", "Me acuerdo del plano."])
    }

    func testNativeBeginReturnsStableReceiptWhenOptionalContextDoesNotFit() async throws {
        let (app, services) = try await makeApp()
        let request = try BrainTurnRequest(clientOperationID: "small-context", threadID: "tight",
            message: .init(id: "user-input", speakerID: BrainIdentity.userID, text: "La puerta es verde.",
                           observedAt: 20, evidenceIDs: []),
            budget: .init(contextTokens: 4096, outputTokens: 1024, systemTokens: 3071))
        try await app.test(.live) { client in
            let body = try Self.bytes(request)
            let first = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth, body: body)
            XCTAssertEqual(first.status, .ok)
            guard first.status == .ok else { return }
            let receipt = try JSONDecoder().decode(BrainTurnResult.self, from: Data(first.body.readableBytesView))
            XCTAssertNil(receipt.context)
            XCTAssertEqual(receipt.completion.evidenceIDs.count, 1)

            let replay = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth, body: body)
            XCTAssertEqual(replay.status, .ok)
            let retried = try JSONDecoder().decode(BrainTurnResult.self, from: Data(replay.body.readableBytesView))
            XCTAssertEqual(retried.turnID, receipt.turnID)
            XCTAssertEqual(retried.completion.evidenceIDs, receipt.completion.evidenceIDs)

            let complete = try BrainTurnCompletionRequest(clientOperationID: "small-context-reply",
                turnID: receipt.turnID, assistantText: "Entendido.", evidenceIDs: receipt.completion.evidenceIDs)
            try await client.execute(uri: "/v1/brain/turns/complete", method: .post, headers: Self.auth,
                                     body: Self.bytes(complete)) { response in
                XCTAssertEqual(response.status, .ok)
            }
            let context = try BrainContextRequest(clientOperationID: "explicit-context", threadID: request.threadID,
                                                  query: request.message.text, budget: request.budget)
            try await client.execute(uri: "/v1/brain/context", method: .post, headers: Self.auth,
                                     body: Self.bytes(context)) { response in
                XCTAssertEqual(response.status, .unprocessableContent)
            }
        }
        XCTAssertEqual(try services.transcript.range(threadId: "tight", from: 1, to: 4).map(\.text),
                       ["La puerta es verde.", "Entendido."])
    }

    func testReadOnlyProfileAndProspectiveRoutesEnforceBearerAndScope() async throws {
        let (app, _) = try await makeApp()
        try await app.test(.live) { client in
            let profileURI = "/v1/brain/tastes/profile?domain=music&threadID=one"
            try await client.execute(uri: profileURI, method: .get) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
            try await client.execute(uri: profileURI, method: .get, headers: Self.auth) { res in
                XCTAssertEqual(res.status, .ok)
                if res.status == .ok {
                    let profile = try JSONDecoder().decode(BrainTasteProfile.self, from: Data(res.body.readableBytesView))
                    XCTAssertEqual(profile.subjectID, "self:user")
                    XCTAssertTrue(profile.records.isEmpty)
                }
            }
            try await client.execute(uri: profileURI + "&subjectID=self%3Aagent", method: .get, headers: Self.auth) { res in
                XCTAssertEqual(res.status, .forbidden)
            }
            try await client.execute(uri: "/v1/brain/prospective?revision=999", method: .get, headers: Self.auth) { res in
                XCTAssertEqual(res.status, .conflict)
            }
        }
    }

    func testStagedUpdateIdentityAffectAndForgetWorkflow() async throws {
        let (app, services) = try await makeApp()
        let native = try BrainTurnRequest(clientOperationID: "native-change", threadID: "workflow",
            message: .init(id: "device-message", speakerID: BrainIdentity.userID, text: "Configura tu nombre como Brisa.",
                           observedAt: 4_000_000_000, evidenceIDs: []), budget: .init(contextTokens: 5500, outputTokens: 128))
        try await app.test(.live) { client in
            let begin = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth, body: Self.bytes(native))
            let turn = try JSONDecoder().decode(BrainTurnResult.self, from: Data(begin.body.readableBytesView))
            let source = try XCTUnwrap(services.transcript.range(threadId: "workflow", from: 1, to: 1).first)
            XCTAssertLessThan(source.createdAt, native.message.observedAt)
            let propose = ByteBuffer(string: #"{"turnID":"\#(turn.turnID)"}"#)
            let commit = ByteBuffer(string: #"{"turnID":"\#(turn.turnID)","expectedRevision":\#(turn.completion.revision),"updates":[]}"#)
            try await client.execute(uri: "/v1/brain/updates/propose", method: .post, headers: Self.auth, body: propose) { res in
                XCTAssertEqual(res.status, .ok)
            }
            try await client.execute(uri: "/v1/brain/updates/commit", method: .post, headers: Self.auth, body: commit) { res in
                XCTAssertEqual(res.status, .ok)
                if res.status == .ok {
                    let result = try JSONDecoder().decode(BrainCommitResult.self, from: Data(res.body.readableBytesView))
                    XCTAssertEqual(result.state, .committed)
                }
            }
            try await client.execute(uri: "/v1/brain/identity", method: .get, headers: Self.auth) { res in
                XCTAssertEqual(res.status, .ok)
                if res.status == .ok {
                    let identity = try JSONDecoder().decode(BrainIdentity.self, from: Data(res.body.readableBytesView))
                    XCTAssertEqual(identity.id, BrainIdentity.agentID)
                }
            }
            try await client.execute(uri: "/v1/brain/affect?threadID=workflow", method: .get, headers: Self.auth) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("hypotheses"))
            }
            struct Revision: Encodable { let clientOperationID: String; let expectedRevision: Int64; let change: BrainIdentityChange; let threadID: String }
            let change = BrainIdentityChange.configure(displayName: "Brisa", evidenceIDs: turn.completion.evidenceIDs)
            let stale = Revision(clientOperationID: "stale-identity", expectedRevision: 0, change: change, threadID: "workflow")
            try await client.execute(uri: "/v1/brain/revise", method: .post, headers: Self.auth, body: Self.bytes(stale)) { res in
                XCTAssertEqual(res.status, .conflict)
            }
            let current = Revision(clientOperationID: "identity", expectedRevision: turn.completion.revision, change: change, threadID: "workflow")
            let revised = try await client.execute(uri: "/v1/brain/revise", method: .post, headers: Self.auth, body: Self.bytes(current))
            XCTAssertEqual(revised.status, .ok)
            if revised.status == .ok {
                let identity = try JSONDecoder().decode(BrainIdentity.self, from: Data(revised.body.readableBytesView))
                XCTAssertEqual(identity.displayName, "Brisa")
            }
            let forget = ByteBuffer(string: #"{"clientOperationID":"forget-workflow","expectedRevision":\#(turn.completion.revision + 1),"scope":{"kind":"thread","id":"workflow"}}"#)
            try await client.execute(uri: "/v1/brain/forget", method: .post, headers: Self.auth, body: forget) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertFalse(String(buffer: res.body).contains(native.message.text))
            }
            XCTAssertTrue(try services.transcript.range(threadId: "workflow", from: 1, to: 20).isEmpty)
            try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth, body: Self.bytes(native)) { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        }
    }

    func testConsolidationJobIsAcceptedAndHasAReadableStatus() async throws {
        let (app, _) = try await makeApp()
        try await app.test(.live) { client in
            let body = ByteBuffer(string: #"{"kind":"reflection","timezone":"America/Louisville"}"#)
            let launched = try await client.execute(uri: "/v1/brain/consolidate", method: .post, headers: Self.auth, body: body)
            XCTAssertEqual(launched.status, .accepted)
            if launched.status == .accepted {
                let json = try JSONSerialization.jsonObject(with: Data(launched.body.readableBytesView)) as? [String: Any]
                let job = try XCTUnwrap(json?["jobID"] as? String)
                try await client.execute(uri: "/v1/brain/consolidate?jobID=\(job)", method: .get, headers: Self.auth) { res in
                    XCTAssertEqual(res.status, .ok)
                    XCTAssertTrue(String(buffer: res.body).contains(job))
                }
            }
        }
    }

    func testProspectiveDeferResolveAndReceiptRequireTheExpectedState() async throws {
        let (app, _) = try await makeApp()
        try await app.test(.live) { client in
            var ids: [String] = []
            for label in ["Duda del plano", "Recordatorio del museo"] {
                let saved = try await client.execute(uri: "/v1/memory/save", method: .post, headers: Self.auth,
                    body: ByteBuffer(string: #"{"kind":"clarification","label":"\#(label)"}"#))
                let reply = try JSONDecoder().decode([String: String].self, from: Data(saved.body.readableBytesView))
                ids.append(try XCTUnwrap(reply["id"]))
            }
            let begin = try BrainTurnRequest(clientOperationID: "resolve-turn", threadID: "prospective",
                message: .init(id: "resolve-input", speakerID: BrainIdentity.userID, text: "Resuelve la duda del plano.",
                    observedAt: 20, evidenceIDs: []), budget: .init(contextTokens: 5500, outputTokens: 128))
            let captured = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth,
                body: Self.bytes(begin))
            let turn = try JSONDecoder().decode(BrainTurnResult.self, from: Data(captured.body.readableBytesView))
            let userEvidence = try XCTUnwrap(turn.completion.evidenceIDs.first)
            let unrelated = try BrainTurnRequest(clientOperationID: "other-resolution", threadID: "prospective",
                message: .init(id: "other-input", speakerID: BrainIdentity.userID,
                    text: "Resuelve la duda de Ana sin dar por resuelta Duda del plano.", observedAt: 21, evidenceIDs: []),
                budget: .init(contextTokens: 5500, outputTokens: 128))
            let capturedOther = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth,
                body: Self.bytes(unrelated))
            let other = try JSONDecoder().decode(BrainTurnResult.self, from: Data(capturedOther.body.readableBytesView))
            let otherEvidence = try XCTUnwrap(other.completion.evidenceIDs.first)
            let rejected = BrainProspectiveResolutionRequest(candidateID: ids[0], turnID: other.turnID,
                evidenceID: otherEvidence, expectedRevision: other.completion.revision)
            try await client.execute(uri: "/v1/brain/prospective/resolve", method: .post, headers: Self.auth, body: Self.bytes(rejected)) { res in
                XCTAssertEqual(res.status, .forbidden)
            }
            let deferBody = ByteBuffer(string: #"{"candidateID":"\#(ids[1])","expectedRevision":\#(other.completion.revision),"until":4000000000}"#)
            try await client.execute(uri: "/v1/brain/prospective/defer", method: .post, headers: Self.auth, body: deferBody) { res in
                XCTAssertEqual(res.status, .ok)
            }
            let forged = ByteBuffer(string: #"{"candidateID":"\#(ids[0])","turnID":"\#(turn.turnID)","evidenceID":"not-issued","expectedRevision":\#(other.completion.revision + 1)}"#)
            try await client.execute(uri: "/v1/brain/prospective/resolve", method: .post, headers: Self.auth, body: forged) { res in
                XCTAssertEqual(res.status, .forbidden)
            }
            let resolved = ByteBuffer(string: #"{"candidateID":"\#(ids[0])","turnID":"\#(turn.turnID)","evidenceID":"\#(userEvidence)","expectedRevision":\#(other.completion.revision + 1)}"#)
            try await client.execute(uri: "/v1/brain/prospective/resolve", method: .post, headers: Self.auth, body: resolved) { res in
                XCTAssertEqual(res.status, .ok)
            }
            let read = try await client.execute(uri: "/v1/brain/prospective", method: .get, headers: Self.auth)
            XCTAssertEqual(read.status, .ok)
            let current = try JSONDecoder().decode([String: BrainValue].self, from: Data(read.body.readableBytesView))
            XCTAssertEqual(current["candidates"], .array([]))
            let readReceipt = ByteBuffer(string: #"{"candidateID":"\#(ids[0])","deliveryID":"not-sent"}"#)
            try await client.execute(uri: "/v1/brain/prospective/receipt", method: .post, headers: Self.auth, body: readReceipt) { res in
                XCTAssertEqual(res.status, .conflict)
            }
        }
    }

    func testOwnerCanForgetThreadSupportingNonReservedProjectSubject() async throws {
        let (app, services) = try await makeApp()
        let owner = ConsolidationEvidenceAdapter.ownerID
        let subject = "project:marina"
        let thread = "project-old"
        let grant = BrainAuthorization(principal: owner, owner: owner, subjects: [subject], scopes: [.user],
            threads: [thread], sourceSpeakers: [.userMessage: [BrainIdentity.userID]], mayCommitClaims: true)
        let brain = BrainStore(store: services.store, authorization: grant)
        let source = BrainEvidence(id: "project-evidence", sourceKind: .userMessage, speakerID: BrainIdentity.userID,
            threadID: thread, observedAt: 1, recordedAt: 1, accessScope: .user, text: "Tenemos un borrador.")
        let claim = BrainClaim(id: "project-claim", revision: 0, subject: subject, predicate: "project.checkpoint",
            value: .string("Borrador pendiente de revisión"), modality: .asserted, status: .active, validFrom: 1,
            recordedAt: 1, evidenceIDs: [source.id])
        let saved = try brain.commit(.init(clientOperationID: "project-original", evidence: [source], updates: [.init(claim: claim)], expectedRevision: 0))
        let request = BrainForgetRequest(clientOperationID: "forget-project-thread", expectedRevision: saved.revision,
                                        scope: .init(kind: .thread, id: thread))
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/brain/forget", method: .post, headers: Self.auth, body: Self.bytes(request)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        XCTAssertTrue(try brain.claims(subject: subject, asOf: 100, scope: .user).isEmpty)
    }
}
