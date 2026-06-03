import Foundation
import Hummingbird
import NIOCore
import HTTPTypes
import MemoryCore

/// `/v1/schedule` — dated events with deterministic overlap detection.
struct ScheduleHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/schedule/check",  use: check)
        group.post("/schedule/create", use: create)
        group.get ("/schedule/window", use: window)
        group.post("/schedule/cancel", use: cancel)
    }

    private func eventJSON(_ n: Node) -> [String: Any] {
        let a = NodeAttributes.from(n.extra)
        var d: [String: Any] = ["id": n.id, "title": n.label, "start": a.startAt ?? 0,
                                "end": a.endAt ?? 0, "allDay": a.allDay ?? false,
                                "status": a.status ?? "scheduled"]
        if let loc = a.location { d["location"] = loc }
        return d
    }

    private func json(_ obj: Any, _ status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func body<T: Decodable>(_ req: Request, _ type: T.Type) async -> T? {
        guard let buf = try? await req.body.collect(upTo: 16_000) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(buf.readableBytesView))
    }

    struct CheckBody: Decodable, Sendable { let start: Double; let end: Double }

    @Sendable func check(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let b = await body(req, CheckBody.self) else {
            return jsonError(.badRequest, "bad_request", "start/end required")
        }
        let conflicts = (try? services.store.scheduleConflicts(start: b.start, end: b.end)) ?? []
        return json(["conflicts": conflicts.map(eventJSON)])
    }

    struct CreateBody: Decodable, Sendable {
        let title: String; let start: Double; let end: Double
        let allDay: Bool?; let location: String?; let origin: String?; let force: Bool?
    }

    @Sendable func create(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let b = await body(req, CreateBody.self) else {
            return jsonError(.badRequest, "bad_request", "title/start/end required")
        }
        let conflicts: [Node]
        do { conflicts = try services.store.scheduleConflicts(start: b.start, end: b.end) }
        catch { return jsonError(.internalServerError, "store_error", "\(error)") }
        if !conflicts.isEmpty, b.force != true {
            return json(["created": false, "conflicts": conflicts.map(eventJSON)])
        }
        let origin: Origin = (b.origin == "extracted") ? .extracted : .explicit
        let id = try services.store.upsertEvent(title: b.title, start: b.start, end: b.end,
                                                allDay: b.allDay ?? false, location: b.location,
                                                origin: origin)
        return json(["created": true, "id": id, "conflicts": conflicts.map(eventJSON)])
    }

    @Sendable func window(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        let from = q["from"].flatMap { Double($0) } ?? 0
        let to   = q["to"].flatMap   { Double($0) } ?? (from + 7 * 86_400)
        let incl = q["includeCancelled"] == "true"
        let events = (try? services.store.scheduleWindow(from: from, to: to, includeCancelled: incl)) ?? []
        return json(["events": events.map(eventJSON)])
    }

    struct CancelBody: Decodable, Sendable { let ids: [String]?; let from: Double?; let to: Double? }

    @Sendable func cancel(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let b = await body(req, CancelBody.self) else {
            return jsonError(.badRequest, "bad_request", "ids or from/to required")
        }
        guard b.ids != nil || (b.from != nil && b.to != nil) else {
            return jsonError(.badRequest, "bad_request", "ids or from/to required")
        }
        let n = (try? services.store.cancelEvents(ids: b.ids, from: b.from, to: b.to)) ?? 0
        return json(["cancelled": n])
    }
}
