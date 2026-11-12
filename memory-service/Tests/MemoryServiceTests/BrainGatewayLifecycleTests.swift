import Foundation
import GRDB
import XCTest
import BrainContract
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import MemoryCore
@testable import MemoryService

final class BrainGatewayLifecycleTests: XCTestCase {
    private static let auth: HTTPFields = [.authorization: "Bearer test-token", .contentType: "application/json"]

    private actor Observations {
        struct Call: Sendable {
            let system: String
            let user: String
            let rows: [TranscriptRow]
        }
        var calls: [Call] = []

        func record(_ call: Call) -> Int {
            calls.append(call)
            return calls.count
        }
    }

    private final class RecordingClient: AgentModelClient, Sendable {
        struct Unavailable: Error {}
        let observations = Observations()
        let transcript: TranscriptStore
        let threadID: String
        let answer: String?
        let firstTool: AgentToolCall?
        let secondTool: AgentToolCall?
        let beforeResult: (@Sendable (Int) throws -> Void)?

        init(transcript: TranscriptStore, threadID: String, answer: String?, firstTool: AgentToolCall? = nil,
             secondTool: AgentToolCall? = nil, beforeResult: (@Sendable (Int) throws -> Void)? = nil) {
            self.transcript = transcript
            self.threadID = threadID
            self.answer = answer
            self.firstTool = firstTool
            self.secondTool = secondTool
            self.beforeResult = beforeResult
        }

        func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
            let rows = try transcript.range(threadId: threadID, from: 1, to: 100)
            let callIndex = await observations.record(.init(system: systemPrompt, user: userPrompt, rows: rows))
            try beforeResult?(callIndex)
            if callIndex == 1, let firstTool { return .init(text: "", toolCalls: [firstTool]) }
            if callIndex == 2, let secondTool { return .init(text: "", toolCalls: [secondTool]) }
            guard let answer else { throw Unavailable() }
            return AgentModelResult(text: answer, toolCalls: [])
        }
    }

    private struct RevisionChangingEmbedder: Embedder {
        let dimension = 8
        let store: MemoryStore

        func embed(_ text: String) throws -> [Float] {
            let owner = ConsolidationEvidenceAdapter.ownerID
            let grant = BrainAuthorization(principal: owner, owner: owner, subjects: [], scopes: [.user],
                threads: ["other-connection"], sourceSpeakers: [:], mayCommitClaims: true)
            let other = BrainStore(store: store, authorization: grant)
            _ = try other.commit(.init(clientOperationID: UUID().uuidString, evidence: [], updates: [],
                                       expectedRevision: other.revision()))
            return Array(repeating: 1, count: dimension)
        }
    }

    private struct LearningClient: ModelTextClient {
        let quoteID: String?
        let oversizedID: String?

        func generate(prompt: String, options: ModelTextOptions) async throws -> String {
            if prompt.contains("BRAIN_DETAIL_SELECTION"), let quoteID, let oversizedID {
                return try String(decoding: JSONEncoder().encode(["quoteEvidenceIDs": [quoteID, oversizedID]]), as: UTF8.self)
            }
            guard prompt.contains("BRAIN_TURN_LEARNING") else { return "{}" }
            if prompt.contains("Solo quiero que me escuches.") {
                return #"{"updates":[{"kind":"advice","mode":"listen","quote":"Solo quiero que me escuches.","enduring":true}]}"#
            }
            if prompt.contains("Ahora sí quiero que me aconsejes.") {
                return #"{"updates":[{"kind":"advice","mode":"welcome","quote":"Ahora sí quiero que me aconsejes.","enduring":true,"correction":true}]}"#
            }
            return "{}"
        }
    }

    private func makeApp(threadID: String, answer: String? = "Entendido.", firstTool: AgentToolCall? = nil,
                         secondTool: AgentToolCall? = nil, beforeResult: (@Sendable (MemoryStore, Int) throws -> Void)? = nil,
                         modelClient: any ModelTextClient = DefaultNoOpModelClient(),
                         makeEmbedder: (MemoryStore) -> any Embedder = { _ in FakeEmbedder(dimension: 8) }) async throws
        -> (some ApplicationProtocol, Services, RecordingClient) {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let transcript = TranscriptStore(dbQueue: store.dbQueue)
        let recorder = RecordingClient(transcript: transcript, threadID: threadID, answer: answer, firstTool: firstTool,
                                       secondTool: secondTool, beforeResult: { try beforeResult?(store, $0) })
        let services = await Services(store: store, transcript: transcript, embedder: makeEmbedder(store),
                                      bearerToken: "test-token", modelClient: modelClient, agentClient: recorder)
        return (try await buildApp(services: services, port: 0), services, recorder)
    }

    func testActiveFirstProviderCallHasCurrentCaptureAndSameThreadContinuityWithoutLegacyName() async throws {
        let threadID = "bridge"
        let (app, services, recorder) = try await makeApp(threadID: threadID)
        let priorUser = "La misión pasa por un puente de piedra."
        let priorReply = "Sí, conozco ese puente."
        let current = "¿De qué material era?"
        _ = try services.store.upsertSelf(name: "Lucas")
        try services.transcript.append(threadId: threadID, turnIndex: 1, role: "user", text: priorUser, now: 1)
        try services.transcript.append(threadId: threadID, turnIndex: 1, role: "assistant", text: priorReply, now: 2)
        try services.transcript.append(threadId: "unrelated", turnIndex: 1, role: "user", text: "Contexto de otro hilo sin permiso.", now: 3)

        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"¿De qué material era?","threadId":"bridge","language":"es"}"#)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(response.body.readableBytesView)),
                               ["reply": "Entendido."])
            }
        }

        let calls = await recorder.observations.calls
        let first = try XCTUnwrap(calls.first)
        XCTAssertEqual(first.rows.map(\.text), [priorUser, priorReply, current])
        XCTAssertTrue(first.user.contains(priorUser))
        XCTAssertTrue(first.user.contains(priorReply))
        XCTAssertEqual(first.user.components(separatedBy: current).count, 2)
        XCTAssertFalse(first.user.contains("Contexto de otro hilo sin permiso."))
        XCTAssertFalse(first.user.contains("Lucas"))
        XCTAssertTrue(first.user.contains("Reply in Spanish."))
    }

    func testGatewayOperationRetryAfterModelFailureCapturesOnceAndRejectsChangedInput() async throws {
        let (app, services, recorder) = try await makeApp(threadID: "retry", answer: nil)
        let body = ByteBuffer(string: #"{"text":"Acabo de mencionar el puente.","threadId":"retry","clientOperationID":"same-operation"}"#)
        let changed = ByteBuffer(string: #"{"text":"Un texto distinto.","threadId":"retry","clientOperationID":"same-operation"}"#)
        try await app.test(.live) { client in
            for _ in 0..<2 {
                try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth, body: body) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertTrue(String(buffer: response.body).contains(AgentLoop.modelUnreachableReply))
                }
            }
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth, body: changed) { response in
                XCTAssertEqual(response.status, .conflict)
                XCTAssertTrue(String(buffer: response.body).contains("conflict"))
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(calls.allSatisfy { $0.rows.map(\.role) == ["user"] })
        XCTAssertEqual(try services.transcript.range(threadId: "retry", from: 1, to: 20).map(\.text),
                       ["Acabo de mencionar el puente."])
    }

    func testCompletedGatewayOperationReplaysWithoutAnotherProviderCall() async throws {
        let (app, services, recorder) = try await makeApp(threadID: "done")
        let body = ByteBuffer(string: #"{"text":"Seguimos con el plano.","threadId":"done","clientOperationID":"completed-op"}"#)
        try await app.test(.live) { client in
            for _ in 0..<2 {
                try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth, body: body) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(response.body.readableBytesView)),
                                   ["reply": "Entendido."])
                }
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try services.transcript.range(threadId: "done", from: 1, to: 20).map(\.role), ["user", "assistant"])
    }

    func testPassiveIgnoreAdmitsNoTranscriptAndDirectActiveLoopOwnsPersistence() async throws {
        let (app, services, recorder) = try await makeApp(threadID: "direct", answer: #"{"intervene":false,"reply":""}"#)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Radio de fondo.","threadId":"direct","isPassive":true}"#)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(response.body.readableBytesView)), ["reply": ""])
            }
        }
        XCTAssertTrue(try services.transcript.range(threadId: "direct", from: 1, to: 20).isEmpty)
        let loop = AgentLoop(client: recorder)
        _ = await loop.run(text: "Un turno directo.", threadId: "direct", services: services, language: "es")
        let calls = await recorder.observations.calls
        XCTAssertEqual(calls.first?.rows.count, 0)
        XCTAssertEqual(calls.last?.rows.map(\.text), ["Un turno directo."])
        XCTAssertEqual(try services.transcript.range(threadId: "direct", from: 1, to: 20).map(\.role), ["user", "assistant"])
    }

    func testBeginEndpointAuthenticatesAndReturnsStableReceiptBeforeModelGeneration() async throws {
        let (app, services, recorder) = try await makeApp(threadID: "native")
        let uri = "/v1/brain/turns/begin"
        func body(_ text: String) throws -> ByteBuffer {
            let request = try BrainTurnRequest(clientOperationID: "native-1", threadID: "native",
                message: .init(id: "device-unit", speakerID: "self:user", text: text, observedAt: 20, evidenceIDs: []),
                budget: .init(contextTokens: 5500, outputTokens: 256))
            return ByteBuffer(bytes: try JSONEncoder().encode(request))
        }
        let first = try body("Abrí el plano del puente.")
        let changed = try body("Intento de cambiar el turno capturado.")
        try await app.test(.live) { client in
            try await client.execute(uri: uri, method: .post, body: first) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            let initial = try await client.execute(uri: uri, method: .post, headers: Self.auth, body: first)
            let replay = try await client.execute(uri: uri, method: .post, headers: Self.auth, body: first)
            for response in [initial, replay] { XCTAssertEqual(response.status, .ok) }
            if initial.status == .ok, replay.status == .ok {
                let result = try JSONDecoder().decode(BrainTurnResult.self, from: Data(initial.body.readableBytesView))
                let replayed = try JSONDecoder().decode(BrainTurnResult.self, from: Data(replay.body.readableBytesView))
                XCTAssertEqual(result.turnID, replayed.turnID)
                XCTAssertEqual(result.completion.evidenceIDs, replayed.completion.evidenceIDs)
                XCTAssertEqual(result.completion.evidenceIDs.count, 1)
                XCTAssertNotNil(result.context)
            }
            try await client.execute(uri: uri, method: .post, headers: Self.auth, body: changed) { response in
                XCTAssertEqual(response.status, .conflict)
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try services.transcript.range(threadId: "native", from: 1, to: 20).map(\.text), ["Abrí el plano del puente."])
    }

    func testCurrentIntroductionReplacesOldNameBeforeFirstProviderCallInNewThread() async throws {
        let (app, services, recorder) = try await makeApp(threadID: "name-new")
        _ = try services.store.upsertSelf(name: "Lucas")
        let statements = [
            #"{"text":"Me llamo Alba.","threadId":"name-earlier"}"#,
            #"{"text":"Mi nombre es Ada.","threadId":"name-new"}"#,
            #"{"text":"Hola de nuevo.","threadId":"name-later"}"#,
        ]
        try await app.test(.live) { client in
            for statement in statements {
                try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                    body: ByteBuffer(string: statement)) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertEqual(calls.count, 3)
        let correction = try XCTUnwrap(calls.dropFirst().first?.user)
        XCTAssertTrue(correction.contains("Confirmed user name: Ada"))
        XCTAssertFalse(correction.contains("Confirmed user name: Alba"))
        XCTAssertEqual(correction.components(separatedBy: "Mi nombre es Ada.").count, 2)
        let later = try XCTUnwrap(calls.last?.user)
        XCTAssertTrue(later.contains("Confirmed user name: Ada"))
        XCTAssertFalse(later.contains("Lucas"))
    }

    func testGatewayToolsUseTheSameRequestTimezoneAsTheProvider() async throws {
        let tool = AgentToolCall(name: "create_event", args: #"{"title":"Visita al museo","start":"2030-07-04T13:30","end":"2030-07-04T14:30"}"#)
        let (app, services, recorder) = try await makeApp(threadID: "zone", firstTool: tool)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Agenda la visita al museo.","threadId":"zone","timezone":"Pacific/Kiritimati"}"#)) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-07-03T23:30:00Z"))
        let events = try services.store.scheduleWindow(from: date.timeIntervalSince1970 - 10, to: date.timeIntervalSince1970 + 10)
        XCTAssertEqual(events.map(\.label), ["Visita al museo"])
        let calls = await recorder.observations.calls
        XCTAssertTrue(calls.last?.user.contains("Scheduled: Visita al museo") == true)
    }

    func testPassiveInterventionRepliesWithoutStoringAmbientUserText() async throws {
        let (app, services, _) = try await makeApp(threadID: "passive", answer: #"{"intervene":true,"reply":"Apártate del fuego."}"#)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Conversación ambiental sobre fuego.","threadId":"passive","isPassive":true}"#)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(response.body.readableBytesView)),
                               ["reply": "Apártate del fuego."])
            }
        }
        let rows = try services.transcript.range(threadId: "passive", from: 1, to: 20)
        XCTAssertEqual(rows.map(\.role), ["assistant"])
        XCTAssertEqual(rows.map(\.text), ["Apártate del fuego."])
    }

    func testGatewayProjectRecallDoesNotGrantPriorThreadOriginals() async throws {
        let (app, services, recorder) = try await makeApp(threadID: "new-connection",
            firstTool: .init(name: "load_messages", args: #"{"chat_id":"old-connection","from":1}"#))
        let owner = ConsolidationEvidenceAdapter.ownerID
        let subject = "project:aurora"
        let old = "old-connection"
        let grant = BrainAuthorization(principal: owner, owner: owner, subjects: [subject], scopes: [.user, .thread],
                                       threads: [old], sourceSpeakers: [.userMessage: [BrainIdentity.userID]], mayCommitClaims: true)
        let brain = BrainStore(store: services.store, authorization: grant)
        try services.transcript.append(threadId: old, turnIndex: 1, role: "user", text: "Original privado del plano azul.", now: 1)
        let row = try XCTUnwrap(services.transcript.range(threadId: old, from: 1, to: 1).first)
        let privateRoot = try XCTUnwrap(ConsolidationEvidenceAdapter.evidence(for: row, scope: .thread))
        func claim(_ id: String, _ predicate: String, _ text: String, source: BrainEvidence) throws {
            let claim = BrainClaim(id: id, revision: 0, subject: subject, predicate: predicate, value: .string(text),
                modality: .asserted, status: .active, validFrom: source.observedAt, recordedAt: source.recordedAt, evidenceIDs: [source.id])
            let result = try brain.commit(.init(clientOperationID: "commit-" + id, evidence: [source],
                updates: [.init(claim: claim)], expectedRevision: brain.revision()))
            XCTAssertEqual(result.state, .committed)
        }
        let shared = BrainEvidence(id: "shared-checkpoint", sourceKind: .userMessage, speakerID: BrainIdentity.userID,
                                   threadID: old, observedAt: 2, recordedAt: 2, accessScope: .user, text: "Aurora espera la importación.")
        try claim("project-name", "project.name", "Aurora", source: shared)
        try claim("project-checkpoint", "project.checkpoint", "Falta validar la importación.", source: shared)
        try claim("project-private", "project.next-step", "Detalle privado del proyecto.", source: privateRoot)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Sigamos con el proyecto Aurora","threadId":"new-connection"}"#)) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        let calls = await recorder.observations.calls
        let first = try XCTUnwrap(calls.first?.user)
        XCTAssertTrue(first.contains("Falta validar la importación."))
        XCTAssertFalse(first.contains("Detalle privado del proyecto."))
        XCTAssertFalse(first.contains("Recent conversation (this chat"))
        XCTAssertFalse(first.contains("Complete originals eligible for exact citation: shared-checkpoint"))
        let next = try XCTUnwrap(calls.dropFirst().first?.user)
        XCTAssertFalse(next.contains("Original privado del plano azul."))
    }

    func testIncompleteMutationCannotReenterProviderOnOperationReplay() async throws {
        let tool = AgentToolCall(name: "create_event", args: #"{"title":"Paseo en el parque","start":"2030-07-04T13:30","end":"2030-07-04T14:30"}"#)
        let (app, _, recorder) = try await makeApp(threadID: "mutation", answer: nil, firstTool: tool)
        let body = ByteBuffer(string: #"{"text":"Agenda el paseo.","threadId":"mutation","clientOperationID":"mutation-1"}"#)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth, body: body) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains(AgentLoop.incompleteReply))
            }
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth, body: body) { res in
                XCTAssertEqual(res.status, .conflict)
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.last?.user.contains("Scheduled: Paseo en el parque") == true)
    }

    func testMixedLegacyVoiceAndTypedTurnsStayInChronologicalOrder() async throws {
        let thread = "mixed"
        let (app, services, recorder) = try await makeApp(threadID: thread)
        let rows = [("Primera voz.", "Primera respuesta.", 0), ("Primer texto.", "Respuesta escrita.", 20),
                    ("Segunda voz.", "Segunda respuesta.", 0)]
        for (index, exchange) in rows.enumerated() {
            try services.transcript.append(threadId: thread, turnIndex: exchange.2, role: "user", text: exchange.0, now: Double(index * 2 + 1))
            try services.transcript.append(threadId: thread, turnIndex: exchange.2, role: "assistant", text: exchange.1, now: Double(index * 2 + 2))
        }
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"¿Qué fue lo último?","threadId":"mixed"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        let calls = await recorder.observations.calls
        let prompt = try XCTUnwrap(calls.first?.user)
        let positions = try rows.flatMap { [$0.0, $0.1] }.map { try XCTUnwrap(prompt.range(of: $0)).lowerBound }
        XCTAssertEqual(positions, positions.sorted())
    }

    func testGatewayKeepsRelevantUserLegacyMemoryWithoutGrantingIdentityOrPrivateScope() async throws {
        let (app, _, recorder) = try await makeApp(threadID: "legacy-consumer")
        try await app.test(.live) { client in
            let nodes = [#"{"kind":"preference","label":"origami","body":"Prefiere plegar grullas."}"#,
                         #"{"kind":"fact","label":"origami privado","body":"Plegado secreto ajeno.","extra":"{\"scope\":\"thread\",\"threadId\":\"unrelated\"}"}"#]
            for node in nodes {
                try await client.execute(uri: "/v1/memory/save", method: .post, headers: Self.auth, body: ByteBuffer(string: node)) { res in
                    XCTAssertEqual(res.status, .ok)
                }
            }
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Hablemos de origami.","threadId":"legacy-consumer"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        let calls = await recorder.observations.calls
        let prompt = try XCTUnwrap(calls.first?.user)
        XCTAssertTrue(prompt.contains("Prefiere plegar grullas."))
        XCTAssertTrue(prompt.contains("unverified legacy"))
        XCTAssertFalse(prompt.contains("Plegado secreto ajeno."))
    }

    func testMalformedNameLikeIntroductionCannotRetireConfirmedName() async throws {
        let (app, _, recorder) = try await makeApp(threadID: "name-safe")
        try await app.test(.live) { client in
            for body in [#"{"text":"Me llamo Ada.","threadId":"name-setup"}"#,
                         #"{"text":"Me llamo .Alba.","threadId":"name-safe"}"#] {
                try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth, body: ByteBuffer(string: body)) { res in
                    XCTAssertEqual(res.status, .ok)
                }
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertTrue(calls.last?.user.contains("Confirmed user name: Ada") == true)
        XCTAssertFalse(calls.last?.user.contains("Confirmed user name: Alba") == true)
    }

    func testGatewayCanUseFreshLocalContextWhenSemanticReadKeepsLosingRevisionRace() async throws {
        let (app, services, recorder) = try await makeApp(threadID: "churn", makeEmbedder: { RevisionChangingEmbedder(store: $0) })
        try services.transcript.append(threadId: "churn", turnIndex: 1, role: "user", text: "El color del plano es azul.", now: 1)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"¿De qué color es?","threadId":"churn"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.first?.user.contains("El color del plano es azul.") == true)
    }

    func testCurrentConversationPreferenceCorrectionReachesFirstResponse() async throws {
        let (app, _, recorder) = try await makeApp(threadID: "listen", modelClient: LearningClient(quoteID: nil, oversizedID: nil))
        try await app.test(.live) { client in
            for body in [#"{"text":"Solo quiero que me escuches.","threadId":"listen"}"#,
                         #"{"text":"Ahora sí quiero que me aconsejes.","threadId":"listen"}"#] {
                try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth, body: ByteBuffer(string: body)) { res in
                    XCTAssertEqual(res.status, .ok)
                }
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.first?.user.contains("Listen without offering unsolicited advice.") == true)
        XCTAssertTrue(calls.last?.user.contains("Offer advice when it is useful") == true)
        XCTAssertFalse(calls.last?.user.contains("Listen without offering unsolicited advice.") == true)
    }

    func testGatewaySelectorGrantsExactCitationOnlyForOriginalActuallyForwarded() async throws {
        let thread = "selection"
        let exact = "La barandilla era verde."
        let oversized = String(repeating: "fragmento extenso 🛝 ", count: 2_500)
        let exactID = ConsolidationEvidenceAdapter.evidenceID(threadID: thread, seq: 1, text: exact)
        let oversizedID = ConsolidationEvidenceAdapter.evidenceID(threadID: thread, seq: 2, text: oversized)
        let (app, services, recorder) = try await makeApp(threadID: thread,
            modelClient: LearningClient(quoteID: exactID, oversizedID: oversizedID))
        try services.transcript.append(threadId: thread, turnIndex: 1, role: "user", text: exact, now: 1)
        try services.transcript.append(threadId: thread, turnIndex: 2, role: "user", text: oversized, now: 2)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Cita exactamente el texto de la barandilla.","threadId":"selection"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        let calls = await recorder.observations.calls
        let prompt = try XCTUnwrap(calls.first?.user)
        XCTAssertTrue(prompt.contains("[original quote source=\(exactID)]\n" + exact))
        XCTAssertFalse(prompt.contains("[original quote source=\(oversizedID)]"))
        let citation = try XCTUnwrap(prompt.split(separator: "\n").first { $0.contains("eligible for exact citation") })
        XCTAssertTrue(citation.contains(exactID))
        XCTAssertFalse(citation.contains(oversizedID))
    }

    func testGatewayJournalsOnlySanitizedToolOutcomeEvenIfFinalProviderFails() async throws {
        let tool = AgentToolCall(name: "get_current_time", args: #"{"Authorization":"FAKE_PRIVATE_HEADER"}"#)
        let (app, services, _) = try await makeApp(threadID: "tool-journal", answer: nil, firstTool: tool)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"¿Qué hora es?","threadId":"tool-journal"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains(AgentLoop.incompleteReply))
            }
        }
        let records = try await services.store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM brain_turn_outcome")
        }
        let receipt = try JSONDecoder().decode(BrainOutcome.self, from: Data(try XCTUnwrap(records.first).utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records.joined().contains("FAKE_PRIVATE_HEADER"))
        XCTAssertEqual(receipt.observation?.operation, .resourceCheck)
        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(receipt.evidenceIDs.count, 2)
        let safeRows = try await services.store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM brain_evidence WHERE json_extract(payload, '$.sourceKind')='toolObservation'")
        }
        let safeEvidence = try JSONDecoder().decode(BrainEvidence.self, from: Data(try XCTUnwrap(safeRows.first).utf8))
        XCTAssertEqual(safeEvidence.text, "result=succeeded")
        XCTAssertTrue(receipt.evidenceIDs.contains(safeEvidence.id))
    }

    func testGatewayOperationReplayConflictsWhenTimezoneChanges() async throws {
        let (app, _, recorder) = try await makeApp(threadID: "replay-zone")
        try await app.test(.live) { client in
            for (zone, expected) in [("Pacific/Kiritimati", HTTPResponse.Status.ok), ("America/Louisville", .conflict)] {
                let body = ByteBuffer(string: #"{"text":"Agenda una visita a las tres.","threadId":"replay-zone","timezone":"\#(zone)","clientOperationID":"zoned-op"}"#)
                try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth, body: body) { res in
                    XCTAssertEqual(res.status, expected)
                }
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testModelTopicsHideLabelsFromExcludedLegacyNodes() async throws {
        let (app, services, recorder) = try await makeApp(threadID: "topics",
            firstTool: .init(name: "list_topics", args: "{}"))
        try await app.test(.live) { client in
            let notes = [(#"{"kind":"fact","label":"figuras de papel","body":"Hicimos grullas."}"#, "papel compartido"),
                         (#"{"kind":"fact","label":"detalle confidencial","body":"Privado","extra":"{\"scope\":\"thread\",\"threadId\":\"elsewhere\"}"}"#, "tema privado")]
            for (note, tag) in notes {
                let response = try await client.execute(uri: "/v1/memory/save", method: .post, headers: Self.auth,
                    body: ByteBuffer(string: note))
                let values = try JSONDecoder().decode([String: String].self, from: Data(response.body.readableBytesView))
                try services.store.setTags(nodeId: XCTUnwrap(values["id"]), [tag])
            }
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Dime qué temas hay.","threadId":"topics"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        let calls = await recorder.observations.calls
        XCTAssertTrue(calls.last?.user.contains("papel compartido") == true)
        XCTAssertFalse(calls.last?.user.contains("tema privado") == true)
    }

    func testModelSaveCannotWriteGuessedNameToLegacyIdentity() async throws {
        let (app, services, _) = try await makeApp(threadID: "no-guess",
            firstTool: .init(name: "save_memory", args: #"{"kind":"self","entity":"Lucas","detail":"The user is Lucas"}"#))
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Hola.","threadId":"no-guess"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        XCTAssertNil(try services.store.selfNode())
    }

    func testModelForgetRequiresTheUsersExactRequestAndWithdrawsTheBoundClaim() async throws {
        let label = "registros temporales"
        let thread = "forget-tool"
        let (app, services, _) = try await makeApp(threadID: thread,
            firstTool: .init(name: "forget", args: #"{"query":"registros temporales"}"#))
        let owner = ConsolidationEvidenceAdapter.ownerID
        let grant = BrainAuthorization(principal: owner, owner: owner, subjects: [BrainIdentity.userID], scopes: [.user],
            threads: [thread], sourceSpeakers: [.userMessage: [BrainIdentity.userID]], mayCommitClaims: true)
        let brain = BrainStore(store: services.store, authorization: grant)
        let source = BrainEvidence(id: "remember-source", sourceKind: .userMessage, speakerID: BrainIdentity.userID,
            threadID: thread, observedAt: 1, recordedAt: 1, accessScope: .user, text: "Conserva registros temporales.")
        let claim = BrainClaim(id: "remember-claim", revision: 0, subject: BrainIdentity.userID,
            predicate: "recall.detail", value: .string(label), modality: .asserted, status: .active,
            validFrom: 1, recordedAt: 1, evidenceIDs: [source.id])
        _ = try brain.commit(.init(clientOperationID: "remember", evidence: [source], updates: [.init(claim: claim)], expectedRevision: 0))
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Olvida registros temporales.","threadId":"forget-tool"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
        XCTAssertFalse(try brain.claims(subject: BrainIdentity.userID, asOf: 100, scope: .user).contains { $0.id == claim.id })
    }

    func testWithdrawingTurnBetweenProviderRoundsPreventsLaterMutation() async throws {
        let thread = "withdrawn-mid-turn"
        let first = AgentToolCall(name: "create_event", args: #"{"title":"Primera visita","start":"2030-07-04T09:00","end":"2030-07-04T10:00"}"#)
        let second = AgentToolCall(name: "create_event", args: #"{"title":"Segunda visita","start":"2030-07-04T13:00","end":"2030-07-04T14:00"}"#)
        let (app, services, _) = try await makeApp(threadID: thread, firstTool: first, secondTool: second, beforeResult: { store, call in
            guard call == 2 else { return }
            let owner = ConsolidationEvidenceAdapter.ownerID
            let grant = BrainAuthorization(principal: owner, owner: owner, subjects: BrainIdentity.reservedSubjects,
                scopes: [.user, .thread, .agent, .shared], threads: [thread], sourceSpeakers: [:], mayForget: true)
            let brain = BrainStore(store: store, authorization: grant)
            _ = try BrainRetractionService(brain: brain).forget(scope: .init(kind: .thread, id: thread),
                expectedRevision: brain.revision(), operationID: "withdraw-before-second-dispatch")
        })
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/agent/turn", method: .post, headers: Self.auth,
                body: ByteBuffer(string: #"{"text":"Agenda dos visitas.","threadId":"withdrawn-mid-turn","timezone":"UTC"}"#)) { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-07-04T00:00:00Z")).timeIntervalSince1970
        let events = try services.store.scheduleWindow(from: date, to: date + 86_400)
        XCTAssertEqual(events.map(\.label), ["Primera visita"])
    }
}
