import Foundation
import Hummingbird
import NIOCore
import HTTPTypes
import MemoryCore

/// Endpoints under `/v1/connection-services`:
/// - `GET /v1/connection-services` -> lists all connected service summaries
/// - `GET /v1/connection-services/:service` -> gets credentials for a service
/// - `POST /v1/connection-services/:service` -> saves/updates credentials for a service
/// - `DELETE /v1/connection-services/:service` -> deletes a service's stored credentials
struct ConnectionServicesHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.get("/connection-services", use: listServices)
        group.get("/connection-services/:service", use: getService)
        group.post("/connection-services/:service", use: setService)
        group.delete("/connection-services/:service", use: deleteService)
    }

    private func json(_ obj: Any, _ status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    @Sendable func listServices(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        do {
            let list = try services.connectionServices.list()
            let array = list.map { ["id": $0.id, "updatedAt": $0.updatedAt] }
            return json(["services": array])
        } catch {
            return jsonError(.internalServerError, "store_error", "\(error)")
        }
    }

    @Sendable func getService(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let serviceId = ctx.parameters.get("service"), !serviceId.isEmpty else {
            return jsonError(.badRequest, "bad_request", "service parameter required")
        }
        do {
            guard let record = try services.connectionServices.load(id: serviceId) else {
                return jsonError(.notFound, "not_found", "Service \(serviceId) not found")
            }
            var credentialsObj: Any = [:]
            if let data = record.payloadJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                credentialsObj = parsed
            }
            return json([
                "id": record.id,
                "updatedAt": record.updatedAt,
                "credentials": credentialsObj
            ])
        } catch {
            return jsonError(.internalServerError, "store_error", "\(error)")
        }
    }

    @Sendable func setService(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let serviceId = ctx.parameters.get("service"), !serviceId.isEmpty else {
            return jsonError(.badRequest, "bad_request", "service parameter required")
        }
        guard let buf = try? await req.body.collect(upTo: 64_000) else {
            return jsonError(.badRequest, "bad_request", "payload required")
        }
        let data = Data(buf.readableBytesView)
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return jsonError(.badRequest, "bad_request", "JSON object required")
        }
        
        let payloadToStore: [String: Any]
        if let nested = jsonObject["credentials"] as? [String: Any] {
            payloadToStore = nested
        } else {
            payloadToStore = jsonObject
        }
        
        guard let serializedData = try? JSONSerialization.data(withJSONObject: payloadToStore),
              let jsonString = String(data: serializedData, encoding: .utf8) else {
            return jsonError(.badRequest, "bad_request", "Cannot serialize payload")
        }

        let verify = serviceId == "amazon-atoz" && jsonObject["verify"] as? Bool == true
        if verify {
            guard let cookie = payloadToStore["cookie"] as? String,
                  let employeeId = payloadToStore["employeeId"] as? String,
                  !cookie.isEmpty, !employeeId.isEmpty,
                  AtoZSessionVerifier.credentialsAreCurrent(cookie: cookie, employeeId: employeeId) else {
                return jsonError(.badRequest, "invalid_credentials", "Incomplete A to Z credentials")
            }
            do {
                guard try await AtoZSessionVerifier.verify(cookie: cookie, employeeId: employeeId) else {
                    return jsonError(.unprocessableContent, "amazon_session_rejected", "Amazon rejected the exported session")
                }
            } catch {
                return jsonError(.badGateway, "amazon_unavailable", "Could not verify the session with Amazon")
            }
        }

        let updatedAt = Date().timeIntervalSince1970
        do {
            try services.connectionServices.save(id: serviceId, payloadJSON: jsonString, updatedAt: updatedAt)
            return json([
                "ok": true,
                "id": serviceId,
                "verified": verify,
                "updatedAt": updatedAt
            ])
        } catch {
            return jsonError(.internalServerError, "store_error", "\(error)")
        }
    }

    @Sendable func deleteService(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let serviceId = ctx.parameters.get("service"), !serviceId.isEmpty else {
            return jsonError(.badRequest, "bad_request", "service parameter required")
        }
        do {
            let deleted = try services.connectionServices.delete(id: serviceId)
            return json(["ok": true, "deleted": deleted])
        } catch {
            return jsonError(.internalServerError, "store_error", "\(error)")
        }
    }
}
