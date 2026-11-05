import XCTest
import GRDB
@testable import MemoryCore

final class ConnectionServicesStoreTests: XCTestCase {
    func test_empty_returnsNil() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cs = ConnectionServicesStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "test-token"))
        XCTAssertNil(try cs.load(id: "amazon-atoz"))
        XCTAssertEqual(try cs.list(), [])
    }

    func test_save_load_roundTrip_and_encryptsCipher() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cs = ConnectionServicesStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "test-token"))
        let payload = #"{"cookie":"session-123","employeeId":"456"}"#
        try cs.save(id: "amazon-atoz", payloadJSON: payload, updatedAt: 12345.0)

        let loaded = try cs.load(id: "amazon-atoz")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "amazon-atoz")
        XCTAssertEqual(loaded?.updatedAt, 12345.0)
        XCTAssertEqual(loaded?.payloadJSON, payload)

        // Verify cipher in DB is not plaintext
        let rawCipher: Data? = try store.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT payloadCipher FROM connection_services WHERE id = ?", arguments: ["amazon-atoz"])
        }
        XCTAssertNotNil(rawCipher)
        XCTAssertNotEqual(rawCipher, Data(payload.utf8))
    }

    func test_save_updates_existing_and_list_and_delete() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cs = ConnectionServicesStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "test-token"))
        try cs.save(id: "service-a", payloadJSON: #"{"key":"val1"}"#, updatedAt: 100.0)
        try cs.save(id: "service-b", payloadJSON: #"{"key":"val2"}"#, updatedAt: 200.0)

        let list = try cs.list()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map { $0.id }, ["service-a", "service-b"])

        // Update service-a
        try cs.save(id: "service-a", payloadJSON: #"{"key":"updated"}"#, updatedAt: 300.0)
        let updated = try cs.load(id: "service-a")
        XCTAssertEqual(updated?.payloadJSON, #"{"key":"updated"}"#)
        XCTAssertEqual(updated?.updatedAt, 300.0)

        // Delete service-a
        let deleted = try cs.delete(id: "service-a")
        XCTAssertTrue(deleted)
        XCTAssertNil(try cs.load(id: "service-a"))
        let listAfter = try cs.list()
        XCTAssertEqual(listAfter.count, 1)
        XCTAssertEqual(listAfter.first?.id, "service-b")
    }
}
