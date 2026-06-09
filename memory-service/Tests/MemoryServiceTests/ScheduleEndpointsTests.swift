import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class ScheduleEndpointsTests: XCTestCase {
    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = await Services(store: store,
                                      transcript: TranscriptStore(dbQueue: store.dbQueue),
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }

    func test_create_then_check_conflict_then_window() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // create a trip [1000,2000)
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Trip","start":1000,"end":2000,"allDay":true,"origin":"user"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true"))
            }
            // check a conflicting slot [1500,1600)
            try await client.execute(uri: "/v1/schedule/check", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"start":1500,"end":1600}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("Trip"))
            }
            // create conflicting without force → not created
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Meeting","start":1500,"end":1600,"origin":"user","force":false}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":false"))
            }
            // window returns the trip
            try await client.execute(uri: "/v1/schedule/window?from=0&to=5000", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("Trip"))
            }
        }
    }

    func test_force_creates_despite_conflict() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // create a trip [1000,2000)
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Trip","start":1000,"end":2000,"allDay":true,"origin":"user"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true"))
            }
            // create conflicting [1500,1600) with force:true → created AND conflict listed
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Meeting","start":1500,"end":1600,"origin":"user","force":true}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"created\":true"), "Expected created:true, got: \(body)")
                XCTAssertTrue(body.contains("Trip"), "Expected conflict 'Trip' listed, got: \(body)")
            }
        }
    }

    func test_cancel_by_range() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // create event [1000,2000)
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Trip","start":1000,"end":2000,"allDay":true,"origin":"user"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
            // cancel by range [0,5000)
            try await client.execute(uri: "/v1/schedule/cancel", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"from":0,"to":5000}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertTrue(body.contains("\"cancelled\":1"), "Expected cancelled:1, got: \(body)")
            }
            // window no longer lists the event (default excludes cancelled)
            try await client.execute(uri: "/v1/schedule/window?from=0&to=5000", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let body = String(buffer: res.body)
                XCTAssertFalse(body.contains("Trip"), "Expected Trip to be absent, got: \(body)")
            }
        }
    }

    func test_cancel_empty_body_returns_400() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/schedule/cancel", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: "{}")) { res in
                XCTAssertEqual(res.status, .badRequest)
            }
        }
    }

    func test_malformed_create_body_returns_400() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: "not json")) { res in
                XCTAssertEqual(res.status, .badRequest)
            }
        }
    }

    func test_update_event_endpoint_move_notfound_conflict() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            let auth: HTTPFields = [.authorization: "Bearer test-token", .contentType: "application/json"]
            // Seed two same-day events: meeting [9000,9600), dentist [3000,3600).
            try await client.execute(uri: "/v1/schedule/create", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"title":"meeting","start":9000,"end":9600,"origin":"user"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true")) }
            try await client.execute(uri: "/v1/schedule/create", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"title":"dentist","start":3000,"end":3600,"origin":"user"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true")) }

            // notFound: no event at start=999999.
            try await client.execute(uri: "/v1/schedule/update", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"start":999999,"location":"Miami"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"notFound\":true")) }

            // location-only update on the meeting → updated true.
            try await client.execute(uri: "/v1/schedule/update", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"start":9000,"title":"meeting","location":"Miami"}"#)) { res in
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"updated\":true"))
                XCTAssertTrue(s.contains("Miami")) }

            // time move onto the dentist slot, no force → updated false + conflicts.
            try await client.execute(uri: "/v1/schedule/update", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"start":9000,"title":"meeting","newStart":3000,"newEnd":3600}"#)) { res in
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"updated\":false"))
                XCTAssertTrue(s.contains("dentist")) }
        }
    }

    // Covers the two HTTP response shapes the first test doesn't reach: `ambiguous` and the
    // force-applies-despite-conflict path.
    func test_update_event_endpoint_ambiguous_and_force() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            let auth: HTTPFields = [.authorization: "Bearer test-token", .contentType: "application/json"]
            // Two same-title, same-day events → ambiguous when the passed start matches neither.
            try await client.execute(uri: "/v1/schedule/create", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"title":"sync","start":4000,"end":4600,"origin":"user"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true")) }
            try await client.execute(uri: "/v1/schedule/create", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"title":"sync","start":8000,"end":8600,"origin":"user"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true")) }
            // start=6000 matches neither exactly → ambiguous list, no change.
            try await client.execute(uri: "/v1/schedule/update", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"start":6000,"title":"sync","location":"X"}"#)) { res in
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"ambiguous\""), s)
                XCTAssertTrue(s.contains("\"updated\":false"), s) }

            // A blocking event, then a FORCED time-move of sync@8000 onto its slot → applied.
            try await client.execute(uri: "/v1/schedule/create", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"title":"block","start":2000,"end":2600,"origin":"user"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true")) }
            try await client.execute(uri: "/v1/schedule/update", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"start":8000,"title":"sync","newStart":2000,"newEnd":2600,"force":true}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"updated\":true")) }
        }
    }
}
