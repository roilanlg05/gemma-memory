import Foundation
import GRDB

public struct EmbeddingIndexVersion: Codable, Equatable, Hashable, Sendable {
    public let modelID: String
    public let dimension: Int
    public let revision: String

    public init(modelID: String, dimension: Int, revision: String) {
        self.modelID = modelID
        self.dimension = dimension
        self.revision = revision
    }

    fileprivate var arguments: StatementArguments { [modelID, dimension, revision] }

    fileprivate func validate() throws {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_536).contains(dimension) else {
            throw EmbeddingIndexError.invalidVersion
        }
    }
}

public struct EmbeddingIndexState: Codable, Equatable, Sendable {
    public let version: EmbeddingIndexVersion?
    public let revision: Int64
}

public enum EmbeddingIndexError: Error, Equatable {
    case invalidVersion
    case invalidVector
    case dimensionMismatch(expected: Int, actual: Int)
    case versionInUse
    case indexNotActive
    case indexNotReady
    case staleRevision
    case sourceChanged
    case incompleteBatch
    case buildSuperseded
}

extension MemoryStore {
    static func createEmbeddingIndexSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE embedding_index (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model_id TEXT NOT NULL,
                dimension INTEGER NOT NULL CHECK(dimension > 0),
                model_revision TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('building', 'ready', 'active', 'retired')),
                build_token TEXT,
                base_revision INTEGER NOT NULL,
                source_revision INTEGER NOT NULL,
                UNIQUE(model_id, dimension, model_revision)
            );
            CREATE TABLE embedding_index_pointer (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                index_id INTEGER REFERENCES embedding_index(id),
                revision INTEGER NOT NULL,
                source_revision INTEGER NOT NULL
            );
            INSERT INTO embedding_index_pointer VALUES (1, NULL, 0, 0);
            CREATE TABLE indexed_node_embedding (
                index_id INTEGER NOT NULL REFERENCES embedding_index(id) ON DELETE CASCADE,
                node_id TEXT NOT NULL REFERENCES node(id) ON DELETE CASCADE,
                fingerprint TEXT NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY(index_id, node_id)
            );
            CREATE INDEX indexed_node_embedding_source ON indexed_node_embedding(node_id);
            CREATE TABLE indexed_transcript_embedding (
                index_id INTEGER NOT NULL REFERENCES embedding_index(id) ON DELETE CASCADE,
                turn_id TEXT NOT NULL REFERENCES transcript(id) ON DELETE CASCADE,
                fingerprint TEXT NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY(index_id, turn_id)
            );
            CREATE INDEX indexed_transcript_embedding_source ON indexed_transcript_embedding(turn_id);
            """)

        let eligibleNode = "deleted = 0 AND kind NOT IN ('hub', 'cluster') AND id NOT LIKE 'hub:%'"
        let eligibleTurn = "consolidated = 0"
        try db.execute(sql: """
            CREATE VIEW embedding_node_source AS
            SELECT id, CASE WHEN body = '' OR CAST(body AS BLOB) = CAST(label AS BLOB)
                THEN label ELSE label || char(10) || body END AS text FROM node WHERE \(eligibleNode);
            CREATE VIEW embedding_transcript_source AS
            SELECT id, text FROM transcript WHERE \(eligibleTurn);
            """)
        for source in EmbeddingSource.Kind.allCases {
            let table = source.sourceTable
            let isNode = source == .node
            let newIsEligible = isNode
                ? "NEW.deleted = 0 AND NEW.kind NOT IN ('hub', 'cluster') AND NEW.id NOT LIKE 'hub:%'"
                : "NEW.consolidated = 0"
            let oldIsEligible = newIsEligible.replacingOccurrences(of: "NEW.", with: "OLD.")
            let changedColumns = isNode ? "label, body, kind, deleted" : "text, consolidated"
            let changedText = isNode
                ? "CAST(OLD.label AS BLOB) != CAST(NEW.label AS BLOB) OR CAST(OLD.body AS BLOB) != CAST(NEW.body AS BLOB)"
                : "CAST(OLD.text AS BLOB) != CAST(NEW.text AS BLOB)"
            try db.execute(sql: """
                CREATE TRIGGER embedding_\(table)_insert AFTER INSERT ON \(table)
                WHEN \(newIsEligible) BEGIN
                    UPDATE embedding_index_pointer SET source_revision = source_revision + 1;
                END;
                CREATE TRIGGER embedding_\(table)_delete AFTER DELETE ON \(table) BEGIN
                    DELETE FROM \(source.legacyTable) WHERE \(source.idColumn) = OLD.id;
                    UPDATE embedding_index_pointer SET source_revision = source_revision + 1 WHERE \(oldIsEligible);
                END;
                CREATE TRIGGER embedding_\(table)_change AFTER UPDATE OF \(changedColumns) ON \(table)
                WHEN (\(oldIsEligible)) != (\(newIsEligible)) OR
                    ((\(oldIsEligible)) AND (\(changedText))) BEGIN
                    DELETE FROM \(source.indexedTable) WHERE \(source.idColumn) = OLD.id;
                    DELETE FROM \(source.legacyTable) WHERE \(source.idColumn) = OLD.id;
                    UPDATE embedding_index_pointer SET source_revision = source_revision + 1;
                END;
                """)
        }
    }

    public func embeddingIndexState() throws -> EmbeddingIndexState {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT p.revision, i.model_id, i.dimension, i.model_revision FROM embedding_index_pointer p
                LEFT JOIN embedding_index i ON i.id = p.index_id WHERE p.id = 1
                """)!
            let modelID: String? = row["model_id"]
            return EmbeddingIndexState(
                version: modelID.map { EmbeddingIndexVersion(modelID: $0, dimension: row["dimension"], revision: row["model_revision"]) },
                revision: row["revision"])
        }
    }

    /// Initialize a named index on an empty database. Existing memory is migrated by staging
    /// a rebuild. Startup can call this repeatedly without changing the active pointer.
    public func bootstrapEmbeddingIndex(version: EmbeddingIndexVersion) throws {
        try version.validate()
        try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: """
                SELECT revision = 0 AND NOT EXISTS (SELECT 1 FROM embedding_index)
                  AND NOT EXISTS (SELECT 1 FROM embedding_node_source)
                  AND NOT EXISTS (SELECT 1 FROM embedding_transcript_source)
                  AND NOT EXISTS (SELECT 1 FROM node_embedding)
                  AND NOT EXISTS (SELECT 1 FROM transcript_embedding)
                FROM embedding_index_pointer WHERE id = 1
                """) == true else { return }
            try db.execute(sql: """
                INSERT INTO embedding_index(model_id, dimension, model_revision, status, base_revision, source_revision)
                SELECT ?, ?, ?, 'active', revision, source_revision FROM embedding_index_pointer WHERE id = 1
                """, arguments: version.arguments)
            try db.execute(sql: "UPDATE embedding_index_pointer SET index_id = ?, revision = 1 WHERE id = 1",
                           arguments: [db.lastInsertedRowID])
        }
    }

    /// Build into a separate index. Re-running a stage replaces its private attempt token,
    /// allowing immediate recovery from an interrupted build while fencing off late writes.
    public func rebuildIndex(version: EmbeddingIndexVersion,
                             embed: @Sendable ([String]) async throws -> [[Float]]) async throws {
        try version.validate()
        try Task.checkCancellation()
        let token = UUID().uuidString
        let indexID = try await dbQueue.write { db -> Int64 in
            try db.execute(sql: """
                DELETE FROM embedding_index WHERE model_id = ? AND dimension = ? AND model_revision = ?
                AND status != 'active'
                """, arguments: version.arguments)
            guard try Self.indexID(version, db: db) == nil else { throw EmbeddingIndexError.versionInUse }
            try db.execute(sql: """
                INSERT INTO embedding_index(model_id, dimension, model_revision, status, build_token, base_revision, source_revision)
                SELECT ?, ?, ?, 'building', ?, revision, source_revision FROM embedding_index_pointer WHERE id = 1
                """, arguments: version.arguments + [token])
            return db.lastInsertedRowID
        }

        do {
            for kind in EmbeddingSource.Kind.allCases {
                var after: String?
                while true {
                    try Task.checkCancellation()
                    let cursor = after
                    let sources = try await dbQueue.read { db in
                        try Self.requireCurrentBuild(indexID, token: token, db: db)
                        return try EmbeddingSource.batch(kind: kind, after: cursor, db: db)
                    }
                    guard let last = sources.last else { break }
                    let vectors = try await embed(sources.map(\.text))
                    try Task.checkCancellation()
                    guard sources.count == vectors.count else { throw EmbeddingIndexError.incompleteBatch }
                    for vector in vectors { try Self.validateEmbedding(vector, dimension: version.dimension) }
                    try await dbQueue.write { db in
                        try Self.requireCurrentBuild(indexID, token: token, db: db)
                        for (source, vector) in zip(sources, vectors) {
                            try source.write(vector, indexID: indexID, db: db)
                        }
                    }
                    after = last.id
                }
            }
            try Task.checkCancellation()
            try await dbQueue.write { db in
                try Self.requireCurrentBuild(indexID, token: token, db: db)
                try Self.validateCompleteIndex(indexID, dimension: version.dimension, db: db)
                try db.execute(sql: "UPDATE embedding_index SET status = 'ready', build_token = NULL WHERE id = ?",
                               arguments: [indexID])
            }
        } catch {
            // A canceled task may be rejected by GRDB's async writer. Clean up synchronously
            // using the attempt token so a superseding build is never removed.
            discardEmbeddingBuild(indexID, token: token)
            throw error
        }
    }

    private func discardEmbeddingBuild(_ id: Int64, token: String) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM embedding_index WHERE id = ? AND build_token = ?",
                           arguments: [id, token])
        }
    }

    public func activateIndex(version: EmbeddingIndexVersion, expectedRevision: Int64) throws {
        try version.validate()
        try dbQueue.write { db in
            let pointer = try Row.fetchOne(db, sql: "SELECT * FROM embedding_index_pointer WHERE id = 1")!
            let revision: Int64 = pointer["revision"]
            guard revision == expectedRevision else { throw EmbeddingIndexError.staleRevision }
            guard let ready = try Row.fetchOne(db, sql: """
                SELECT id, base_revision, source_revision FROM embedding_index
                WHERE model_id = ? AND dimension = ? AND model_revision = ? AND status = 'ready'
                """, arguments: version.arguments) else { throw EmbeddingIndexError.indexNotReady }
            guard (ready["base_revision"] as Int64) == revision else { throw EmbeddingIndexError.staleRevision }
            guard (ready["source_revision"] as Int64) == (pointer["source_revision"] as Int64)
            else { throw EmbeddingIndexError.sourceChanged }
            let newIndex: Int64 = ready["id"]
            try Self.validateCompleteIndex(newIndex, dimension: version.dimension, db: db)
            let oldIndex: Int64? = pointer["index_id"]
            try db.execute(sql: "UPDATE embedding_index SET status = 'retired' WHERE id = ?", arguments: [oldIndex])
            try db.execute(sql: "UPDATE embedding_index SET status = 'active' WHERE id = ?", arguments: [newIndex])
            try db.execute(sql: "UPDATE embedding_index_pointer SET index_id = ?, revision = revision + 1 WHERE id = 1",
                           arguments: [newIndex])
        }
    }

    static func activeEmbeddingIndexID(_ version: EmbeddingIndexVersion, db: Database) throws -> Int64? {
        try version.validate()
        return try Int64.fetchOne(db, sql: """
            SELECT i.id FROM embedding_index i JOIN embedding_index_pointer p ON p.index_id = i.id
            WHERE i.model_id = ? AND i.dimension = ? AND i.model_revision = ?
            """, arguments: version.arguments)
    }

    private static func indexID(_ version: EmbeddingIndexVersion, db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT id FROM embedding_index WHERE model_id = ? AND dimension = ? AND model_revision = ?
            """, arguments: version.arguments)
    }

    private static func requireCurrentBuild(_ id: Int64, token: String, db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT i.base_revision = p.revision AS current_index, i.source_revision = p.source_revision AS current_source
            FROM embedding_index i CROSS JOIN embedding_index_pointer p
            WHERE i.id = ? AND i.build_token = ? AND i.status = 'building' AND p.id = 1
            """, arguments: [id, token]) else { throw EmbeddingIndexError.buildSuperseded }
        guard row["current_index"] as Bool else { throw EmbeddingIndexError.staleRevision }
        guard row["current_source"] as Bool else { throw EmbeddingIndexError.sourceChanged }
    }

    private static func validateCompleteIndex(_ id: Int64, dimension: Int, db: Database) throws {
        for kind in EmbeddingSource.Kind.allCases {
            let rows = try Row.fetchCursor(db, sql: """
                SELECT s.text, e.embedding, e.fingerprint FROM \(kind.sourceView) s
                LEFT JOIN \(kind.indexedTable) e ON e.\(kind.idColumn) = s.id AND e.index_id = ?
                """, arguments: [id])
            while let row = try rows.next() {
                guard let blob = row["embedding"] as Data?, let fingerprint = row["fingerprint"] as String?
                else { throw EmbeddingIndexError.incompleteBatch }
                guard fingerprint == BrainStore.digest(row["text"]) else { throw EmbeddingIndexError.sourceChanged }
                try validateEmbedding(blobToFloats(blob), dimension: dimension)
            }
            guard try Bool.fetchOne(db, sql: """
                SELECT NOT EXISTS (SELECT 1 FROM \(kind.indexedTable) e
                LEFT JOIN \(kind.sourceView) s ON e.\(kind.idColumn) = s.id
                WHERE e.index_id = ? AND s.id IS NULL)
                """, arguments: [id]) == true else { throw EmbeddingIndexError.sourceChanged }
        }
    }

    static func validateEmbedding(_ values: [Float], dimension: Int) throws {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { throw EmbeddingIndexError.invalidVector }
        guard values.count == dimension else {
            throw EmbeddingIndexError.dimensionMismatch(expected: dimension, actual: values.count)
        }
    }
}

struct EmbeddingSource: Sendable {
    enum Kind: CaseIterable, Sendable {
        case node, transcript

        var sourceTable: String { self == .node ? "node" : "transcript" }
        var sourceView: String { "embedding_\(sourceTable)_source" }
        var legacyTable: String { "\(sourceTable)_embedding" }
        var indexedTable: String { "indexed_\(legacyTable)" }
        var idColumn: String { self == .node ? "node_id" : "turn_id" }
    }

    let kind: Kind
    let id: String
    let text: String

    static func batch(kind: Kind, after: String?, db: Database) throws -> [Self] {
        try Row.fetchAll(db, sql: """
            SELECT id, text FROM \(kind.sourceView) WHERE (? IS NULL OR id > ?) ORDER BY id LIMIT 32
            """, arguments: [after, after]).map { .init(kind: kind, id: $0["id"], text: $0["text"]) }
    }

    func write(_ vector: [Float], indexID: Int64, db: Database) throws {
        try requireCurrent(in: db)
        try db.execute(sql: """
            INSERT INTO \(kind.indexedTable)(index_id, \(kind.idColumn), fingerprint, embedding)
            VALUES (?, ?, ?, ?) ON CONFLICT(index_id, \(kind.idColumn))
            DO UPDATE SET fingerprint = excluded.fingerprint, embedding = excluded.embedding
            """, arguments: [indexID, id, BrainStore.digest(text), MemoryStore.floatsToBlob(vector)])
    }

    func requireCurrent(in db: Database) throws {
        guard let current = try String.fetchOne(db, sql: "SELECT text FROM \(kind.sourceView) WHERE id = ?", arguments: [id]),
              current.utf8.elementsEqual(text.utf8) else { throw EmbeddingIndexError.sourceChanged }
    }
}
