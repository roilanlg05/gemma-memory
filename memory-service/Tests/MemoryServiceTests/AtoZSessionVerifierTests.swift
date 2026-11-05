import XCTest
import Foundation
@testable import MemoryService

final class AtoZSessionVerifierTests: XCTestCase {
    private func cookie(exp: Double, sub: String = "12345") -> String {
        let json = try! JSONSerialization.data(withJSONObject: ["exp": exp, "sub": sub])
        let payload = json.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "atoz-oauth-token=header.\(payload).sig"
    }
    func testRejectsExpiredNearExpiryAndAllowsConfiguredEmployee() {
        XCTAssertFalse(AtoZSessionVerifier.credentialsAreCurrent(cookie: cookie(exp: 1), employeeId: "12345"))
        XCTAssertFalse(AtoZSessionVerifier.credentialsAreCurrent(cookie: cookie(exp: Date().timeIntervalSince1970 + 30), employeeId: "12345"))
        XCTAssertTrue(AtoZSessionVerifier.credentialsAreCurrent(cookie: cookie(exp: Date().timeIntervalSince1970 + 3600), employeeId: "204193941"))
        XCTAssertFalse(AtoZSessionVerifier.credentialsAreCurrent(cookie: "atoz-oauth-token=bad", employeeId: "12345"))
        XCTAssertTrue(AtoZSessionVerifier.credentialsAreCurrent(cookie: cookie(exp: Date().timeIntervalSince1970 + 3600), employeeId: "12345"))
    }
    func testEmptyScheduleIsValid() {
        XCTAssertTrue(AtoZSessionVerifier.accepts(status: 200, data: Data(#"{"data":{"schedule":{"scheduleShifts":[]}}}"#.utf8)))
    }
    func testRejectsLoginRedirectsHTMLAndGraphQLErrors() {
        let good = Data(#"{"data":{"schedule":{"scheduleShifts":[]}}}"#.utf8)
        for status in [302, 401, 403, 429, 500] {
            XCTAssertFalse(AtoZSessionVerifier.accepts(status: status, data: good))
        }
        for body in ["<html>Login</html>", #"{"data":{"schedule":null}}"#,
                     #"{"data":{"schedule":{"scheduleShifts":[]}},"errors":[{"message":"Unauthorized"}]}"#,
                     #"{"ok":true}"#] {
            XCTAssertFalse(AtoZSessionVerifier.accepts(status: 200, data: Data(body.utf8)))
        }
    }
    func testUsesExportedHeaderForReadOnlyRequest() throws {
        let req = try AtoZSessionVerifier.makeRequest(cookie: "atoz-oauth-token=synthetic; same=a; same=b", employeeId: "12345")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "atoz-oauth-token=synthetic; same=a; same=b")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "Agent/Gemma")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-atoz-client-id"), "SCHEDULE_MANAGEMENT_SERVICE")
        XCTAssertEqual(req.url?.host, "atoz-apps.amazon.work")
        XCTAssertEqual(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "12345")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        let query = try XCTUnwrap(body["query"] as? String)
        XCTAssertTrue(query.hasPrefix("query "))
        XCTAssertFalse(query.contains("mutation"))
    }
}
