import Foundation
import Hummingbird
import NIOCore
import HTTPTypes
import MemoryCore

/// `POST /v1/consolidation/turn-end`, `POST /v1/consolidation/reflect`,
/// `GET  /v1/consolidation/state` — drives the server-side sleep/reflection scheduler and
/// exposes graph counters for the macOS client.
struct ConsolidationHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/consolidation/turn-end", use: turnEnd)
        group.post("/consolidation/reflect",  use: reflect)
        group.get ("/consolidation/state",    use: state)
    }

    struct TurnEndBody: Decodable, Sendable { let threadId: String }

    @Sendable func turnEnd(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf = (try? await req.body.collect(upTo: 4_000)) ?? ByteBuffer()
        guard let body = try? JSONDecoder().decode(TurnEndBody.self, from: Data(buf.readableBytesView)) else {
            return jsonError(.badRequest, "bad_request", "threadId required")
        }
        await services.scheduler.armTurnEnd(threadId: body.threadId)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(string: "{}")))
    }

    @Sendable func reflect(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let id = await services.scheduler.runReflectAdHoc() ?? ""
        let payload = #"{"cycleId":"\#(id)"}"#
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(string: payload)))
    }

    @Sendable func state(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let nodeCount = (try? services.store.nodeCount()) ?? 0
        let transcriptCount = (try? services.transcript.count()) ?? 0
        let isRunning = await services.scheduler.isRunning
        // `latestSleepCycle()` returns the startedAt epoch (or nil) — we surface that directly
        // since SleepCycleState itself is internal-shaped. A null payload means no cycle yet.
        let lastStartedAt = (try? services.store.latestSleepCycle()) ?? nil
        struct OutCycle: Encodable { let startedAt: Double }
        struct Payload: Encodable {
            let lastCycle: OutCycle?
            let nodeCount: Int
            let transcriptCount: Int
            let isRunning: Bool
        }
        let payload = Payload(
            lastCycle: lastStartedAt.map { OutCycle(startedAt: $0) },
            nodeCount: nodeCount,
            transcriptCount: transcriptCount,
            isRunning: isRunning
        )
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}
