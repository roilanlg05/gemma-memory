import BrainContract
import Crypto
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import MemoryCore
import MemoryService
import NIOCore

enum EvaluationPartition: String, Codable, CodingKeyRepresentable, CaseIterable {
    case tuning, heldOut
}

struct EvaluationCorpusManifest: Codable, Sendable {
    let schemaVersion: Int
    let corpusVersion: String
    let sha256: String
    let caseCount: Int
    let tuningTemplates: [String]
    let heldOutTemplates: [String]

    func partition(for caseID: String) -> EvaluationPartition {
        heldOutTemplates.contains(Self.template(caseID)) ? .heldOut : .tuning
    }

    static func template(_ caseID: String) -> String {
        caseID.split(separator: "-").dropLast().joined(separator: "-")
    }

    static func load() throws -> (Self, [BrainEvaluationCase]) {
        guard let manifestURL = Bundle.module.url(forResource: "brain-scenarios-manifest", withExtension: "json",
                                                   subdirectory: "Fixtures"),
              let corpusURL = Bundle.module.url(forResource: "brain-scenarios", withExtension: "json",
                                                subdirectory: "Fixtures") else {
            throw EvaluationRunError.invalid("Missing bundled corpus or manifest")
        }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Self.self, from: Data(contentsOf: manifestURL))
        let data = try Data(contentsOf: corpusURL)
        guard manifest.schemaVersion == 1, !manifest.corpusVersion.isEmpty, manifest.sha256 == digest(data) else {
            throw EvaluationRunError.invalid("Unsupported or mismatched corpus manifest")
        }
        let fixtures = try decoder.decode([BrainEvaluationCase].self, from: data)
        let templates = Dictionary(grouping: fixtures) { template($0.id) }
        let tuning = Set(manifest.tuningTemplates)
        let heldOut = Set(manifest.heldOutTemplates)
        guard !fixtures.isEmpty, manifest.caseCount == fixtures.count,
              !tuning.isEmpty, !heldOut.isEmpty, tuning.count == manifest.tuningTemplates.count,
              heldOut.count == manifest.heldOutTemplates.count, tuning.isDisjoint(with: heldOut),
              tuning.union(heldOut) == Set(templates.keys) else {
            throw EvaluationRunError.invalid("Incomplete or overlapping template partitions")
        }
        _ = try BrainEvaluation.score(cases: fixtures, predictions: [])
        return (manifest, fixtures)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum EvaluationRetrievalMode: String, Codable, CodingKeyRepresentable, CaseIterable {
    case direct, hybrid, vectorOnly
}

enum EvaluationRunError: Error {
    case invalid(String)
    case route(caseID: String, path: String, status: Int)
    case generationUnavailable
}

struct EvaluationLatency: Codable {
    let samples: Int
    let median: Double?
    let p95: Double?

    init(_ values: [Double]) {
        let sorted = values.sorted()
        samples = sorted.count
        median = sorted.isEmpty ? nil : sorted[Int(ceil(Double(samples) * 0.5)) - 1]
        p95 = sorted.isEmpty ? nil : sorted[Int(ceil(Double(samples) * 0.95)) - 1]
    }
}

struct EvaluationSourceSample: Codable, Sendable {
    let deliveredIDs: [String]
    let latencyMilliseconds: Double
    let withdrawnTextIDs: [String]

    static func sourceIDs(_ identifiers: [String], known: [String: String]) -> [String] {
        Set(identifiers.map { known[$0] ?? "unmapped-source:\($0)" }).sorted()
    }

    static func withdrawnSourcesExposed(in bundle: BrainContextBundle, evidenceID: String, original: String) -> Bool {
        let identifiers = Set((bundle.sourceUses ?? [:]).keys)
            .union(bundle.sourceReferences.flatMap { [$0.id] + ($0.parentEvidenceIDs ?? []) })
            .union(bundle.recentMessageUnits.flatMap { [$0.id] + $0.evidenceIDs })
            .union((bundle.truncations ?? []).compactMap(\.evidenceID))
        let contents = [bundle.renderedContext] + bundle.recentMessageUnits.map(\.text)
            + bundle.sourceReferences.compactMap(\.text)
        return identifiers.contains(evidenceID) || contents.contains { text in
            text.contains(evidenceID) || (!original.isEmpty && text.contains(original))
        }
    }
}

struct EvaluationSourceMetrics: Codable {
    let observedCases: Int
    let deliveredSources: Int
    let expectedSources: Int
    let matchedSources: Int
    let withdrawnSources: Int
    let withdrawnSourcesExposed: Int
    let precision: Double?
    let recall: Double?
    let latencyMilliseconds: EvaluationLatency

    init(_ pairs: [(BrainEvaluationCase, EvaluationSourceSample)]) {
        observedCases = pairs.count
        deliveredSources = pairs.reduce(0) { $0 + $1.1.deliveredIDs.count }
        expectedSources = pairs.reduce(0) { $0 + $1.0.expectedEvidenceIDs.count }
        matchedSources = pairs.reduce(0) { $0 + Set($1.1.deliveredIDs).intersection($1.0.expectedEvidenceIDs).count }
        withdrawnSources = pairs.reduce(0) { $0 + $1.0.messages.filter { $0.state == "withdrawn" }.count }
        withdrawnSourcesExposed = pairs.reduce(0) { sum, pair in
            let withdrawn = Set(pair.0.messages.filter { $0.state == "withdrawn" }.map(\.id))
            return sum + Set(pair.1.deliveredIDs + pair.1.withdrawnTextIDs).intersection(withdrawn).count
        }
        precision = deliveredSources == 0 ? nil : Double(matchedSources) / Double(deliveredSources)
        recall = expectedSources == 0 ? nil : Double(matchedSources) / Double(expectedSources)
        latencyMilliseconds = .init(pairs.map { $0.1.latencyMilliseconds })
    }
}

struct EvaluationAssertionMetrics: Codable {
    let counts: BrainEvaluationCounts
    let coverage: Double?
    let exactAssertionAccuracy: Double?
    let overallExactAssertionAccuracy: Double?

    init(_ score: BrainEvaluationReport) {
        counts = score.counts
        coverage = score.coverage
        exactAssertionAccuracy = score.exactAssertionAccuracy
        overallExactAssertionAccuracy = score.overallExactAssertionAccuracy
    }
}

struct EvaluationCategoryMetrics: Codable {
    let assertions: EvaluationAssertionMetrics
    let context: EvaluationSourceMetrics
    let retrieval: [EvaluationRetrievalMode: EvaluationSourceMetrics]
}

private struct EvaluationCaseInput: Sendable {
    let id: String
    let language: String
    let messages: [BrainEvaluationMessage]
    let query: String

    init(_ fixture: BrainEvaluationCase) {
        id = fixture.id
        language = fixture.language
        messages = fixture.messages
        query = fixture.query
    }

    var canReplay: Bool { messages.allSatisfy { ["user", "assistant"].contains($0.role) } }

    var requestsOriginalQuote: Bool {
        switch language {
        case "en": query.lowercased().hasPrefix("quote my original ")
        case "es": query.lowercased().hasPrefix("cita exactamente mi ")
        default: false
        }
    }
}

private struct EvaluationObservation: Sendable {
    let prediction: BrainEvaluationPrediction
    let context: EvaluationSourceSample?
    let retrieval: [EvaluationRetrievalMode: EvaluationSourceSample]
    let restartReplayStable: Bool?
    let erasedSources: [String]
}

struct EvaluationCaseResult: Codable {
    let id: String
    let category: String
    let partition: EvaluationPartition
    let assertionResult: BrainEvaluationResult
    let context: EvaluationSourceSample?
    let retrieval: [EvaluationRetrievalMode: EvaluationSourceSample]
    let restartReplayStable: Bool?
    let erasedSources: [String]
}

struct BrainLongitudinalEvaluation: Encodable {
    let schemaVersion = 1
    let corpus: EvaluationCorpusManifest
    let software: [String: String]
    let configuration: [String: String]
    let assertions: EvaluationAssertionMetrics
    let partitions: [EvaluationPartition: EvaluationAssertionMetrics]
    let byCategory: [String: EvaluationCategoryMetrics]
    let context: EvaluationSourceMetrics
    let retrieval: [EvaluationRetrievalMode: EvaluationSourceMetrics]
    let cases: [EvaluationCaseResult]
    let unmeasured: [String: String]

    static func run() async throws -> Self {
        let (manifest, fixtures) = try EvaluationCorpusManifest.load()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-evaluation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = EvaluationRouteAdapter()
        var observations: [String: EvaluationObservation] = [:]
        for (index, fixture) in fixtures.enumerated() {
            let database = root.appendingPathComponent("\(index).sqlite")
            observations[fixture.id] = try await adapter.run(EvaluationCaseInput(fixture), database: database)
        }
        guard observations.values.contains(where: { $0.context != nil }) else {
            throw EvaluationRunError.invalid("No actual context observations")
        }

        func metrics(for subset: [BrainEvaluationCase]) throws -> (EvaluationCategoryMetrics, [BrainEvaluationResult]) {
            let predictions = subset.compactMap { observations[$0.id]?.prediction }
            let score = try BrainEvaluation.score(cases: subset, predictions: predictions)
            let context = subset.compactMap { fixture in observations[fixture.id]?.context.map { (fixture, $0) } }
            let retrieval = Dictionary(uniqueKeysWithValues: EvaluationRetrievalMode.allCases.map { mode in
                let pairs = subset.compactMap { fixture in observations[fixture.id]?.retrieval[mode].map { (fixture, $0) } }
                return (mode, EvaluationSourceMetrics(pairs))
            })
            return (.init(assertions: .init(score), context: .init(context), retrieval: retrieval), score.results)
        }

        let (overall, results) = try metrics(for: fixtures)
        let caseResults = try zip(fixtures, results).map { fixture, result in
            guard let observation = observations[fixture.id] else { throw EvaluationRunError.invalid("Missing observation") }
            return EvaluationCaseResult(id: fixture.id, category: fixture.category, partition: manifest.partition(for: fixture.id),
                assertionResult: result, context: observation.context, retrieval: observation.retrieval,
                restartReplayStable: observation.restartReplayStable, erasedSources: observation.erasedSources)
        }
        let partitions = try Dictionary(uniqueKeysWithValues: EvaluationPartition.allCases.map { partition in
            let subset = fixtures.filter { manifest.partition(for: $0.id) == partition }
            return (partition, try metrics(for: subset).0.assertions)
        })
        let byCategory = try Dictionary(grouping: fixtures, by: \.category).mapValues { try metrics(for: $0).0 }
        let environment = ProcessInfo.processInfo.environment
        let sqliteVersion = try await MemoryStore(inMemory: true, embeddingDim: adapter.embedder.dimension).dbQueue.read {
            try String.fetchOne($0, sql: "SELECT sqlite_version()") ?? "unavailable"
        }
        var software = ["operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "sqlite": sqliteVersion]
        software["backendRevision"] = environment["BRAIN_EVALUATION_BACKEND_REVISION"]
        software["swift"] = environment["BRAIN_EVALUATION_SWIFT_VERSION"]
        return .init(corpus: manifest, software: software,
            configuration: ["provider": "offline-noop-text-and-denied-agent-generation",
                            "embedding": "FakeEmbedder/\(adapter.embedder.dimension)",
                            "database": "isolated-on-disk-sqlite-per-case",
                            "transport": "Hummingbird .router",
                            "topK": String(adapter.topK),
                            "contextTokens": String(adapter.contextTokens),
                            "outputTokens": String(adapter.outputTokens)],
            assertions: overall.assertions, partitions: partitions, byCategory: byCategory, context: overall.context,
            retrieval: overall.retrieval, cases: caseResults,
            unmeasured: [
                "realProviderAdherence": "No configured real generation provider was exercised.",
                "realEmbeddingQuality": "Vector comparisons use deterministic fixture embeddings.",
                "humanConversationalQuality": "Human naturalness and preference review were not performed.",
                "devicePerformance": "Hardware and native provider latency were not measured.",
                "toolAndSystemFixtureReplay": "Tool/system fixture text is synthetic annotation context and did not trigger operations.",
                "generalSemanticAccuracy": "Exact assertions measure only verbatim delivery for explicit single-source quote requests."
            ])
    }
}

private struct EvaluationRouteAdapter {
    private struct TranscriptAppend: Encodable {
        let threadId: String
        let role: String
        let text: String
        let turnIndex: Int
    }

    private struct HistoricalSource: Sendable {
        let message: BrainEvaluationMessage
        let transcriptID: String
        let evidenceID: String
    }

    private struct PreparedReplay: Sendable {
        let sources: [HistoricalSource]
        let firstUserRequest: BrainTurnRequest?
        let firstUserReceipt: BrainTurnResult?
    }

    private struct UnavailableAgent: AgentModelClient {
        func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
            throw EvaluationRunError.generationUnavailable
        }
    }

    private static let auth: HTTPFields = [.authorization: "Bearer synthetic-evaluation", .contentType: "application/json"]
    let embedder = FakeEmbedder(dimension: 16)
    let topK = 4
    let contextTokens = 5500
    let outputTokens = 128

    func run(_ input: EvaluationCaseInput, database: URL) async throws -> EvaluationObservation {
        guard input.canReplay else {
            return .init(prediction: unsupported(input, "Tool or system text is not a replayable operational event."),
                         context: nil, retrieval: [:], restartReplayStable: nil, erasedSources: [])
        }
        let budget = try BrainContextBudget(contextTokens: contextTokens, outputTokens: outputTokens)
        let prepared = try await prepare(input, database: database, budget: budget)
        let (store, transcript, app) = try await open(database: database)
        return try await app.test(.router) { client in
            var stable = try transcript.range(threadId: input.id, from: 1, to: 80).map(\.id) == prepared.sources.map(\.transcriptID)
            if let request = prepared.firstUserRequest, let original = prepared.firstUserReceipt {
                let replay = try await post("/v1/brain/turns/begin", request, caseID: input.id, client: client, as: BrainTurnResult.self)
                let rows = try transcript.range(threadId: input.id, from: 1, to: 80)
                stable = stable && replay.turnID == original.turnID && replay.completion.evidenceIDs == original.completion.evidenceIDs
                    && rows.map(\.id) == prepared.sources.map(\.transcriptID)
            }

            let withdrawn = prepared.sources.filter { $0.message.state == "withdrawn" }
            var erased: [String] = []
            let owner = ConsolidationEvidenceAdapter.ownerID
            let brain = BrainStore(store: store, authorization: .init(principal: owner, owner: owner,
                subjects: [BrainIdentity.userID], scopes: [.user], threads: [input.id], sourceSpeakers: [:]))
            for source in withdrawn {
                let forget = BrainForgetRequest(clientOperationID: "forget-\(source.message.id)", expectedRevision: try brain.revision(),
                    scope: .init(kind: .evidence, id: source.evidenceID), threadID: input.id)
                let receipt = try await post("/v1/brain/forget", forget, caseID: input.id, client: client, as: BrainForgetReceipt.self)
                if receipt.state == .committed && receipt.forgottenEvidenceIDs.contains(source.evidenceID) {
                    erased.append(source.message.id)
                }
            }

            let liveUserSources = prepared.sources.filter { $0.message.role == "user" && $0.message.state == "active" }
            let requestedQuotes = input.requestsOriginalQuote && liveUserSources.count == 1
                ? liveUserSources.map(\.evidenceID) : []
            let request = try BrainContextRequest(clientOperationID: "query", threadID: input.id, query: input.query,
                                                  budget: budget, quoteEvidenceIDs: requestedQuotes, detailEvidenceIDs: [])
            let clock = ContinuousClock()
            let start = clock.now
            let bundle = try await post("/v1/brain/context", request, caseID: input.id, client: client, as: BrainContextBundle.self)
            let routeLatency = Self.milliseconds(start.duration(to: clock.now))
            let identities = Dictionary(uniqueKeysWithValues: prepared.sources.map { ($0.evidenceID, $0.message.id) })
            let deliveredIDs = EvaluationSourceSample.sourceIDs(Array((bundle.sourceUses ?? [:]).keys), known: identities)
            let exposedText = withdrawn.filter { source in
                EvaluationSourceSample.withdrawnSourcesExposed(in: bundle, evidenceID: source.evidenceID,
                                                                original: source.message.text)
            }.map { $0.message.id }
            let context = EvaluationSourceSample(deliveredIDs: deliveredIDs, latencyMilliseconds: routeLatency,
                                                 withdrawnTextIDs: exposedText)
            let prediction = requestedQuotes.isEmpty
                ? unsupported(input, "Offline route delivered context. Structured semantic answer generation was unavailable.")
                : exactQuote(input, bundle: bundle, identities: identities)
            let retrieval = try retrieve(input, store: store, identities: identities)
            return .init(prediction: prediction, context: context, retrieval: retrieval, restartReplayStable: stable, erasedSources: erased)
        }
    }

    private func prepare(_ input: EvaluationCaseInput, database: URL, budget: BrainContextBudget) async throws -> PreparedReplay {
        let (store, transcript, app) = try await open(database: database)
        return try await app.test(.router) { client in
            var firstRequest: BrainTurnRequest?
            var firstReceipt: BrainTurnResult?
            for (index, message) in input.messages.enumerated() {
                if message.role == "user" {
                    let request = try BrainTurnRequest(clientOperationID: "capture-\(message.id)", threadID: input.id,
                        message: .init(id: message.id, speakerID: BrainIdentity.userID, text: message.text,
                                       observedAt: Double(index + 1), evidenceIDs: []), budget: budget)
                    let receipt = try await post("/v1/brain/turns/begin", request, caseID: input.id, client: client, as: BrainTurnResult.self)
                    if firstRequest == nil {
                        firstRequest = request
                        firstReceipt = receipt
                    }
                } else {
                    let body = TranscriptAppend(threadId: input.id, role: message.role, text: message.text, turnIndex: index + 1)
                    _ = try await post("/v1/transcript/append", body, caseID: input.id, client: client, as: [String: String].self)
                }
            }
            let rows = try transcript.range(threadId: input.id, from: 1, to: 80)
            guard rows.count == input.messages.count else { throw EvaluationRunError.invalid("Unexpected replay row count for \(input.id)") }
            let sources = try zip(rows, input.messages).map { row, message in
                guard row.role == message.role, row.text == message.text else {
                    throw EvaluationRunError.invalid("Unexpected replay row for \(input.id)")
                }
                let evidenceID = ConsolidationEvidenceAdapter.evidenceID(for: row)
                // Each retrieval lane gets the same unannotated source corpus and tombstones.
                let node = Node(id: row.id, kind: "fact", label: row.text, body: row.text, layer: .daily,
                    createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 5, decayRate: 0,
                    confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: evidenceID,
                    origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
                try store.upsert(node)
                try store.setEmbedding(nodeId: node.id, embedder.embed(row.text))
                return HistoricalSource(message: message, transcriptID: row.id, evidenceID: evidenceID)
            }
            return .init(sources: sources, firstUserRequest: firstRequest, firstUserReceipt: firstReceipt)
        }
    }

    private func open(database: URL) async throws -> (MemoryStore, TranscriptStore, some ApplicationProtocol) {
        let store = try MemoryStore(url: database, embeddingDim: embedder.dimension)
        let transcript = TranscriptStore(dbQueue: store.dbQueue)
        let services = await Services(store: store, transcript: transcript, embedder: embedder, bearerToken: "synthetic-evaluation",
                                      modelClient: DefaultNoOpModelClient(), agentClient: UnavailableAgent())
        return (store, transcript, try await buildApp(services: services, port: 0))
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String, _ body: Body, caseID: String, client: any TestClientProtocol, as responseType: Response.Type
    ) async throws -> Response {
        let response = try await client.execute(uri: path, method: .post, headers: Self.auth,
            body: ByteBuffer(bytes: try JSONEncoder().encode(body)))
        guard response.status == .ok else { throw EvaluationRunError.route(caseID: caseID, path: path, status: response.status.code) }
        return try JSONDecoder().decode(responseType, from: Data(response.body.readableBytesView))
    }

    private func retrieve(_ input: EvaluationCaseInput, store: MemoryStore, identities: [String: String])
        throws -> [EvaluationRetrievalMode: EvaluationSourceSample] {
        let clock = ContinuousClock()
        let retriever = MemoryRetriever(store: store, embedder: embedder)
        var output: [EvaluationRetrievalMode: EvaluationSourceSample] = [:]
        for mode in EvaluationRetrievalMode.allCases {
            let start = clock.now
            let nodes: [Node]
            switch mode {
            case .direct:
                nodes = try store.searchFTS(query: input.query, limit: topK)
            case .hybrid:
                nodes = try retriever.retrieve(query: input.query, k: topK, now: 1)
            case .vectorOnly:
                nodes = try store.nearest(to: embedder.embed(input.query), k: topK).compactMap { try store.node(id: $0.id) }
            }
            let identifiers = nodes.map { $0.sourceRef ?? "unattributed-node:\($0.id)" }
            let exposed = input.messages.filter { source in
                source.state == "withdrawn" && !source.text.isEmpty && nodes.contains {
                    $0.label.contains(source.text) || $0.body.contains(source.text)
                }
            }.map(\.id)
            output[mode] = .init(deliveredIDs: EvaluationSourceSample.sourceIDs(identifiers, known: identities),
                                 latencyMilliseconds: Self.milliseconds(start.duration(to: clock.now)), withdrawnTextIDs: exposed)
        }
        return output
    }

    private func unsupported(_ input: EvaluationCaseInput, _ reason: String) -> BrainEvaluationPrediction {
        .init(caseID: input.id, unsupportedReason: reason, evidenceIDs: [], assertions: [])
    }

    private func exactQuote(_ input: EvaluationCaseInput, bundle: BrainContextBundle,
                            identities: [String: String]) -> BrainEvaluationPrediction {
        let assertions = bundle.sourceReferences.compactMap { reference -> BrainEvaluationAssertion? in
            guard reference.sourceKind == .userMessage,
                  bundle.sourceUses?[reference.id]?.contains(.renderedQuote) == true,
                  let rendered = bundle.renderedContext.range(of: "[original quote source=\(reference.id)]\n") else { return nil }
            let id = identities[reference.id] ?? "unmapped-source:\(reference.id)"
            let original = bundle.renderedContext[rendered.upperBound...].components(separatedBy: "\n[").first ?? ""
            guard !original.isEmpty else { return nil }
            return .init(subject: reference.speakerID, predicate: "exactQuote", value: original, state: "verbatim",
                         sourceRole: "user", sourceIDs: [id])
        }
        let quoted = (bundle.sourceUses ?? [:]).filter { $0.value.contains(.renderedQuote) }.map(\.key)
        return .init(caseID: input.id, evidenceIDs: EvaluationSourceSample.sourceIDs(quoted, known: identities),
                     assertions: assertions)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
