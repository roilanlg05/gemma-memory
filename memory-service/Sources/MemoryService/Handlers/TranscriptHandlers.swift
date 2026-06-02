import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import MemoryCore

/// `POST /v1/transcript/append` and `GET /v1/conversation/window` (Layer 1 short-term window).
struct TranscriptHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/transcript/append", use: append)
        group.get("/conversation/window", use: window)
    }

    struct AppendBody: Decodable, Sendable {
        let threadId: String
        let role: String
        let text: String
        let turnIndex: Int
    }

    @Sendable func append(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf: ByteBuffer
        do { buf = try await req.body.collect(upTo: 32_000) }
        catch { return jsonError(.badRequest, "bad_request", "body unreadable") }
        let data = Data(buf.readableBytesView)
        guard let body = try? JSONDecoder().decode(AppendBody.self, from: data),
              ["user", "assistant"].contains(body.role) else {
            return jsonError(.badRequest, "bad_request", "invalid append body")
        }
        try services.transcript.append(threadId: body.threadId, turnIndex: body.turnIndex,
                                       role: body.role, text: body.text,
                                       now: Date().timeIntervalSince1970)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(string: "{}")))
    }

    @Sendable func window(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        guard let threadId = q["threadId"] else {
            return jsonError(.badRequest, "bad_request", "threadId required")
        }
        let maxTurns = q["maxTurns"].flatMap { Int($0) } ?? 12
        let maxChars = q["maxChars"].flatMap { Int($0) } ?? 1500
        let rows = try services.transcript.recent(threadId: String(threadId),
                                                  maxTurns: maxTurns, maxChars: maxChars)
        struct OutTurn: Encodable { let role: String; let text: String }
        struct OutPayload: Encodable { let turns: [OutTurn] }
        let out = OutPayload(turns: rows.map { OutTurn(role: $0.role, text: $0.text) })
        let data = try JSONEncoder().encode(out)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}

func jsonError(_ status: HTTPResponse.Status, _ code: String, _ message: String) -> Response {
    let payload = #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
    return Response(status: status, headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: ByteBuffer(string: payload)))
}
