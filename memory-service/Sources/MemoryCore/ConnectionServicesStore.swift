import Foundation
import GRDB

/// Encrypted storage for connection service credentials (e.g. Amazon A to Z, third party APIs).
/// Credentials payloads are encrypted with AES-GCM via `ConfigCrypto` using HKDF derived from the bearer token.
public final class ConnectionServicesStore: @unchecked Sendable {
    public struct ServiceRecord: Sendable, Equatable {
        public let id: String
        public let updatedAt: Double
        public let payloadJSON: String

        public init(id: String, updatedAt: Double, payloadJSON: String) {
            self.id = id
            self.updatedAt = updatedAt
            self.payloadJSON = payloadJSON
        }
    }

    public struct ServiceSummary: Sendable, Equatable {
        public let id: String
        public let updatedAt: Double

        public init(id: String, updatedAt: Double) {
            self.id = id
            self.updatedAt = updatedAt
        }
    }

    private let dbQueue: DatabaseQueue
    private let crypto: ConfigCrypto

    public init(dbQueue: DatabaseQueue, crypto: ConfigCrypto) {
        self.dbQueue = dbQueue
        self.crypto = crypto
    }

    public func save(id: String, payloadJSON: String, updatedAt: Double = Date().timeIntervalSince1970) throws {
        let cipher = try crypto.seal(payloadJSON)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO connection_services (id, payloadCipher, updatedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payloadCipher=excluded.payloadCipher, updatedAt=excluded.updatedAt
                """, arguments: [id, cipher, updatedAt])
        }
    }

    public func load(id: String) throws -> ServiceRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT id, payloadCipher, updatedAt FROM connection_services WHERE id = ?",
                arguments: [id]) else { return nil }
            guard let cipher = row["payloadCipher"] as Data? else { return nil }
            let json = try crypto.open(cipher)
            let updatedAt: Double = row["updatedAt"]
            return ServiceRecord(id: id, updatedAt: updatedAt, payloadJSON: json)
        }
    }

    public func list() throws -> [ServiceSummary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, updatedAt FROM connection_services ORDER BY id ASC")
            return rows.map { row in
                ServiceSummary(id: row["id"], updatedAt: row["updatedAt"])
            }
        }
    }

    public func delete(id: String) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM connection_services WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
