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
        group.get("/graph", use: graph)
        group.get("/memory/byHub", use: byHub)
        group.get("/memory/byEntity", use: byEntity)
    }

    /// GET /v1/memory/byHub?kind=task&status=pending&sort=date&limit=50
    /// `status` → filters `json_extract(extra,'$.status') = <value>`
    /// `sort=date` → orders by `json_extract(extra,'$.date')` ascending; default = newest-updated
    @Sendable func byHub(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        guard let kindRaw = q["kind"].map(String.init),
              let kind = NodeKind(rawValue: kindRaw) else {
            return jsonError(.badRequest, "bad_request", "kind required and must be a known NodeKind")
        }
        let limit = q["limit"].flatMap { Int($0) } ?? 100

        var filter: String? = nil
        if let status = q["status"].map(String.init) {
            // Escape user input for SQL string-literal; rejects naive injection attempts.
            let safe = status.replacingOccurrences(of: "'", with: "''")
            filter = "json_extract(n.extra,'$.status') = '\(safe)'"
        }
        let order: String = (q["sort"] == "date")
            ? "json_extract(n.extra,'$.date') ASC, n.updatedAt DESC"
            : "n.updatedAt DESC"

        let nodes = try services.store.nodesByHub(kind: kind, extraFilter: filter,
                                                  orderSQL: order, limit: limit)
        struct Payload: Encodable { let nodes: [Node]; let kind: String; let total: Int }
        let payload = Payload(nodes: nodes, kind: kindRaw, total: nodes.count)
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// GET /v1/memory/byEntity?label=Roilan&limit=100 — everything linked to the named entity
    /// (mentionedIn, likes, knows, … any relation either direction). Useful for "tell me
    /// everything you know about <person>" recall.
    @Sendable func byEntity(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        guard let label = q["label"].map(String.init), !label.isEmpty else {
            return jsonError(.badRequest, "bad_request", "label required")
        }
        let limit = q["limit"].flatMap { Int($0) } ?? 100
        let nodes = try services.store.nodesByEntity(label: label, limit: limit)
        struct Payload: Encodable { let nodes: [Node]; let entity: String; let total: Int }
        let payload = Payload(nodes: nodes, entity: label, total: nodes.count)
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    @Sendable func graph(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let nodeLimit = req.uri.queryParameters["nodeLimit"].flatMap { Int($0) } ?? 300
        let result = try services.store.loadGraph(nodeLimit: nodeLimit)
        let data = try JSONEncoder().encode(result)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
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
