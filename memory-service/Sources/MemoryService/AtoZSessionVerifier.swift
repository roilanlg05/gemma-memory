import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Verifies the exported header independently of the browser cookie store.
enum AtoZSessionVerifier {
    static func verify(cookie: String, employeeId: String) async throws -> Bool {
        guard credentialsAreCurrent(cookie: cookie, employeeId: employeeId) else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg, delegate: AtoZNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = try makeRequest(cookie: cookie, employeeId: employeeId)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return accepts(status: http.statusCode, data: data)
    }

    static func credentialsAreCurrent(cookie: String, employeeId: String) -> Bool {
        guard !cookie.contains("\r"), !cookie.contains("\n"),
              let entry = cookie.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("atoz-oauth-token=") }) else { return false }
        let parts = entry.dropFirst("atoz-oauth-token=".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double, exp.isFinite,
              exp > Date().timeIntervalSince1970 + 60 else { return false }
        // amazon_scheduler.py uses its configured EMPLOYEE_ID, not JWT sub.
        return !employeeId.isEmpty
    }

    static func makeRequest(cookie: String, employeeId: String) throws -> URLRequest {
        var url = URLComponents(string: "https://atoz-apps.amazon.work/apis/ScheduleManagementAssociateGateway/graphql")!
        url.queryItems = [URLQueryItem(name: "employeeId", value: employeeId)]
        var req = URLRequest(url: url.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Agent/Gemma", forHTTPHeaderField: "User-Agent")
        req.setValue("SCHEDULE_MANAGEMENT_SERVICE", forHTTPHeaderField: "x-atoz-client-id")
        req.setValue("https://atoz.amazon.work", forHTTPHeaderField: "Origin")
        req.setValue("https://atoz.amazon.work/", forHTTPHeaderField: "Referer")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        let now = Date()
        let iso = ISO8601DateFormatter()
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "operationName": "GemmaScheduleCheck",
            "query": "query GemmaScheduleCheck($timeRange: DateTimeRangeInput!) { schedule(timeRange: $timeRange) { scheduleShifts { shift { id } } } }",
            "variables": ["timeRange": ["start": iso.string(from: now), "end": iso.string(from: now.addingTimeInterval(86400))]]
        ])
        return req
    }

    static func accepts(status: Int, data: Data) -> Bool {
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["errors"] == nil || (root["errors"] as? [Any])?.isEmpty == true,
              let payload = root["data"] as? [String: Any],
              let schedule = payload["schedule"] as? [String: Any],
              schedule["scheduleShifts"] is [Any] else { return false }
        return true
    }
}

private final class AtoZNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
