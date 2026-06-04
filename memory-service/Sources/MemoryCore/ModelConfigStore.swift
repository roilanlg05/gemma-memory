import Foundation
import GRDB

/// Persisted consolidation provider config (single row). The API key is stored AES-GCM-encrypted.
/// Reuses the MemoryStore DatabaseQueue; never touches `node`/`transcript`.
public final class ModelConfigStore: @unchecked Sendable {
    public struct Resolved: Sendable, Equatable {
        public let provider: String
        public let baseURL: String
        public let model: String
        public let apiKey: String?
    }

    private let dbQueue: DatabaseQueue
    private let crypto: ConfigCrypto
    private static let rowID = "default"

    public init(dbQueue: DatabaseQueue, crypto: ConfigCrypto) {
        self.dbQueue = dbQueue; self.crypto = crypto
    }

    public func save(provider: String, baseURL: String, model: String, apiKey: String?) throws {
        let cipher = try apiKey.flatMap { $0.isEmpty ? nil : try crypto.seal($0) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO service_config (id, provider, baseURL, model, apiKeyCipher)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, baseURL=excluded.baseURL,
                                              model=excluded.model, apiKeyCipher=excluded.apiKeyCipher
                """, arguments: [Self.rowID, provider, baseURL, model, cipher])
        }
    }

    /// Current config, or nil if nothing persisted. Throws if a stored key fails to decrypt.
    public func load() throws -> Resolved? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT provider, baseURL, model, apiKeyCipher FROM service_config WHERE id = ?",
                arguments: [Self.rowID]) else { return nil }
            let cipher = row["apiKeyCipher"] as Data?
            let key = try cipher.map { try crypto.open($0) }
            return Resolved(provider: row["provider"], baseURL: row["baseURL"], model: row["model"], apiKey: key)
        }
    }
}
