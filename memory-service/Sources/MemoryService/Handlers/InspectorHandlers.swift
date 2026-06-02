import Foundation
import Hummingbird
import NIOCore
import HTTPTypes
import MemoryCore

/// Read-only inspector endpoints used by the macOS Memory inspector UI.
/// `GET /v1/nodes` — paginated, optionally `kind`-filtered list of live nodes.
/// `GET /v1/transcript/recent` — newest-first cross-thread transcript dump.
struct InspectorHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.get("/nodes", use: nodes)
        group.get("/transcript/recent", use: recent)
    }

    @Sendable func nodes(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        let limit = q["limit"].flatMap { Int($0) } ?? 100
        let offset = q["offset"].flatMap { Int($0) } ?? 0
        let kind = q["kind"].map(String.init)
        let result = try services.store.listNodes(limit: limit, offset: offset, kind: kind)
        let data = try JSONEncoder().encode(result)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    @Sendable func recent(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 200
        let rows = try services.transcript.allRecent(limit: limit)
        struct OutRow: Encodable {
            let id: String
            let threadId: String
            let role: String
            let text: String
            let turnIndex: Int
            let createdAt: Double
        }
        struct Payload: Encodable { let rows: [OutRow] }
        let out = Payload(rows: rows.map { OutRow(id: $0.id, threadId: $0.threadId, role: $0.role,
                                                  text: $0.text, turnIndex: $0.turnIndex,
                                                  createdAt: $0.createdAt) })
        let data = try JSONEncoder().encode(out)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}
