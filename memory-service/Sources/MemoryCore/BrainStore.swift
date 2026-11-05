import Foundation
import BrainContract
import GRDB

public struct BrainLegacyBinding: Sendable {
    public let claimID: String
    public let subject: String
    public let predicate: String
    public let nodeIDs: Set<String>
    public init(claimID: String, subject: String, predicate: String, nodeIDs: Set<String>) {
        self.claimID = claimID; self.subject = subject; self.predicate = predicate; self.nodeIDs = nodeIDs
    }
}
public struct BrainAuthorization: Sendable {
    public let principal: String
    public let owner: String
    public let allowDelegated: Bool
    public let mayCommitClaims: Bool
    public let subjects: Set<String>
    public let scopes: Set<BrainAccessScope>
    public let threads: Set<String>
    public let sourceSpeakers: [BrainSourceKind: Set<String>]
    public let mayProject: Bool
    public let legacyBindings: [BrainLegacyBinding]
    public init(principal: String, owner: String, subjects: Set<String>, scopes: Set<BrainAccessScope>, threads: Set<String>, sourceSpeakers: [BrainSourceKind: Set<String>], mayProject: Bool = false, legacyBindings: [BrainLegacyBinding] = [], allowDelegated: Bool = false, mayCommitClaims: Bool = false) {
        self.principal = principal; self.owner = owner; self.allowDelegated = allowDelegated; self.mayCommitClaims = mayCommitClaims; self.subjects = subjects
        self.scopes = scopes; self.threads = threads; self.sourceSpeakers = sourceSpeakers
        self.mayProject = mayProject; self.legacyBindings = legacyBindings
    }
    public static let deny = BrainAuthorization(principal: "", owner: "", subjects: [], scopes: [], threads: [], sourceSpeakers: [:])
}
public enum BrainStoreError: Error, Equatable { case denied, invalid, conflict, unimplemented }
public final class BrainStore {
    let store: MemoryStore
    let authorization: BrainAuthorization
    public init(store: MemoryStore, authorization: BrainAuthorization = .deny) { self.store = store; self.authorization = authorization }
    func requirePrincipal() throws {
        guard !authorization.principal.isEmpty, !authorization.owner.isEmpty,
              authorization.principal == authorization.owner || authorization.allowDelegated else { throw BrainStoreError.denied }
    }
    func checkOwner(_ db: Database, bind: Bool) throws {
        try requirePrincipal()
        let owner = try String.fetchOne(db, sql: "SELECT owner FROM brain_meta WHERE id=1")
        if let owner { guard owner == authorization.owner else { throw BrainStoreError.denied } }
        else if bind { try db.execute(sql: "UPDATE brain_meta SET owner=? WHERE id=1", arguments: [authorization.owner]) }
    }
    public func revision() throws -> Int64 {
        try store.dbQueue.read { db in try checkOwner(db, bind: false); return try Self.revision(db) }
    }
    static func revision(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT revision FROM brain_meta WHERE id=1") ?? 0
    }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(value.utf8))
    }
    func requireAccess(subject: String, scope: BrainAccessScope) throws {
        try requirePrincipal()
        guard authorization.subjects.contains(subject), authorization.scopes.contains(scope) else { throw BrainStoreError.denied }
    }
    func canRead(_ evidence: BrainEvidence) -> Bool {
        authorization.scopes.contains(evidence.accessScope) && (evidence.accessScope != .thread || authorization.threads.contains(evidence.threadID))
    }
}
