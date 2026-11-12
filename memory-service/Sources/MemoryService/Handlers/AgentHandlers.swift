import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import MemoryCore

/// `POST /v1/agent/turn` — runs one agentic turn (recall → model → tool execution → reply),
/// using the same admitted-turn lifecycle as direct callers.
struct AgentHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/agent/turn", use: turn)
    }

    struct TurnBody: Decodable, Sendable {
        let text: String
        let threadId: String?
        /// IANA tz id (e.g. "America/Havana") — drives consolidation sleep-window timing. The i3
        /// runs UTC in Docker, so a caller in another zone should pass its local tz. Optional → server's.
        let timezone: String?
        /// STT-detected language code (e.g. "en"/"es"). When present, pins the reply language for
        /// this turn. Optional — typed callers omit it; the voice gateway forwards the STT language.
        let language: String?
        let isPassive: Bool?
        let clientOperationID: String?
    }

    @Sendable func turn(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf: ByteBuffer
        // 32KB cap (matches TranscriptHandlers) — ample for a single text turn; oversized → 400, no crash.
        do { buf = try await req.body.collect(upTo: 32_000) }
        catch { return jsonError(.badRequest, "bad_request", "body unreadable") }

        guard let body = try? JSONDecoder().decode(TurnBody.self, from: Data(buf.readableBytesView)),
              !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return jsonError(.badRequest, "bad_request", "text required")
        }

        // A caller that omits threadId pools into one shared "gateway" transcript — fine for Phase 1a
        // (thin-device callers are expected to pass a stable id; episode-boundary logic is the caller's).
        let threadId = body.threadId ?? "gateway"
        guard BrainHandlers.validID(threadId), body.clientOperationID.map(BrainHandlers.validID) ?? true else {
            return jsonError(.badRequest, "bad_request", "invalid thread or operation id")
        }
        let reply: String
        do {
            reply = try await AgentLoop(client: services.agentClient).runAdmitted(text: body.text, threadID: threadId,
                services: services, language: body.language, isPassive: body.isPassive ?? false,
                timezone: body.timezone.flatMap(TimeZone.init(identifier:)) ?? .current,
                operationID: body.clientOperationID)
        } catch {
            return BrainHandlers.failure(error)
        }

        struct Out: Encodable { let reply: String }
        let data = try JSONEncoder().encode(Out(reply: reply))
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}
