import Foundation
import Hummingbird
import NIOCore
import HTTPTypes
import MemoryCore

/// `POST/GET /v1/config/model` — the macOS app configures the consolidation provider here.
struct ConfigHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/config/model", use: set)
        group.get ("/config/model", use: get)
    }

    private func json(_ obj: Any, _ status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    struct SetBody: Decodable, Sendable {
        let provider: String; let baseURL: String; let model: String; let apiKey: String?
    }

    @Sendable func set(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let buf = try? await req.body.collect(upTo: 16_000),
              let b = try? JSONDecoder().decode(SetBody.self, from: Data(buf.readableBytesView)) else {
            return jsonError(.badRequest, "bad_request", "provider/baseURL/model required")
        }
        if b.provider != "local", (b.apiKey ?? "").isEmpty {
            return jsonError(.badRequest, "key_required", "cloud provider requires an apiKey")
        }
        do { try services.modelConfig.save(provider: b.provider, baseURL: b.baseURL, model: b.model, apiKey: b.apiKey) }
        catch { return jsonError(.internalServerError, "store_error", "\(error)") }
        return json(["ok": true])
    }

    @Sendable func get(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let cfg = (try? services.modelConfig.load()) ?? nil
        let provider = cfg?.provider ?? "local"
        let baseURL = cfg?.baseURL ?? ""
        let model = cfg?.model ?? ""
        let hasKey = (cfg?.apiKey?.isEmpty == false)
        return json(["provider": provider, "baseURL": baseURL, "model": model, "hasKey": hasKey])
    }
}
