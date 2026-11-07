import Foundation
import BrainContract
import Hummingbird
import NIOCore
import MemoryCore

/// Context retrieval for the service owner. Registered under the existing bearer group.
struct BrainHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/brain/context", use: context)
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

        // The bearer authenticates this service's single owner. Bind the read grant to the
        // requested thread server-side. Context assembly also checks each requested original.
        let owner = ConsolidationEvidenceAdapter.ownerID
        let grant = BrainAuthorization(principal: owner, owner: owner, subjects: BrainIdentity.reservedSubjects,
                                       scopes: [.user, .thread, .agent, .shared], threads: [body.threadID],
                                       sourceSpeakers: [:])
        let brain = BrainStore(store: services.store, authorization: grant)
        let assembler = BrainContextAssembler(store: ConversationStateStore(brain: brain))
        do {
            let bundle = try await assembler.context(body)
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
