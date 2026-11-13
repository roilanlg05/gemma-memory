import Foundation
import BrainContract
import Hummingbird
import HTTPTypes
import NIOCore
import MemoryCore

/// Context retrieval for the service owner. Registered under the existing bearer group.
struct BrainHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/brain/context", use: context)
        group.post("/brain/turns/begin", use: begin)
        group.post("/brain/turns/complete", use: complete)
        group.post("/brain/outcomes", use: outcomes)
        group.get("/brain/tastes/profile", use: tastes)
        group.get("/brain/prospective", use: prospective)
        group.post("/brain/prospective/defer", use: deferProspective)
        group.post("/brain/prospective/resolve", use: resolveProspective)
        group.post("/brain/prospective/receipt", use: acknowledgeProspective)
        group.post("/brain/updates/propose", use: propose)
        group.post("/brain/updates/commit", use: commit)
        group.get("/brain/identity", use: identity)
        group.get("/brain/affect", use: affect)
        group.post("/brain/affect/correct", use: correctAffect)
        group.post("/brain/affect/end", use: endAffect)
        group.post("/brain/revise", use: revise)
        group.post("/brain/forget", use: forget)
        group.post("/brain/consolidate", use: consolidate)
        group.get("/brain/consolidate", use: consolidationStatus)
    }

    static func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
    }

    static func response<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONEncoder().encode(value)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func read<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T {
        let buffer: ByteBuffer
        do { buffer = try await request.body.collect(upTo: 32_000) }
        catch { throw BrainStoreError.invalid }
        return try JSONDecoder().decode(type, from: Data(buffer.readableBytesView))
    }

    static func failure(_ error: Error) -> Response {
        switch error {
        case BrainContractError.unsupportedSchemaVersion:
            return jsonError(.badRequest, "unsupported_schema", "unsupported brain schema")
        case is BrainContractError, is DecodingError, BrainStoreError.invalid:
            return jsonError(.badRequest, "bad_request", "invalid brain request")
        case BrainStoreError.denied:
            return jsonError(.forbidden, "forbidden", "brain source unavailable")
        case BrainStoreError.conflict:
            return jsonError(.conflict, "revision_conflict", "brain operation or revision conflicts")
        case BrainContextAssemblyError.insufficientBudget:
            return jsonError(.unprocessableContent, "insufficient_budget", "context budget cannot fit required disclosure")
        default:
            return jsonError(.serviceUnavailable, "persistence_unavailable", "brain operation unavailable")
        }
    }

    @Sendable func begin(_ request: Request, _: BasicRequestContext) async -> Response {
        let body: BrainTurnRequest
        do { body = try await Self.read(BrainTurnRequest.self, request) }
        catch let error as BrainContractError { return Self.failure(error) }
        catch { return jsonError(.badRequest, "bad_request", "invalid turn request") }
        guard Self.validID(body.threadID), Self.validID(body.clientOperationID),
              !body.clientOperationID.hasPrefix("gateway:"), Self.validID(body.message.id),
              body.message.evidenceIDs.isEmpty, body.budget.contextTokens <= 128_000 else {
            return jsonError(.badRequest, "bad_request", "invalid turn request")
        }
        do {
            let result = try await services.brain.begin(body, onAdmission: { await services.scheduler.noteUserActivity() })
            return try Self.response(result)
        }
        catch { return Self.failure(error) }
    }

    @Sendable func complete(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainTurnCompletionRequest.self, request)
            guard Self.validID(body.turnID), Self.validID(body.clientOperationID),
                  !body.clientOperationID.hasPrefix("gateway:"), !AgentLoop.fallbackReplies.contains(body.assistantText) else {
                throw BrainStoreError.invalid
            }
            let turns = try services.brain.turnService(turnID: body.turnID)
            let before = try turns.completion(turnID: body.turnID)
            guard before.evidenceIDs == body.evidenceIDs else { throw BrainStoreError.denied }
            try turns.recordAssistant(turnID: body.turnID, operationID: body.clientOperationID, text: body.assistantText)
            return try Self.response(BrainTurnResult(clientOperationID: body.clientOperationID, turnID: body.turnID,
                                                     reply: body.assistantText, completion: before))
        } catch { return Self.failure(error) }
    }

    @Sendable func outcomes(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainReportedOutcomeRequest.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.turnID), Self.validID(body.outcome.id), !body.outcome.id.hasPrefix("gateway:") else {
                throw BrainStoreError.invalid
            }
            guard body.outcome.observation == nil else { throw BrainStoreError.denied }
            let turns = try services.brain.turnService(turnID: body.turnID)
            let admission = try turns.completion(turnID: body.turnID)
            guard admission.evidenceIDs == body.outcome.evidenceIDs else { throw BrainStoreError.denied }
            return try Self.response(turns.recordOutcome(body.outcome))
        } catch { return Self.failure(error) }
    }

    @Sendable func tastes(_ request: Request, _: BasicRequestContext) async -> Response {
        let q = request.uri.queryParameters
        let subject = q["subjectID"].map(String.init) ?? BrainIdentity.userID
        let thread = q["threadID"].map(String.init)
        guard subject == BrainIdentity.userID else { return Self.failure(BrainStoreError.denied) }
        guard let domain = q["domain"].map(String.init), Self.validID(domain), thread.map(Self.validID) ?? true else {
            return Self.failure(BrainStoreError.invalid)
        }
        do {
            let brain = BrainStore(store: services.store, authorization: services.brain.grant(threadID: thread ?? ""))
            let context = BrainTasteContext(threadID: thread, situation: q["situation"].map(String.init))
            let profile = try TastePreferenceService(brain: brain).profile(subject: subject, domain: domain,
                                                                          context: context, now: Date().timeIntervalSince1970)
            return try Self.response(profile)
        } catch { return Self.failure(error) }
    }

    @Sendable func prospective(_ request: Request, _: BasicRequestContext) async -> Response {
        let q = request.uri.queryParameters
        do {
            let grant = services.brain.grant(threadID: "")
            let brain = BrainStore(store: services.store, authorization: grant)
            let revision: Int64
            if let raw = q["revision"] {
                guard let supplied = Int64(raw), supplied >= 0 else { throw BrainStoreError.invalid }
                revision = supplied
            } else { revision = try brain.revision() }
            let candidates = try ProspectiveMemoryStore(store: services.store, authorization: grant)
                .candidates(scope: .user, revision: revision)
            return try Self.response(BrainProspectiveResult(revision: revision, candidates: candidates))
        } catch { return Self.failure(error) }
    }

    @Sendable func context(_ request: Request, _: BasicRequestContext) async -> Response {
        let body: BrainContextRequest
        do {
            let buffer = try await request.body.collect(upTo: 32_000)
            body = try JSONDecoder().decode(BrainContextRequest.self, from: Data(buffer.readableBytesView))
        } catch BrainContractError.unsupportedSchemaVersion(_) {
            return jsonError(.badRequest, "unsupported_schema", "unsupported context schema")
        } catch {
            return jsonError(.badRequest, "bad_request", "invalid context request")
        }
        let selections = (body.quoteEvidenceIDs ?? []) + (body.detailEvidenceIDs ?? [])
        guard !body.threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.budget.contextTokens <= 128_000,
              selections.count <= 64,
              selections.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return jsonError(.badRequest, "bad_request", "invalid thread, context window or original selection")
        }

        do {
            // The cue mode does not admit a turn, store a claim, or call a selector model.
            // A final begin request always assembles against freshly validated sources.
            let mode = request.uri.queryParameters["mode"]
            let prefetch = mode == "prefetch"
            guard !prefetch || (Self.validID(body.threadID) && Self.validID(body.clientOperationID)
                && !body.clientOperationID.hasPrefix("gateway:") && body.query.utf8.count <= 1200 && selections.isEmpty) else {
                return Self.failure(BrainStoreError.invalid)
            }
            let bundle = try await services.brain.context(body, semanticSelection: !prefetch && mode != "cue",
                                                          prefetchMode: prefetch ? .prepare : nil)
            let data = try JSONEncoder().encode(bundle)
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
        } catch BrainContextAssemblyError.insufficientBudget {
            return jsonError(.unprocessableContent, "insufficient_budget", "context budget cannot fit required disclosure")
        } catch BrainStoreError.denied {
            return jsonError(.forbidden, "forbidden", "context source unavailable")
        } catch BrainStoreError.conflict {
            return jsonError(.conflict, "revision_conflict", "context changed during assembly")
        } catch BrainStoreError.invalid {
            return jsonError(.badRequest, "bad_request", "invalid context source")
        } catch {
            return jsonError(.serviceUnavailable, "context_unavailable", "context assembly unavailable")
        }
    }
}
