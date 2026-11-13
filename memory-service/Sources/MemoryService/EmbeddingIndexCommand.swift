import Foundation
import MemoryCore

enum EmbeddingIndexCommand {
    enum CommandError: Error, CustomStringConvertible {
        case usage

        var description: String {
            "Usage: memory-service embedding-index status|rebuild|activate <expected-revision>"
        }
    }

    static func run(_ arguments: [String], config: AppConfig) async throws {
        guard arguments.first == "embedding-index", arguments.count >= 2 else { throw CommandError.usage }
        let version = config.embeddingVersion
        switch (arguments[1], arguments.count) {
        case ("status", 2):
            let state = try MemoryStore(path: config.dbPath).embeddingIndexState()
            print("Activation revision: \(state.revision)")
            if let active = state.version {
                print("Active: \(active.modelID) \(active.revision) (\(active.dimension) dimensions)")
            } else {
                print("Active: legacy")
            }
        case ("rebuild", 2):
            let store = try MemoryStore(path: config.dbPath)
            let embedder = try config.makeEmbedder()
            // Check identity even on an empty rebuild, before recording its readiness.
            _ = try await embedder.embed(["Embedding index compatibility check."])
            do {
                try await store.rebuildIndex(version: version) { texts in
                    try await embedder.embed(texts)
                }
            } catch EmbeddingIndexError.sourceChanged {
                throw OperatorError("Memory changed during the rebuild. Run rebuild again.")
            } catch EmbeddingIndexError.staleRevision {
                throw OperatorError("The active index changed during the rebuild. Check status and rebuild again.")
            }
            print("Prepared: \(version.modelID) \(version.revision)")
        case ("activate", 3):
            guard let revision = Int64(arguments[2]), revision >= 0 else { throw CommandError.usage }
            let store = try MemoryStore(path: config.dbPath)
            let embedder = try config.makeEmbedder()
            _ = try await embedder.embed(["Embedding index compatibility check."])
            do {
                try store.activateIndex(version: version, expectedRevision: revision)
            } catch EmbeddingIndexError.sourceChanged {
                throw OperatorError("Memory changed after the rebuild. Rebuild again before activating.")
            } catch EmbeddingIndexError.staleRevision {
                throw OperatorError("The activation revision changed. Check status before retrying.")
            } catch EmbeddingIndexError.indexNotReady {
                throw OperatorError("There is no ready index for the configured version. Run rebuild first.")
            }
            print("Activated: \(version.modelID) \(version.revision)")
        default:
            throw CommandError.usage
        }
    }

    private struct OperatorError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
