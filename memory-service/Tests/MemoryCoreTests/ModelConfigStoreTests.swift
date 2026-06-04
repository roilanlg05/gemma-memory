import XCTest
import GRDB
@testable import MemoryCore

final class ModelConfigStoreTests: XCTestCase {
    func test_empty_returnsNil() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        XCTAssertNil(try cfg.load())
    }
    func test_save_then_load_decryptsKey() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        try cfg.save(provider: "gemini", baseURL: "https://x", model: "gemini-2.5-flash", apiKey: "K")
        let loaded = try cfg.load()
        XCTAssertEqual(loaded?.provider, "gemini")
        XCTAssertEqual(loaded?.model, "gemini-2.5-flash")
        XCTAssertEqual(loaded?.apiKey, "K")
        let raw: Data? = try store.dbQueue.read { try Data.fetchOne($0, sql: "SELECT apiKeyCipher FROM service_config") }
        XCTAssertNotNil(raw); XCTAssertNotEqual(raw, Data("K".utf8))
    }
    func test_save_localNoKey() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        try cfg.save(provider: "local", baseURL: "http://localhost:8080", model: "gemma", apiKey: nil)
        XCTAssertNil(try cfg.load()?.apiKey)
    }
    func test_save_overwrites() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        try cfg.save(provider: "gemini", baseURL: "https://x", model: "m1", apiKey: "K1")
        try cfg.save(provider: "groq", baseURL: "https://y", model: "m2", apiKey: "K2")
        let loaded = try cfg.load()
        XCTAssertEqual(loaded?.provider, "groq")
        XCTAssertEqual(loaded?.apiKey, "K2")
        let count = try store.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM service_config") }
        XCTAssertEqual(count, 1)  // single row
    }
}
