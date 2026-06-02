import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import MemoryCore

/// `POST /v1/memory/save`, `POST /v1/memory/forget`, `POST /v1/memory/recall`,
/// `GET /v1/memory/expand` — the Layer 2/3/4 memory operations exposed to the macOS client.
struct MemoryHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/memory/save",   use: save)
        group.post("/memory/forget", use: forget)
        group.post("/memory/recall", use: recall)
        group.get ("/memory/expand", use: expand)
    }

    struct SaveBody: Decodable, Sendable {
        let kind: String
        let label: String
        let body: String?
        let extra: String?
        let sourceRef: String?
        let layer: String?
        let confidence: String?
        let origin: String?
    }
    struct ForgetBody: Decodable, Sendable { let id: String?; let label: String? }
    struct RecallBody: Decodable, Sendable { let query: String; let scope: String?; let limit: Int? }

    @Sendable func save(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf: ByteBuffer
        do { buf = try await req.body.collect(upTo: 64_000) }
        catch { return jsonError(.badRequest, "bad_request", "body unreadable") }
        guard let body = try? JSONDecoder().decode(SaveBody.self, from: Data(buf.readableBytesView)),
              !body.kind.isEmpty, !body.label.isEmpty else {
            return jsonError(.badRequest, "bad_request", "invalid save body")
        }

        let now = Date().timeIntervalSince1970
        let layer: MemoryLayer = body.layer.flatMap { MemoryLayer(rawValue: $0) }
            ?? (body.kind == "identity" ? .identity : .daily)
        let confidence: Confidence = body.confidence.flatMap { Confidence(rawValue: $0) } ?? .probable
        let origin: Origin = body.origin.flatMap { Origin(rawValue: $0) } ?? .explicit
        let candidate = Node(
            id: UUID().uuidString, kind: body.kind, label: body.label,
            body: body.body ?? "", layer: layer,
            createdAt: now, updatedAt: now, lastSeenAt: now,
            salience: layer == .identity ? 8 : 3,
            decayRate: Decay.defaultDecayRate(for: layer),
            confidence: confidence, mentionCount: 1, ttlExpiresAt: nil,
            sourceRef: body.sourceRef, origin: origin, serverId: nil,
            dirty: true, deleted: false, extra: body.extra
        )

        // Compute embedding (best-effort — RemoteEmbedder may be unreachable in some envs).
        let embedding: [Float]? = try? services.embedder.embed(body.label)

        let id: String
        do {
            id = try services.store.upsertMergingSemantic(candidate, embedding: embedding,
                                                          embedder: services.embedder)
        } catch {
            return jsonError(.internalServerError, "save_failed", "\(error)")
        }
        // mergedInto = id when an existing node absorbed the candidate (id != candidate.id).
        let mergedInto: String? = (id == candidate.id) ? nil : id
        struct Out: Encodable { let id: String; let mergedInto: String? }
        let payload = Out(id: id, mergedInto: mergedInto)
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    @Sendable func forget(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf: ByteBuffer
        do { buf = try await req.body.collect(upTo: 16_000) }
        catch { return jsonError(.badRequest, "bad_request", "body unreadable") }
        guard let body = try? JSONDecoder().decode(ForgetBody.self, from: Data(buf.readableBytesView)) else {
            return jsonError(.badRequest, "bad_request", "invalid forget body")
        }
        let removed: Int
        if let id = body.id, !id.isEmpty {
            // forgetById returns Void; treat success as 1 row.
            do {
                try services.store.forgetById(id)
                removed = 1
            } catch {
                return jsonError(.internalServerError, "forget_failed", "\(error)")
            }
        } else if let label = body.label, !label.isEmpty {
            do { removed = try services.store.forgetByLabel(label) }
            catch { return jsonError(.internalServerError, "forget_failed", "\(error)") }
        } else {
            return jsonError(.badRequest, "bad_request", "id or label required")
        }
        let payload = #"{"removed":\#(removed)}"#
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(string: payload)))
    }

    @Sendable func recall(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf: ByteBuffer
        do { buf = try await req.body.collect(upTo: 16_000) }
        catch { return jsonError(.badRequest, "bad_request", "body unreadable") }
        guard let body = try? JSONDecoder().decode(RecallBody.self, from: Data(buf.readableBytesView)),
              !body.query.isEmpty else {
            return jsonError(.badRequest, "bad_request", "invalid recall body")
        }
        let limit = body.limit ?? 6

        // MemoryRetriever.retrieve() already unions identity-core; split the returned set so
        // the client can render "always-on identity facts" separately from query-relevant recall.
        let retrieved: [Node]
        do { retrieved = try services.retriever.retrieve(query: body.query, k: limit) }
        catch { return jsonError(.internalServerError, "recall_failed", "\(error)") }
        let coreNodes = (try? services.store.coreMemories(limit: limit)) ?? []
        let coreIds = Set(coreNodes.map { $0.id })
        let recallNodes = retrieved.filter { !coreIds.contains($0.id) }

        struct OutNode: Encodable { let id: String; let kind: String; let label: String; let body: String; let extra: String? }
        struct Payload: Encodable { let core: [OutNode]; let recall: [OutNode] }
        func toOut(_ n: Node) -> OutNode {
            OutNode(id: n.id, kind: n.kind, label: n.label, body: n.body, extra: n.extra)
        }
        let payload = Payload(core: coreNodes.map(toOut), recall: recallNodes.map(toOut))
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    @Sendable func expand(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        guard let topicRaw = q["topic"] else {
            return jsonError(.badRequest, "bad_request", "topic required")
        }
        let topic = String(topicRaw)
        let result: Services.ExpandResult
        do { result = try services.expandContext(topic: topic) }
        catch { return jsonError(.internalServerError, "expand_failed", "\(error)") }
        struct OutTurn: Encodable { let role: String; let text: String }
        struct Payload: Encodable { let transcript: [OutTurn]; let summaryLabel: String? }
        let payload = Payload(transcript: result.rows.map { OutTurn(role: $0.role, text: $0.text) },
                              summaryLabel: result.summaryLabel)
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}
