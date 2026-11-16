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

    private final class CountingEmbedder: Embedder, @unchecked Sendable {
        let dimension = 8
        private let lock = NSLock()
        private var calls: [String] = []

        func embed(_ text: String) throws -> [Float] {
            lock.withLock { calls.append(text) }
            return try FakeEmbedder(dimension: dimension).embed(text)
        }

        func count(_ text: String) -> Int {
            lock.withLock { calls.filter { $0 == text }.count }
        }
    }

    func testNativePrefetchOnlyReusesExactQueryForItsOwnTurnAndThread() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let embedder = CountingEmbedder()
        let transcript = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: transcript, embedder: embedder, bearerToken: "test-token")
        let app = try await buildApp(services: services, port: 0)
        let budget = try BrainContextBudget(contextTokens: 5500, outputTokens: 128)
        let same = "Recuerda la maqueta color azul."
        let corrected = "Recuerda la maqueta color verde."
        let changedThread = "Recuerda el proyecto Molino."
        let unrelatedOperation = "Recuerda el proyecto Semilla."
        let readOnly = "Recuerda el proyecto Faro."

        try await app.test(.router) { client in
            let samples = [
                ("same", "same-chat", "same", "same-chat", same, same, "prefetch", 1),
                ("changed", "changed-chat", "changed", "changed-chat", same, corrected, "prefetch", 1),
                ("thread", "draft-chat", "thread", "other-chat", changedThread, changedThread, "prefetch", 2),
                ("draft", "different-op-chat", "other-op", "different-op-chat", unrelatedOperation, unrelatedOperation, "prefetch", 2),
                ("read-only", "lookup-chat", "read-only", "lookup-chat", readOnly, readOnly, "cue", 2),
            ]
            for (cueID, cueThread, operationID, threadID, cueText, finalText, mode, expected) in samples {
                let cue = try BrainContextRequest(clientOperationID: cueID, threadID: cueThread, query: cueText,
                    budget: budget, quoteEvidenceIDs: [], detailEvidenceIDs: [])
                let cueResult = try await client.execute(uri: "/v1/brain/context?mode=\(mode)", method: .post,
                                                        headers: Self.auth, body: Self.bytes(cue))
                XCTAssertEqual(cueResult.status, .ok)
                XCTAssertTrue(try transcript.range(threadId: cueThread, from: 1, to: 4).isEmpty)

                let turn = try BrainTurnRequest(clientOperationID: operationID, threadID: threadID,
                    message: .init(id: "message-\(operationID)", speakerID: BrainIdentity.userID, text: finalText,
                                   observedAt: 1, evidenceIDs: []), budget: budget)
                let result = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth,
                                                      body: Self.bytes(turn))
                XCTAssertEqual(result.status, .ok)
                XCTAssertEqual(embedder.count(finalText), expected, "\(cueID)")
                XCTAssertEqual(try transcript.range(threadId: threadID, from: 1, to: 4).map(\.text), [finalText])
            }
        }
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

    func testNativeSmallWindowDeliversProjectCheckpointAndStartupOrientation() async throws {
        let (app, services) = try await makeApp()
        let owner = ConsolidationEvidenceAdapter.ownerID
        let subject = "project:aurora"
        let prior = "previous-chat"
        let brain = BrainStore(store: services.store, authorization: .init(principal: owner, owner: owner,
            subjects: [subject], scopes: [.user], threads: [prior],
            sourceSpeakers: [.userMessage: [BrainIdentity.userID]], mayCommitClaims: true))
        for (index, predicate, value, text) in [(1, "project.name", "Aurora", "Empezamos el proyecto Aurora."),
                                                (2, "project.checkpoint", "Falta validar la importación.", "Terminamos revisando el plano.")] {
            let source = BrainEvidence(id: "prior-source-\(index)", sourceKind: .userMessage, speakerID: BrainIdentity.userID,
                threadID: prior, observedAt: Double(index), recordedAt: Double(index), accessScope: .user, text: text)
            let claim = BrainClaim(id: "project-\(index)", revision: 0, subject: subject, predicate: predicate, value: .string(value),
                modality: .asserted, status: .active, validFrom: Double(index), recordedAt: Double(index), evidenceIDs: [source.id])
            let result = try brain.commit(.init(clientOperationID: "seed-\(index)", evidence: [source],
                updates: [.init(claim: claim)], expectedRevision: brain.revision()))
            XCTAssertEqual(result.state, .committed)
        }
        let request = try BrainTurnRequest(clientOperationID: "project-resume", threadID: "fresh-chat",
            message: .init(id: "input", speakerID: BrainIdentity.userID, text: "Sigamos con el proyecto Aurora.",
                           observedAt: 3, evidenceIDs: []),
            budget: .init(contextTokens: 4096, outputTokens: 396, systemTokens: 900, toolTokens: 800))
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth,
                                                    body: Self.bytes(request))
            XCTAssertEqual(response.status, .ok)
            let result = try JSONDecoder().decode(BrainTurnResult.self, from: Data(response.body.readableBytesView))
            let bundle = try XCTUnwrap(result.context)
            XCTAssertTrue(bundle.renderedContext.contains("Falta validar la importación."), bundle.renderedContext)
            XCTAssertTrue(bundle.renderedContext.contains("previous exchange opening orientation"), bundle.renderedContext)
            XCTAssertTrue(bundle.renderedContext.contains("previous exchange closing orientation"), bundle.renderedContext)
            XCTAssertTrue(bundle.recentMessageUnits.isEmpty)
            let accounting = try XCTUnwrap(bundle.accounting)
            XCTAssertLessThanOrEqual(accounting.estimatedInputTokens + accounting.reservedOutputTokens
                                     + accounting.reservedSystemTokens + accounting.reservedToolTokens, 4096)
        }
    }

    func testNativeRecallAcrossChatsFindsRecentAndYearOldUnconsolidatedMessages() async throws {
        let (app, services) = try await makeApp()
        let now = Date().timeIntervalSince1970
        let history = [
            ("old-chat", now - 365 * 86_400, "La receta de berenjenas llevaba tahini y limón."),
            ("dental-chat", now - 650, "Me puedes agendar un evento para mañana a la 1:30: limpieza con el dentista."),
            ("retry-chat", now - 120, "Oye, créame el evento que te pedí anteriormente"),
            ("other-chat", now - 60, "Puse música para cocinar."),
            ("new-chat-3", now - 30, "Hola")
        ]
        for (thread, timestamp, text) in history {
            let prior = try BrainTurnRequest(clientOperationID: "seed-" + thread, threadID: thread,
                message: .init(id: "input", speakerID: BrainIdentity.userID, text: text, observedAt: timestamp, evidenceIDs: []),
                budget: .init(contextTokens: 4096, outputTokens: 256))
            let grant = services.brain.grant(threadID: thread, write: true)
            let brain = BrainStore(store: services.store, authorization: grant)
            let journal = BrainTurnStore(brain: brain)
            let turn = try journal.capture(prior)
            if thread == "new-chat-3" {
                _ = try journal.assistant(turnID: turn, operationID: "greeting-reply",
                    text: "Hola. Aquí estoy. ¿Qué necesitas?", timestamp: timestamp + 1)
            }
            if thread == "old-chat" {
                _ = try journal.assistant(turnID: turn, operationID: "seed-old-reply",
                    text: "Para las berenjenas te recomiendo pimentón ahumado.", timestamp: timestamp + 1)
            }
        }

        let oldRow = try XCTUnwrap(services.transcript.range(threadId: "old-chat", from: 1, to: 1).first)
        try await app.test(.router) { client in
            for (index, query, expected) in [
                (0, "Oye, créame el evento que te pedí anteriormente", "limpieza con el dentista"),
                (1, "¿Qué te dije de la receta de berenjenas hace un año?", "tahini y limón"),
                (2, "¿Qué me recomendaste para las berenjenas hace un año?", "pimentón ahumado"),
                (3, "Q continuemos agendando el evento", "limpieza con el dentista"),
                (4, "Retomemos lo de la receta de berenjenas", "tahini y limón")
            ] {
                let ampleRequest = try BrainContextRequest(clientOperationID: "probe-\(index)", threadID: "new-chat-\(index)",
                    query: query, budget: .init(contextTokens: 8192, outputTokens: 396))
                let ample = try await services.brain.context(ampleRequest, semanticSelection: false)
                XCTAssertTrue(ample.renderedContext.contains(expected), "Ample window for \(index): \(ample.renderedContext)")
                let request = try BrainTurnRequest(clientOperationID: "recall-\(index)", threadID: "new-chat-\(index)",
                    message: .init(id: "input", speakerID: BrainIdentity.userID, text: query, observedAt: now, evidenceIDs: []),
                    budget: .init(contextTokens: 4096, outputTokens: 396, systemTokens: 900, toolTokens: index == 3 ? 900 : 1600))
                let response = try await client.execute(uri: "/v1/brain/turns/begin", method: .post, headers: Self.auth,
                                                        body: Self.bytes(request))
                XCTAssertEqual(response.status, .ok)
                let result = try JSONDecoder().decode(BrainTurnResult.self, from: Data(response.body.readableBytesView))
                let bundle = try XCTUnwrap(result.context)
                let label = index == 2 ? "prior assistant reply on" : "prior user message on"
                XCTAssertTrue(bundle.renderedContext.contains(label), "Compact window for \(index): \(bundle.renderedContext)")
                XCTAssertTrue(bundle.renderedContext.contains(expected), "Compact window for \(index): \(bundle.renderedContext)")
                XCTAssertFalse(bundle.renderedContext.contains("Puse música"), bundle.renderedContext)
                if index == 3 {
                    // The client already has the greeting in its local buffer.
                    XCTAssertTrue(bundle.recentMessageUnits.allSatisfy {
                        $0.text == "Hola" || $0.text == "Hola. Aquí estoy. ¿Qué necesitas?"
                    })
                } else {
                    XCTAssertTrue(bundle.recentMessageUnits.isEmpty)
                }
                XCTAssertTrue(bundle.exactCitationSourceReferences(includingRenderedContext: true, forwardedRecentUnitIDs: []).isEmpty)
            }

            let grant = services.brain.grant(threadID: "old-chat", forget: true)
            let brain = BrainStore(store: services.store, authorization: grant)
            let forgotten = try BrainRetractionService(brain: brain).forget(
                scope: .init(kind: .evidence, id: ConsolidationEvidenceAdapter.evidenceID(for: oldRow)),
                expectedRevision: brain.revision(), operationID: "forget-recipe")
            XCTAssertEqual(forgotten.state, .committed)
            let query = try BrainContextRequest(clientOperationID: "after-forget", threadID: "new-after-forget",
                query: "¿Qué te dije de la receta de berenjenas hace un año?",
                budget: .init(contextTokens: 4096, outputTokens: 396))
            let context = try await services.brain.context(query, semanticSelection: false)
            XCTAssertFalse(context.renderedContext.contains("tahini"))
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
