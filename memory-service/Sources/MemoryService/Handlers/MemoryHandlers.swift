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
        group.post("/memory/save",     use: save)
        group.post("/memory/forget",   use: forget)
        group.post("/memory/recall",   use: recall)
        group.get ("/memory/expand",   use: expand)
        group.get ("/memory/tags",     use: tags)
        group.get ("/memory/by_topic", use: byTopic)
        group.get ("/memory/why",      use: why)
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
    struct RecallBody: Decodable, Sendable { let query: String; let scope: String?; let limit: Int?; let threadId: String?; let tag: String? }

    @Sendable func save(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf: ByteBuffer
        do { buf = try await req.body.collect(upTo: 64_000) }
        catch { return jsonError(.badRequest, "bad_request", "body unreadable") }
        guard let body = try? JSONDecoder().decode(SaveBody.self, from: Data(buf.readableBytesView)),
              !body.kind.isEmpty, !body.label.isEmpty else {
            return jsonError(.badRequest, "bad_request", "invalid save body")
        }

        // The user's own identity is a singleton — route to the self node, never a generic merge.
        if body.kind == "self" {
            let id: String
            do {
                id = try services.store.upsertSelf(name: body.label, detail: body.body, embedder: services.embedder)
            } catch {
                return jsonError(.internalServerError, "save_failed", "\(error)")
            }
            struct SelfOut: Encodable { let id: String; let mergedInto: String? }
            let data = try JSONEncoder().encode(SelfOut(id: id, mergedInto: nil))
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
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
        // Embed the query ONCE and reuse it for both node retrieval and recent-turn selection
        // (avoids a second embedder HTTP round-trip).
        let qv = try? services.embedder.embed(body.query)
        let retrieved: [Node]
        do { retrieved = try services.retriever.retrieve(query: body.query, k: limit, queryVector: qv) }
        catch { return jsonError(.internalServerError, "recall_failed", "\(error)") }

        // Recent relevant turns from OTHER threads that haven't consolidated yet — cross-chat
        // memory for a chat opened seconds after another, before consolidation runs. The current
        // thread's turns already ride the conversation window, so they're excluded.
        var recentTurns: [(role: String, text: String)] = []
        if let qv {
            let hits = (try? services.store.nearestTranscript(to: qv, k: limit * 3)) ?? []
            let turns = (try? services.transcript.rows(ids: hits.map { $0.turnId })) ?? []
            let byId = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for hit in hits {
                guard let t = byId[hit.turnId], !t.consolidated, t.threadId != body.threadId else { continue }
                recentTurns.append((t.role, t.text))
                if recentTurns.count >= 4 { break }
            }
        }

        let coreNodes = (try? services.store.coreMemories(limit: limit)) ?? []
        let coreIds = Set(coreNodes.map { $0.id })
        var recallNodes = retrieved.filter { !coreIds.contains($0.id) }
        if let tag = body.tag, !tag.isEmpty {
            let allowed = Set((try? services.store.nodesWithTag(tag)) ?? [])
            recallNodes = recallNodes.filter { allowed.contains($0.id) }
        }
        let summaryKind = NodeKind.summary.rawValue
        let atomicNodes = recallNodes.filter { $0.kind != summaryKind }
        let summaryNodes = recallNodes.filter { $0.kind == summaryKind }

        struct OutNode: Encodable { let id: String; let kind: String; let label: String; let body: String; let extra: String?; let tags: [String] }
        struct OutSummary: Encodable { let summaryId: String; let chatId: String; let messageRange: [Int]; let text: String }
        struct OutTurn: Encodable { let role: String; let text: String }
        struct Payload: Encodable { let core: [OutNode]; let recall: [OutNode]; let summaries: [OutSummary]; let recentTurns: [OutTurn] }
        func toOut(_ n: Node) -> OutNode {
            OutNode(id: n.id, kind: n.kind, label: n.label, body: n.body, extra: n.extra,
                    tags: (try? services.store.tagsFor(nodeId: n.id)) ?? [])
        }
        // NOTE: a summary node whose extra lacks parseable threadId/turnRange returns nil here and
        // is dropped from BOTH tiers (it's already excluded from `recall`) — no drill-down ref to surface.
        func toSummary(_ n: Node) -> OutSummary? {
            guard let raw = n.extra?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let chatId = obj["threadId"] as? String,
                  let tr = obj["turnRange"] as? [Int], tr.count == 2 else { return nil }
            return OutSummary(summaryId: n.id, chatId: chatId, messageRange: tr, text: n.body.isEmpty ? n.label : n.body)
        }
        let payload = Payload(core: coreNodes.map(toOut), recall: atomicNodes.map(toOut),
                              summaries: summaryNodes.compactMap(toSummary),
                              recentTurns: recentTurns.map { OutTurn(role: $0.role, text: $0.text) })
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

    /// GET /v1/memory/tags — returns all distinct tags sorted alphabetically.
    /// GET /v1/memory/tags — the distinct thematic tags the user has memories about.
    /// Best-effort read: a store failure degrades to an empty list (never a 500), so the agent's
    /// list_topics tool just reports "no topics" rather than erroring the turn.
    @Sendable func tags(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        struct Payload: Encodable { let tags: [String] }
        let payload = Payload(tags: (try? services.store.distinctTags()) ?? [])
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// GET /v1/memory/by_topic?topic=<text>[&limit=N]
    /// Resolves a natural-language topic to the nearest canonical tag (exact-match first,
    /// then embedding cosine ≤ 0.2), then returns every node carrying that tag.
    @Sendable func byTopic(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        guard let topicRaw = q["topic"], !String(topicRaw).trimmingCharacters(in: .whitespaces).isEmpty else {
            return jsonError(.badRequest, "bad_request", "topic required")
        }
        let topic = String(topicRaw)
        let limit = q["limit"].flatMap { Int(String($0)) } ?? 100

        struct OutNode: Encodable { let kind: String; let label: String; let body: String }
        struct Payload: Encodable { let tag: String; let nodes: [OutNode] }

        // resolveTag + nodesForTopic are separated so we can include the resolved tag in the response.
        guard let tag = MemoryQueries.resolveTag(topic, store: services.store, embedder: services.embedder) else {
            // No tag matched → empty result (tag "" is the no-match sentinel; the client checks nodes).
            let data = try JSONEncoder().encode(Payload(tag: "", nodes: []))
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
        }

        // Shared fetch (also used by the gateway's recall_by_topic tool) — no duplication.
        let nodes = MemoryQueries.nodesForTag(tag, store: services.store, limit: limit)
            .map { OutNode(kind: $0.kind, label: $0.label, body: $0.body) }
        let data = try JSONEncoder().encode(Payload(tag: tag, nodes: nodes))
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// GET /v1/memory/why?claim=<text> — justify a belief: find the matching insight and return the
    /// source memories it `derivesFrom`. Best-effort read (empty result, never 500).
    @Sendable func why(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        guard let claimRaw = q["claim"], !String(claimRaw).trimmingCharacters(in: .whitespaces).isEmpty else {
            return jsonError(.badRequest, "bad_request", "claim required")
        }
        let claim = String(claimRaw)
        struct OutNode: Encodable { let kind: String; let label: String; let body: String }
        struct Payload: Encodable { let insight: String; let sources: [OutNode] }
        let result = MemoryQueries.why(claim, store: services.store, embedder: services.embedder)
        guard let ins = result.insight else {
            let data = try JSONEncoder().encode(Payload(insight: "", sources: []))
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
        }
        let sources = result.sources.map { OutNode(kind: $0.kind, label: $0.label, body: $0.body) }
        let data = try JSONEncoder().encode(Payload(insight: ins.body, sources: sources))
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}
