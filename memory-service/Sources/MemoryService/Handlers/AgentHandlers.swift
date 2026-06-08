import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import MemoryCore

/// `POST /v1/agent/turn` — runs one agentic turn (recall → model → tool execution → reply),
/// appends both the user and assistant turns to the transcript, then arms consolidation.
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
    }

    @Sendable func turn(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf: ByteBuffer
        // 32KB cap (matches TranscriptHandlers) — ample for a single text turn; oversized → 400, no crash.
        do { buf = try await req.body.collect(upTo: 32_000) }
        catch { return jsonError(.badRequest, "bad_request", "body unreadable") }

        guard let body = try? JSONDecoder().decode(TurnBody.self, from: Data(buf.readableBytesView)),
              !body.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return jsonError(.badRequest, "bad_request", "text required")
        }

        // A caller that omits threadId pools into one shared "gateway" transcript — fine for Phase 1a
        // (thin-device callers are expected to pass a stable id; episode-boundary logic is the caller's).
        let threadId = body.threadId ?? "gateway"

        // Run the agentic loop (recall → model → tool calls → final reply).
        let reply = await AgentLoop(client: services.agentClient).run(
            text: body.text, threadId: threadId, services: services, language: body.language
        )

        // Persist the turn to the transcript: user first, then assistant.
        // `seq` is server-authoritative (assigned inside append, ignoring the client turnIndex).
        // Best-effort: a persistence hiccup shouldn't fail the user's reply, but we log it for ops.
        let now = Date().timeIntervalSince1970
        // Don't persist failure placeholders (model-unreachable / incomplete) as assistant turns —
        // they'd pollute future recall + consolidation. The user turn is still recorded.
        let persistAssistant = !reply.isEmpty && !AgentLoop.fallbackReplies.contains(reply)
        do {
            _ = try services.transcript.append(threadId: threadId, turnIndex: 0,
                                               role: "user", text: body.text, now: now)
            if persistAssistant {
                _ = try services.transcript.append(threadId: threadId, turnIndex: 0,
                                                   role: "assistant", text: reply, now: now + 0.001)
            }
        } catch {
            ctx.logger.warning("agent/turn transcript append failed: \(error)")
        }

        // Arm consolidation: same path/args as POST /v1/consolidation/turn-end (incl. timezone).
        let tz = body.timezone.flatMap { TimeZone(identifier: $0) } ?? .current
        await services.scheduler.armTurnEnd(threadId: threadId, timeZone: tz)

        struct Out: Encodable { let reply: String }
        let data = try JSONEncoder().encode(Out(reply: reply))
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}
