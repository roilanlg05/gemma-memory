import Foundation
import Hummingbird
import Logging
import MemoryCore

public struct AppConfig: Sendable {
    public var bearerToken: String
    public var dbPath: String
    public var embedderURL: String
    public var modelURL: String
    public var modelName: String
    public var port: Int

    public init(bearerToken: String, dbPath: String, embedderURL: String, modelURL: String,
                modelName: String = "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
                port: Int = 8081) {
        self.bearerToken = bearerToken
        self.dbPath = dbPath
        self.embedderURL = embedderURL
        self.modelURL = modelURL
        self.modelName = modelName
        self.port = port
    }

    public static func testDefaults() -> AppConfig {
        AppConfig(bearerToken: "test-token", dbPath: ":memory:",
                  embedderURL: "http://embedder:8000",
                  modelURL: "http://host.docker.internal:8080",
                  port: 0)
    }

    public static func fromEnvironment() -> AppConfig {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["MEMORY_BEARER_TOKEN"] else {
            fatalError("MEMORY_BEARER_TOKEN must be set")
        }
        return AppConfig(
            bearerToken: token,
            dbPath: env["MEMORY_DB_PATH"] ?? "/data/memory.sqlite",
            embedderURL: env["EMBEDDER_URL"] ?? "http://embedder:8000",
            modelURL: env["MODEL_URL"] ?? "http://host.docker.internal:8080",
            modelName: env["MODEL_NAME"] ?? "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
            port: Int(env["MEMORY_PORT"] ?? "8081") ?? 8081
        )
    }
}

/// Process-wide service container — store/transcript/embedder/retriever + bearer token.
/// `@unchecked Sendable`: GRDB `DatabaseQueue` is thread-safe and the stored protocol/class
/// dependencies are also thread-safe (see notes on `MemoryStore`, `TranscriptStore`,
/// `MemoryRetriever`, `RemoteEmbedder`).
public final class Services: @unchecked Sendable {
    public let store: MemoryStore
    public let transcript: TranscriptStore
    public let embedder: any Embedder
    public let retriever: MemoryRetriever
    public let bearerToken: String
    public let modelClient: any ModelTextClient
    public let engine: MemoryConsolidationEngine
    public let scheduler: ConsolidationScheduler
    public let modelConfig: ModelConfigStore

    @MainActor
    public init(config: AppConfig) throws {
        let store = try MemoryStore(path: config.dbPath, embeddingDim: 1024)
        self.store = store
        // Ensure kind hubs + backfill belongsToHub edges on every startup (idempotent).
        // Keeps the graph navigable even after a restart against an older DB.
        try store.ensureKindHubs()
        let transcript = TranscriptStore(dbQueue: store.dbQueue)
        self.transcript = transcript
        let embedder = RemoteEmbedder(baseURL: URL(string: config.embedderURL)!)
        self.embedder = embedder
        self.retriever = MemoryRetriever(store: store, embedder: embedder)
        self.bearerToken = config.bearerToken
        let modelClient = RemoteModelClient(baseURL: URL(string: config.modelURL)!,
                                            model: config.modelName)
        self.modelClient = modelClient
        let engine = MemoryConsolidationEngine(store: store, embedder: embedder,
                                               runtime: modelClient, transcriptStore: transcript)
        self.engine = engine
        // `isReady` is always true (the server only spins up after dependencies exist);
        // `hasPendingCycle` peeks at the persisted sleep_cycle so a server restart resumes.
        self.scheduler = ConsolidationScheduler(
            runner: engine,
            isReady: { true },
            hasPendingCycle: { (try? store.loadSleepCycle()) != nil }
        )
        self.modelConfig = ModelConfigStore(dbQueue: store.dbQueue,
                                            crypto: ConfigCrypto(bearerToken: config.bearerToken))
    }

    /// Test-only injection point. `modelClient` defaults to a NoOp so older tests (Task 7/8)
    /// that only pass `store/transcript/embedder/bearerToken` keep compiling.
    @MainActor
    public init(store: MemoryStore, transcript: TranscriptStore, embedder: any Embedder,
                bearerToken: String,
                modelClient: any ModelTextClient = DefaultNoOpModelClient()) {
        self.store = store
        self.transcript = transcript
        self.embedder = embedder
        self.retriever = MemoryRetriever(store: store, embedder: embedder)
        self.bearerToken = bearerToken
        self.modelClient = modelClient
        let engine = MemoryConsolidationEngine(store: store, embedder: embedder,
                                               runtime: modelClient, transcriptStore: transcript)
        self.engine = engine
        self.scheduler = ConsolidationScheduler(
            runner: engine,
            isReady: { true },
            hasPendingCycle: { (try? store.loadSleepCycle()) != nil }
        )
        self.modelConfig = ModelConfigStore(dbQueue: store.dbQueue,
                                            crypto: ConfigCrypto(bearerToken: bearerToken))
    }
}

/// Default model client used when callers don't provide one (test convenience). Replies with `{}`
/// — empty JSON parses to "no entities/edges" in the consolidation engine, a no-op cycle.
public struct DefaultNoOpModelClient: ModelTextClient {
    public init() {}
    public func generate(prompt: String, options: ModelTextOptions) async throws -> String { "{}" }
}

struct BearerMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let header = request.headers[.authorization],
              header == "Bearer \(token)"
        else {
            return Response(status: .unauthorized)
        }
        return try await next(request, context)
    }
}

/// Production entrypoint used by `main.swift`. Builds a `Services` from the env-derived config.
public func buildApp(config: AppConfig) async throws -> some ApplicationProtocol {
    let services = try await MainActor.run { try Services(config: config) }
    return try await buildApp(services: services, port: config.port)
}

/// Builder accepting a pre-constructed `Services` — used by tests and indirectly by the
/// production path above.
public func buildApp(services: Services, port: Int) async throws -> some ApplicationProtocol {
    let router = Router()
    // Public: health check
    router.get("/healthz") { _, _ -> Response in
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: .init(string: #"{"status":"ok"}"#))
        )
    }
    // Public: readiness probe — pings the embedder to confirm the sidecar (and DB-bound
    // dependencies) are actually serving. Returns 503 if the embedder throws.
    router.get("/readyz") { [services] _, _ -> Response in
        do {
            _ = try services.embedder.embed("readyz")
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: ResponseBody(byteBuffer: .init(string: #"{"status":"ready"}"#))
            )
        } catch {
            return Response(
                status: .serviceUnavailable,
                headers: [.contentType: "application/json"],
                body: ResponseBody(byteBuffer: .init(string: #"{"status":"embedder_unavailable"}"#))
            )
        }
    }
    // Protected: anything under /v1 requires Bearer auth
    let v1 = router.group("/v1").add(middleware: BearerMiddleware(token: services.bearerToken))
    TranscriptHandlers(services: services).register(on: v1)
    MemoryHandlers(services: services).register(on: v1)
    ConsolidationHandlers(services: services).register(on: v1)
    ScheduleHandlers(services: services).register(on: v1)
    InspectorHandlers(services: services).register(on: v1)
    ConfigHandlers(services: services).register(on: v1)
    v1.get("/echo") { _, _ -> Response in
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: .init(string: #"{"ok":true}"#))
        )
    }
    return Application(
        router: router,
        configuration: ApplicationConfiguration(address: .hostname("0.0.0.0", port: port)),
        logger: Logger(label: "memory-service")
    )
}

// MARK: - expand_context (M2d-3 drill-down)

extension Services {
    public struct ExpandResult: Sendable {
        public let rows: [TranscriptRow]
        public let summaryLabel: String?
    }

    /// Locate the best `summary` node whose label matches `topic` (canonical dedup key match,
    /// falling back to case-insensitive substring), then return its referenced transcript range
    /// (`extra` JSON keys `threadId` + `turnRange:[from,to]`). Empty rows + nil label when no
    /// matching summary exists or its extra is malformed.
    public func expandContext(topic: String) throws -> ExpandResult {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ExpandResult(rows: [], summaryLabel: nil) }
        let summaries = (try? store.allNodes())?
            .filter { $0.kind == NodeKind.summary.rawValue } ?? []
        let dedupKey = MemoryText.dedupKey(trimmed)
        let match = summaries.first { MemoryText.dedupKey($0.label) == dedupKey }
            ?? summaries.first { $0.label.localizedCaseInsensitiveContains(trimmed) }
        guard let node = match, let raw = node.extra?.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let threadId = any["threadId"] as? String,
              let tr = any["turnRange"] as? [Int], tr.count == 2 else {
            return ExpandResult(rows: [], summaryLabel: match?.label)
        }
        let rows = (try? transcript.range(threadId: threadId, fromTurn: tr[0], toTurn: tr[1])) ?? []
        return ExpandResult(rows: rows, summaryLabel: node.label)
    }
}
