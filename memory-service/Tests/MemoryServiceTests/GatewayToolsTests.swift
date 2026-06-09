import XCTest
@testable import MemoryService
@testable import MemoryCore

final class GatewayToolsTests: XCTestCase {

    /// Build a lightweight in-memory Services (mirrors MemoryEndpointsTests.makeAppWithServices).
    @MainActor
    private func services() throws -> Services {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        return Services(store: store, transcript: ts, embedder: FakeEmbedder(dimension: 8),
                        bearerToken: "test-token")
    }

    // MARK: - CurrentTimeGatewayTool

    func test_currentTime_tool_returns_a_time() async throws {
        let s = try await MainActor.run { try services() }
        let out = await CurrentTimeGatewayTool().run(argsJSON: "{}", services: s)
        // DateFormatter with dateStyle:.medium, timeStyle:.short always contains a digit
        XCTAssertFalse(out.isEmpty)
        // Contains a colon (time portion) or at minimum digits
        XCTAssertTrue(out.contains(":") || out.contains(","), "Expected time string, got: \(out)")
    }

    // MARK: - SaveMemoryGatewayTool

    func test_save_memory_tool_stores_fact() async throws {
        let s = try await MainActor.run { try services() }
        let out = await SaveMemoryGatewayTool().run(
            argsJSON: #"{"entity":"sushi","detail":"likes it a lot","kind":"preference"}"#,
            services: s
        )
        XCTAssertTrue(out.contains("sushi"), "Expected confirmation, got: \(out)")
        let nodes = try s.store.allNodes()
        XCTAssertTrue(nodes.contains { $0.label == "sushi" })
    }

    func test_save_memory_self_routes_to_singleton() async throws {
        let s = try await MainActor.run { try services() }
        let out = await SaveMemoryGatewayTool().run(
            argsJSON: #"{"entity":"Roilan","kind":"self"}"#,
            services: s
        )
        XCTAssertTrue(out.contains("Roilan"), "Expected confirmation, got: \(out)")
        let selfNode = try s.store.selfNode()
        XCTAssertNotNil(selfNode)
        XCTAssertEqual(selfNode?.kind, NodeKind.selfUser.rawValue)
    }

    // MARK: - ForgetGatewayTool

    func test_forget_tool_removes_matching_node() async throws {
        let s = try await MainActor.run { try services() }
        // Seed a node
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "coffee", body: "likes coffee",
                     layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3,
                     decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                     sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try s.store.upsert(n)
        let out = await ForgetGatewayTool().run(argsJSON: #"{"query":"coffee"}"#, services: s)
        XCTAssertTrue(out.contains("Forgot"), "Expected confirmation, got: \(out)")
        let live = try s.store.allNodes()
        XCTAssertFalse(live.contains { $0.label == "coffee" })
    }

    func test_forget_tool_empty_query_returns_error() async throws {
        let s = try await MainActor.run { try services() }
        let out = await ForgetGatewayTool().run(argsJSON: #"{"query":""}"#, services: s)
        XCTAssertEqual(out, "nothing to forget")
    }

    // MARK: - LoadMessagesGatewayTool

    func test_loadMessages_returns_rows() async throws {
        let s = try await MainActor.run { try services() }
        _ = try s.transcript.append(threadId: "chat1", turnIndex: 0, role: "user", text: "hello world")
        _ = try s.transcript.append(threadId: "chat1", turnIndex: 1, role: "assistant", text: "hi there")
        let out = await LoadMessagesGatewayTool().run(
            argsJSON: #"{"chat_id":"chat1","from":1,"to":2}"#,
            services: s
        )
        XCTAssertTrue(out.contains("hello world"), "Expected transcript, got: \(out)")
        XCTAssertTrue(out.contains("hi there"), "Expected assistant reply, got: \(out)")
    }

    func test_loadMessages_missing_chatId_returns_error() async throws {
        let s = try await MainActor.run { try services() }
        let out = await LoadMessagesGatewayTool().run(argsJSON: #"{"from":1}"#, services: s)
        XCTAssertTrue(out.contains("need"), "Expected error, got: \(out)")
    }

    // MARK: - ListTopicsGatewayTool

    func test_listTopics_returns_tags() async throws {
        let s = try await MainActor.run { try services() }
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "trading", body: "trading",
                     layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3,
                     decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                     sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try s.store.upsert(n)
        try s.store.setTags(nodeId: "n1", ["finance"])
        let out = await ListTopicsGatewayTool().run(argsJSON: "{}", services: s)
        XCTAssertTrue(out.contains("finance"), "Expected topics, got: \(out)")
    }

    func test_listTopics_empty_returns_message() async throws {
        let s = try await MainActor.run { try services() }
        let out = await ListTopicsGatewayTool().run(argsJSON: "{}", services: s)
        XCTAssertEqual(out, "no topics yet")
    }

    // MARK: - RecallByTopicGatewayTool

    func test_recallByTopic_tool_enumerates() async throws {
        let s = try await MainActor.run { try services() }
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "calls", body: "calls",
                     layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3,
                     decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                     sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try s.store.upsert(n)
        try s.store.setTags(nodeId: "n1", ["trading"])
        let out = await RecallByTopicGatewayTool().run(argsJSON: #"{"topic":"trading"}"#, services: s)
        XCTAssertTrue(out.contains("calls"), "Expected node label, got: \(out)")
        XCTAssertTrue(out.hasPrefix("About trading:"), "Expected resolved-tag header (app parity), got: \(out)")
    }

    func test_recallByTopic_empty_topic_returns_error() async throws {
        let s = try await MainActor.run { try services() }
        let out = await RecallByTopicGatewayTool().run(argsJSON: #"{"topic":""}"#, services: s)
        XCTAssertEqual(out, "need a topic")
    }

    func test_recallByTopic_unknown_topic_returns_nothing() async throws {
        let s = try await MainActor.run { try services() }
        let out = await RecallByTopicGatewayTool().run(argsJSON: #"{"topic":"astrophysics"}"#, services: s)
        XCTAssertTrue(out.contains("nothing remembered"), "Expected no-data message, got: \(out)")
    }

    // MARK: - WhyGatewayTool

    func test_why_tool_traces_insight_to_sources() async throws {
        let s = try await MainActor.run { try services() }
        func mk(_ id: String, _ kind: String, _ label: String, _ body: String) throws {
            let n = Node(id: id, kind: kind, label: label, body: body, layer: .daily,
                         createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0,
                         confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                         origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
            try s.store.upsert(n)
        }
        try mk("ins", NodeKind.insight.rawValue, "trades options actively", "trades options actively")
        try mk("s1", NodeKind.preference.rawValue, "calls", "calls")
        try mk("s2", NodeKind.preference.rawValue, "puts", "puts")
        for srcId in ["s1", "s2"] {
            try s.store.upsert(Edge(id: UUID().uuidString, srcId: "ins", dstId: srcId,
                                   relation: .derivesFrom, weight: 1, confidence: .probable,
                                   createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
        }
        let out = await WhyGatewayTool().run(argsJSON: #"{"claim":"trades options"}"#, services: s)
        XCTAssertTrue(out.contains("trades options actively"), "Expected insight, got: \(out)")
        XCTAssertTrue(out.contains("calls") || out.contains("puts"), "Expected sources, got: \(out)")
    }

    func test_why_tool_empty_claim_returns_error() async throws {
        let s = try await MainActor.run { try services() }
        let out = await WhyGatewayTool().run(argsJSON: #"{"claim":""}"#, services: s)
        XCTAssertEqual(out, "need a claim")
    }

    // MARK: - CheckScheduleGatewayTool

    func test_checkSchedule_no_events_returns_no_conflicts() async throws {
        let s = try await MainActor.run { try services() }
        let out = await CheckScheduleGatewayTool().run(
            argsJSON: #"{"start":"2099-01-01T09:00","end":"2099-01-01T10:00"}"#,
            services: s
        )
        XCTAssertEqual(out, "No conflicts.")
    }

    func test_checkSchedule_missing_params_returns_error() async throws {
        let s = try await MainActor.run { try services() }
        let out = await CheckScheduleGatewayTool().run(argsJSON: #"{"start":"2099-01-01T09:00"}"#, services: s)
        XCTAssertTrue(out.contains("need"), "Expected error, got: \(out)")
    }

    func test_checkSchedule_detects_existing_event() async throws {
        let s = try await MainActor.run { try services() }
        _ = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"standup","start":"2099-02-01T09:00","end":"2099-02-01T10:00"}"#,
            services: s
        )
        let out = await CheckScheduleGatewayTool().run(
            argsJSON: #"{"start":"2099-02-01T09:30","end":"2099-02-01T10:30"}"#,
            services: s
        )
        XCTAssertTrue(out.hasPrefix("Conflicts:"), "Expected conflict, got: \(out)")
        XCTAssertTrue(out.contains("standup"), "Expected conflicting event named, got: \(out)")
    }

    // MARK: - CreateEventGatewayTool

    func test_createEvent_creates_successfully() async throws {
        let s = try await MainActor.run { try services() }
        let out = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"dentist","start":"2099-03-01T09:00","end":"2099-03-01T10:00"}"#,
            services: s
        )
        XCTAssertTrue(out.contains("Scheduled"), "Expected success, got: \(out)")
        let events = try s.store.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertTrue(events.contains { $0.label == "dentist" })
    }

    func test_createEvent_missing_params_returns_error() async throws {
        let s = try await MainActor.run { try services() }
        let out = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"dentist","start":"2099-03-01T09:00"}"#,
            services: s
        )
        XCTAssertTrue(out.contains("need"), "Expected error, got: \(out)")
    }

    func test_createEvent_conflict_blocked_without_force() async throws {
        let s = try await MainActor.run { try services() }
        let first = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"flight","start":"2099-04-01T08:00","end":"2099-04-01T12:00"}"#,
            services: s
        )
        XCTAssertTrue(first.contains("Scheduled"), "Setup event should schedule, got: \(first)")
        // Overlapping event, no force → must be refused, and the original must remain the only event.
        let out = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"lunch","start":"2099-04-01T10:00","end":"2099-04-01T11:00"}"#,
            services: s
        )
        XCTAssertTrue(out.contains("NOT scheduled"), "Expected conflict refusal, got: \(out)")
        XCTAssertTrue(out.contains("flight"), "Expected the conflicting event named, got: \(out)")
        let events = try s.store.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertFalse(events.contains { $0.label == "lunch" }, "Conflicting event must not be persisted")
    }

    func test_createEvent_force_books_despite_conflict() async throws {
        let s = try await MainActor.run { try services() }
        _ = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"flight","start":"2099-05-01T08:00","end":"2099-05-01T12:00"}"#,
            services: s
        )
        let out = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"lunch","start":"2099-05-01T10:00","end":"2099-05-01T11:00","force":true}"#,
            services: s
        )
        XCTAssertTrue(out.contains("Scheduled"), "force=true should book despite conflict, got: \(out)")
        let events = try s.store.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertTrue(events.contains { $0.label == "lunch" }, "Forced event must be persisted")
    }

    // MARK: - QueryScheduleGatewayTool

    func test_querySchedule_returns_events() async throws {
        let s = try await MainActor.run { try services() }
        // Create an event first
        _ = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"meeting","start":"2099-06-01T10:00","end":"2099-06-01T11:00"}"#,
            services: s
        )
        let out = await QueryScheduleGatewayTool().run(
            argsJSON: #"{"from":"2099-06-01","to":"2099-06-02"}"#,
            services: s
        )
        XCTAssertTrue(out.contains("meeting"), "Expected event, got: \(out)")
    }

    func test_querySchedule_empty_range_returns_nothing() async throws {
        let s = try await MainActor.run { try services() }
        let out = await QueryScheduleGatewayTool().run(
            argsJSON: #"{"from":"2099-01-01","to":"2099-01-02"}"#,
            services: s
        )
        XCTAssertEqual(out, "Nothing scheduled in that range.")
    }

    // MARK: - CancelEventsGatewayTool

    func test_cancelEvents_cancels_in_range() async throws {
        let s = try await MainActor.run { try services() }
        _ = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"yoga","start":"2099-07-01T08:00","end":"2099-07-01T09:00"}"#,
            services: s
        )
        let out = await CancelEventsGatewayTool().run(
            argsJSON: #"{"from":"2099-07-01","to":"2099-07-02"}"#,
            services: s
        )
        XCTAssertTrue(out.contains("Cancelled"), "Expected cancellation, got: \(out)")
        XCTAssertTrue(out.contains("1"), "Expected 1 event cancelled, got: \(out)")
    }

    // MARK: - functionSpec shape

    func test_functionSpec_shape() {
        let spec = RecallByTopicGatewayTool.functionSpec
        XCTAssertEqual((spec["type"] as? String), "function")
        let fn = spec["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "recall_by_topic")
        let params = fn?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
    }

    func test_all_tools_have_unique_names() {
        let names = GatewayToolRegistry.gatewayTools.map { type(of: $0).name }
        XCTAssertEqual(names.count, Set(names).count, "Duplicate tool names: \(names)")
    }

    func test_registry_has_12_tools() {
        XCTAssertEqual(GatewayToolRegistry.gatewayTools.count, 12)
        XCTAssertEqual(GatewayToolRegistry.gatewayToolSpecs.count, 12)
    }

    func test_gatewayToolSpecs_are_valid_function_specs() {
        for spec in GatewayToolRegistry.gatewayToolSpecs {
            XCTAssertEqual(spec["type"] as? String, "function", "spec missing type=function: \(spec)")
            let fn = spec["function"] as? [String: Any]
            XCTAssertNotNil(fn?["name"])
            XCTAssertNotNil(fn?["description"])
        }
    }

    // MARK: - UpdateEventGatewayTool

    private func seedEvent(_ s: Services, title: String, start: String, end: String) async {
        _ = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"\#(title)","start":"\#(start)","end":"\#(end)"}"#, services: s)
    }

    func test_updateEvent_location_only_applies_without_conflict_check() async throws {
        let s = try await MainActor.run { try services() }
        await seedEvent(s, title: "meeting", start: "2099-06-09T15:00", end: "2099-06-09T16:00")
        let out = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","location":"Miami"}"#, services: s)
        XCTAssertTrue(out.contains("Updated"), "Expected echo, got: \(out)")
        XCTAssertTrue(out.contains("Miami"), "Expected new location, got: \(out)")
        let ev = try s.store.allNodes().first { $0.kind == NodeKind.event.rawValue }!
        XCTAssertEqual(NodeAttributes.from(ev.extra).location, "Miami")
    }

    func test_updateEvent_not_found_never_creates() async throws {
        let s = try await MainActor.run { try services() }
        let out = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"ghost","location":"Miami"}"#, services: s)
        XCTAssertTrue(out.lowercased().contains("couldn't find"), "Expected not-found, got: \(out)")
        let events = try s.store.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertTrue(events.isEmpty, "Must not create anything on a missed match")
    }

    func test_updateEvent_time_move_conflict_blocked_then_forced() async throws {
        let s = try await MainActor.run { try services() }
        await seedEvent(s, title: "meeting", start: "2099-06-09T15:00", end: "2099-06-09T16:00")
        await seedEvent(s, title: "dentist", start: "2099-06-09T11:00", end: "2099-06-09T12:00")
        // Move "meeting" onto the dentist slot → blocked.
        let blocked = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newStart":"2099-06-09T11:00","newEnd":"2099-06-09T12:00"}"#,
            services: s)
        XCTAssertTrue(blocked.contains("NOT changed"), "Expected conflict refusal, got: \(blocked)")
        XCTAssertTrue(blocked.contains("dentist"), "Expected the conflicting event named, got: \(blocked)")
        // With force → applied.
        let forced = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newStart":"2099-06-09T11:00","newEnd":"2099-06-09T12:00","force":true}"#,
            services: s)
        XCTAssertTrue(forced.contains("Updated"), "force should apply, got: \(forced)")
    }

    func test_updateEvent_time_move_no_conflict_excludes_self() async throws {
        let s = try await MainActor.run { try services() }
        await seedEvent(s, title: "meeting", start: "2099-06-09T15:00", end: "2099-06-09T16:00")
        // Shorten within its own old slot — must NOT conflict with itself.
        let out = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newEnd":"2099-06-09T15:30"}"#, services: s)
        XCTAssertTrue(out.contains("Updated"), "self-overlap must not block, got: \(out)")
    }
}
