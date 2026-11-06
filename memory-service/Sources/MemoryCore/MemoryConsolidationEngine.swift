import Foundation
import BrainContract

/// Brain-like consolidation operations over the memory graph, driven by the local model.
///
/// Phases are independent units (testable with a fake runtime). Each one reports what it actually
/// did as a `ConsolidationPhaseResult`: content it committed, writes the store lawfully refused, or
/// a typed failure carrying the stage that broke and whether retrying could help. The resumable
/// cycle driver (`runCycle`) and the awake-light path (`runLight`) compose these phases.
///
/// The honesty rule of the cycle: a transcript turn is marked consolidated only when the phases
/// that actually read it succeeded, and that marking happens in the same transaction that retires
/// the cycle. A generation that failed, output that could not be parsed or a write that threw can
/// no longer cause the content to be dropped without a trace.
public final class MemoryConsolidationEngine: ConsolidationRunning, @unchecked Sendable {
    private let store: MemoryStore
    private let embedder: Embedder?
    private let runtime: any ModelTextClient
    private let transcriptStore: TranscriptStore
    private let now: () -> Double
    /// Timezone for the in-flight cycle. A resumed cycle uses the zone stored with its job, not
    /// the zone of whoever happened to restart it. Cycles are serialized by the scheduler, so a
    /// single instance var is safe. Defaults to server tz for direct phase tests.
    private var currentTimeZone: TimeZone = .current
    /// When the material under consolidation was spoken. Relative dates ("tomorrow") resolve from
    /// here, never from the wall clock of a cycle that may run hours or days later. Nil only when
    /// a caller supplied bare texts with no transcript rows behind them.
    private var currentAnchor: Double?
    /// The job the current cycle is working, when there is one. Phase and item receipts hang off it.
    private var currentJob: ConsolidationJob?
    public var onProgress: ((String) -> Void)?   // e.g. "+2 entities", "+1 edge"

    public init(store: MemoryStore, embedder: Embedder?, runtime: any ModelTextClient,
                transcriptStore: TranscriptStore? = nil,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store; self.embedder = embedder; self.runtime = runtime
        self.transcriptStore = transcriptStore ?? TranscriptStore(dbQueue: store.dbQueue); self.now = now
    }

    // MARK: shared — generation and parsing report why they failed

    /// Run one plain-text generation. A transport error or an empty reply is a typed failure of
    /// the calling phase, not an empty success.
    ///
    /// All consolidation phases run thinking-OFF (the runtime's default): verified against the
    /// real 26B, this model over-reasons and truncates the JSON (often to empty — 0 entities)
    /// when thinking is on, and is ~3.5-5x slower. Thinking-off is reliable and fast across every
    /// phase (consolidate/detect/associate/reflect/curate), and 512 tokens is enough for the
    /// JSON-only output we ask for (verified).
    private func generate(_ prompt: String, maxTokens: Int = 512) async -> Result<String, ConsolidationFailure> {
        do {
            let text = try await runtime.generate(prompt: prompt,
                                                  options: ModelTextOptions(maxTokens: maxTokens, temperature: 0.3))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.generation("empty_response"))
            }
            return .success(text)
        } catch {
            return .failure(.generation("model_unavailable"))
        }
    }

    /// Outermost {...} JSON object from noisy model output.
    static func extractJSON(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b])
    }

    private func parse<T: Decodable>(_ raw: String, _ type: T.Type) -> Result<T, ConsolidationFailure> {
        guard let j = Self.extractJSON(raw), let d = j.data(using: .utf8) else {
            return .failure(.parse("no_json_object"))
        }
        do { return .success(try JSONDecoder().decode(T.self, from: d)) }
        catch { return .failure(.parse("malformed_json")) }
    }

    /// One generation decoded into `T`, or the typed failure that stopped it.
    private func decoded<T: Decodable>(_ prompt: String, _ type: T.Type,
                                       maxTokens: Int = 512) async -> Result<T, ConsolidationFailure> {
        switch await generate(prompt, maxTokens: maxTokens) {
        case .failure(let failure): return .failure(failure)
        case .success(let raw): return parse(raw, type)
        }
    }

    // MARK: shared — persistence separates a refusal from a breakage

    private enum PersistProblem: Error {
        case refused(ConsolidationRefusal)
        case failed(ConsolidationFailure)
    }

    /// Run one persistence step and classify what came back.
    ///
    /// `BrainStoreError.denied` is the store doing its job: the content was retracted, or the node
    /// belongs to the claim store. That is a refusal — reported, never retried, and never a reason
    /// to re-consume the input. A subject conflict is likewise a correct refusal. Anything else is
    /// a real persistence failure and makes the whole phase fail.
    private func persist<T>(_ code: String, _ body: () throws -> T) -> Result<T, PersistProblem> {
        do { return .success(try body()) }
        catch BrainStoreError.denied { return .failure(.refused(.init(code: code + "_withheld"))) }
        catch is MemoryMergeError { return .failure(.refused(.init(code: code + "_subject_conflict"))) }
        catch { return .failure(.failed(.persist(code))) }
    }

    /// Accumulates one phase's outcome as it works.
    private struct PhaseTally {
        let phase: SleepPhase
        var committed = 0
        var refusals: [ConsolidationRefusal] = []
        var failure: ConsolidationFailure?

        init(_ phase: SleepPhase) { self.phase = phase }

        mutating func note(_ problem: PersistProblem) {
            switch problem {
            case .refused(let refusal): refusals.append(refusal)
            case .failed(let f): if failure == nil { failure = f }
            }
        }
        mutating func note(_ failure: ConsolidationFailure) {
            if self.failure == nil { self.failure = failure }
        }
        mutating func refuse(_ code: String) {
            refusals.append(.init(code: code))
        }
        mutating func absorb(_ other: ConsolidationPhaseResult) {
            committed += other.committed
            refusals += other.refusals
            if failure == nil { failure = other.failure }
        }
        var result: ConsolidationPhaseResult {
            if let failure { return .failed(phase, failure, committed: committed, refusals: refusals) }
            return committed > 0 ? .committed(phase, committed, refusals: refusals)
                                 : .empty(phase, refusals: refusals)
        }
    }

    // MARK: shared — per-item replay guards

    /// True when this job already committed this item in an earlier attempt. Outside a job (direct
    /// phase calls, light reflection) there is nothing to replay, so the item always runs.
    private func alreadyCommitted(_ phase: SleepPhase, item key: String) -> Bool {
        guard let job = currentJob else { return false }
        let operationID = job.operationID(for: phase, item: key)
        guard let receipt = (try? store.consolidationReceipt(jobID: job.id, operationID: operationID)) ?? nil
        else { return false }
        return receipt.succeeded
    }

    /// Record that this job committed this item, so a retry after a partial failure neither
    /// duplicates it nor reinforces it a second time.
    private func noteCommitted(_ phase: SleepPhase, item key: String) {
        guard let job = currentJob else { return }
        try? store.recordConsolidationReceipt(jobID: job.id, .committed(phase, 1),
                                              operationID: job.operationID(for: phase, item: key),
                                              at: now())
    }

    /// Machine-native consolidation phase order (SP-B): embed → cluster → tag → reflect/compress/
    /// curate (hygiene) → graph-linking LAST (on clean, clustered, deduped nodes) → clarify → forget.
    static let cycleOrder: [SleepPhase] = [
        .nrem, .summarize, .detect, .embeddings, .cluster, .tag,
        .reflect, .compress, .curate, .rem, .clarify, .shy,
    ]

    // MARK: NREM — Consolidate

    /// The date the material under consolidation was spoken, in the job's timezone. A cycle that
    /// runs at 3am must not date a user's "tomorrow" from 3am of the following day, so the anchor
    /// is the newest source turn, not the clock.
    private func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd (EEEE)"; f.timeZone = currentTimeZone
        return f.string(from: Date(timeIntervalSince1970: currentAnchor ?? now()))
    }

    private struct EntitiesOut: Decodable {
        struct E: Decodable { let entity: String; let kind: String?; let detail: String?; let permanent: Bool?
            struct Attr: Decodable { let status: String?; let horizon: String?; let date: String?
                let startTime: String?; let endTime: String?; let allDay: Bool?; let location: String? }
            let attributes: Attr? }
        let entities: [E]
    }

    /// Text-only entry point, kept for callers that have no transcript rows. Identity extraction
    /// cannot be substantiated without rows, so a `kind: self` proposal arriving this way is
    /// refused rather than written.
    public func consolidate(episodeTexts: [String]) async {
        _ = await consolidate(segment: ConsolidationSegment(threadID: "", texts: episodeTexts))
    }

    func consolidate(segment: ConsolidationSegment) async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.nrem)
        guard !segment.texts.isEmpty else { return tally.result }
        withAnchor(segment)
        let convo = segment.texts.joined(separator: "\n")
        let prompt = """
        Today is \(todayString()). Resolve any relative date (today/tomorrow/a weekday) to an absolute date and put it in attributes.date as "yyyy-MM-dd".
        Extract durable facts the USER stated about themselves from this conversation. Output JSON only.
        Use a short canonical `entity` (a noun/name, not a sentence). The "entity" MUST be a short canonical noun/name (1-3 words), NEVER a sentence (e.g. "Roilan", not "the user's name is Roilan"). Choose a `kind`: self (the USER's OWN name/identity — the person speaking; there is exactly ONE user, never a third party), person (OTHER people the user mentions — put their relationship role in `detail`, e.g. "esposa", "hija", "amigo", "jefe"), place, \
        preference, fact, trait (personality), task (something to do — set attributes.status "pending"), \
        plan (an intention — set attributes.horizon "short" or "long"), or another short lowercase kind if \
        none fit. Put context in `detail`. Never invent; only what the user actually stated.
        For appointments/meetings/trips (things with a time), put the LOCAL calendar date in attributes.date \
        ("yyyy-MM-dd"), the local start time in attributes.startTime ("HH:mm", 24-hour), and the end time in \
        attributes.endTime ("HH:mm"). If only a start is given, omit endTime (1 hour is assumed). Set \
        attributes.allDay true for all-day/multi-day events. NEVER output epoch numbers. If the event has a \
        place (venue, address, city), fill attributes.location with a short place name only (not prose).
        Schema: {"entities":[{"entity":"...","kind":"...","detail":"...","permanent":false,"attributes":{"status":"pending|done","horizon":"short|long","date":"yyyy-MM-dd","startTime":"HH:mm","endTime":"HH:mm","allDay":false,"location":"..."}}]}
        Conversation:
        \(convo)
        JSON:
        """
        let out: EntitiesOut
        switch await decoded(prompt, EntitiesOut.self, maxTokens: 512) {
        case .failure(let failure): tally.note(failure); return tally.result
        case .success(let value): out = value
        }
        for e in out.entities {
            // Structured event: a timed entity with a local date+time → first-class `event`, conflict-checked.
            if let date = e.attributes?.date, let startTime = e.attributes?.startTime,
               let st = ScheduleTime.epoch(date: date, time: startTime, tz: currentTimeZone) {
                let en = e.attributes?.endTime.flatMap { ScheduleTime.epoch(date: date, time: $0, tz: currentTimeZone) } ?? (st + 3600)
                let evLabel = MemoryText.canonicalEntityLabel(e.entity)
                if !MemoryText.isJunkLabel(evLabel), en > st {
                    let itemKey = "event|\(evLabel)|\(date)|\(startTime)"
                    if alreadyCommitted(.nrem, item: itemKey) { continue }
                    let allDay = e.attributes?.allDay ?? false
                    switch persist("event", {
                        try store.createEventChecked(title: evLabel, start: st, end: en, allDay: allDay,
                                                     location: e.attributes?.location, origin: .extracted, force: false)
                    }) {
                    case .failure(let problem): tally.note(problem)
                    case .success(let result):
                        if let evId = result.id {
                            if let emb = (try? embedder?.embed(evLabel)) ?? nil { try? store.setEmbedding(nodeId: evId, emb) }
                            tally.committed += 1
                            noteCommitted(.nrem, item: itemKey)
                        } else {
                            emitConflictClarification(title: evLabel, date: date, time: startTime, conflicts: result.conflicts)
                            noteCommitted(.nrem, item: itemKey)
                        }
                    }
                }
                continue
            }
            // The user's own identity → the singleton self node (never a generic person/fact), and
            // only when the user themselves asserted it in a turn we can point at.
            if e.kind == NodeKind.selfUser.rawValue {
                switch SelfAssertionValidator.validate(label: e.entity, sources: segment.rows,
                                                       permittedScopes: [.user], evidenceScope: .user) {
                case .failure(let rejection):
                    tally.refuse("self_" + rejection.rawValue)
                case .success(let support):
                    let selfLabel = MemoryText.canonicalEntityLabel(e.entity)
                    let itemKey = "self|\(selfLabel)|\(support.evidenceID)"
                    if alreadyCommitted(.nrem, item: itemKey) { continue }
                    switch persist("self", {
                        try store.upsertSelf(name: selfLabel, detail: e.detail, embedder: embedder,
                                             now: now(), sourceRef: support.evidenceID)
                    }) {
                    case .failure(let problem): tally.note(problem)
                    case .success: tally.committed += 1; noteCommitted(.nrem, item: itemKey)
                    }
                }
                continue
            }
            let rawKind = (e.kind?.isEmpty == false) ? e.kind! : NodeKind.fact.rawValue
            let entityKinds: Set<String> = [NodeKind.person.rawValue, NodeKind.place.rawValue,
                                            NodeKind.preference.rawValue, NodeKind.fact.rawValue]
            let label = entityKinds.contains(rawKind) ? MemoryText.canonicalEntityLabel(e.entity)
                                                      : MemoryText.cleanLabel(e.entity)
            if MemoryText.isJunkLabel(label) { continue }
            // Guard: never store temporal/relative date references as permanent fact nodes.
            // "today", "hoy", "tomorrow", "mañana", "ayer", "yesterday" are conversation context,
            // not durable facts. A bare date string ("5 August", "agosto 5") as a fact label is
            // also ephemeral. Dates belong in attributes.date on event/plan/task nodes only.
            let temporalLabels: Set<String> = [
                "today", "hoy", "tomorrow", "mañana", "manana", "yesterday", "ayer",
                "this week", "esta semana", "next week", "la proxima semana", "la próxima semana",
                "tonight", "esta noche", "now", "ahora"
            ]
            let labelLower = label.lowercased()
            if rawKind == NodeKind.fact.rawValue && temporalLabels.contains(labelLower) { continue }
            // Also discard fact nodes whose label is just a date (e.g. "5 August", "agosto 5", "2026-08-08")
            let datePattern = #"^\d{4}-\d{2}-\d{2}$|^\d{1,2}\s+\w+|^\w+\s+\d{1,2}$"#
            if rawKind == NodeKind.fact.rawValue,
               (try? NSRegularExpression(pattern: datePattern).firstMatch(in: labelLower, range: NSRange(labelLower.startIndex..., in: labelLower))) != nil { continue }
            let kind = rawKind
            let itemKey = "entity|\(kind)|\(MemoryText.dedupKey(label))|\(e.attributes?.date ?? "")"
            if alreadyCommitted(.nrem, item: itemKey) { continue }
            // A model's permanence flag is a proposal, not user authorization of identity.
            let layer: MemoryLayer = .daily
            var attrs = NodeAttributes(); attrs.status = e.attributes?.status; attrs.horizon = e.attributes?.horizon; attrs.date = e.attributes?.date
            let t = now()
            let baseBody = e.detail ?? label
            let body = (attrs.date != nil) ? baseBody + " (fecha: \(attrs.date!))" : baseBody
            let node = Node(id: UUID().uuidString, kind: kind, label: label, body: body, layer: layer,
                            createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                            dirty: true, deleted: false, extra: attrs.toJSON())
            let emb = (try? embedder?.embed(label)) ?? nil
            switch persist("entity", { try store.upsertMergingSemantic(node, embedding: emb, embedder: embedder) }) {
            case .failure(let problem): tally.note(problem)
            case .success(let savedId):
                if kind == NodeKind.person.rawValue, let selfNode = try? store.selfNode() {
                    let detailLower = (e.detail ?? "").lowercased()
                    let rel: Relation
                    if detailLower.contains("esposa") || detailLower.contains("hija") || detailLower.contains("hijo") || detailLower.contains("madre") || detailLower.contains("padre") || detailLower.contains("hermano") || detailLower.contains("hermana") || detailLower.contains("wife") || detailLower.contains("daughter") || detailLower.contains("son") {
                        rel = .family
                    } else if detailLower.contains("trabaj") || detailLower.contains("colabor") || detailLower.contains("boss") || detailLower.contains("coworker") || detailLower.contains("work") {
                        rel = .worksWith
                    } else {
                        rel = .knows
                    }
                    if case .failure(let problem) = persist("person_link", {
                        try store.upsert(Edge(id: UUID().uuidString, srcId: selfNode.id, dstId: savedId, relation: rel,
                                              weight: 1, confidence: .sure, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                    }) { tally.note(problem) }
                }
                tally.committed += 1
                noteCommitted(.nrem, item: itemKey)
            }
        }
        onProgress?("+\(tally.committed) entities")
        return tally.result
    }

    // MARK: Transcript helper

    /// Relative dates in this material resolve from when it was spoken.
    private func withAnchor(_ segment: ConsolidationSegment) {
        currentAnchor = segment.anchorAt
    }

    // MARK: Summarize — distill segment into a structured summary node

    /// Group consolidated transcript rows into one summary unit per thread, with the seq-based
    /// message range and role-prefixed texts. Pure (testable without a model/db). Threads are
    /// ordered by their earliest message so summaries are produced in chronological order.
    static func summaryGroups(_ rows: [TranscriptRow]) -> [(threadId: String, range: ClosedRange<Int>, texts: [String])] {
        ConsolidationSegment.segments(rows, maxChars: .max)
            .map { ($0.threadID, $0.seqRange, $0.texts) }
    }

    private struct SummaryOut: Decodable {
        let topic: String; let concepts: [String]
        let intent: String?; let decisions: [String]?; let importance: Double?; let summary: String?
    }

    /// Distill one chat segment into a structured `summary` node ("the ruta"): topic + condensed
    /// concepts, embedded on the concepts (not raw turns) for precise recall. Records threadId +
    /// turnRange in `extra` for later drill-down (M2d-3).
    public func summarize(episodeTexts: [String], threadId: String, turnRange: ClosedRange<Int>) async {
        _ = await summarize(segment: ConsolidationSegment(threadID: threadId, texts: episodeTexts,
                                                          range: turnRange))
    }

    func summarize(segment: ConsolidationSegment) async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.summarize)
        guard !segment.texts.isEmpty else { return tally.result }
        withAnchor(segment)
        let turnRange = segment.seqRange
        let threadId = segment.threadID
        let convo = segment.texts.joined(separator: "\n")
        let prompt = """
        Today is \(todayString()). Summarize this conversation segment as STRUCTURED knowledge about ONE user. Output JSON only.
        Give a short `topic` (2-5 words), the key `concepts` (short noun phrases), the user's `intent`, \
        any `decisions` made, an `importance` 0..1, and a one-sentence `summary`. Don't invent. \
        Answer in the SAME language as the conversation.
        Schema: {"topic":"...","concepts":["..."],"intent":"...","decisions":["..."],"importance":0.5,"summary":"..."}
        Conversation:
        \(convo)
        JSON:
        """
        let out: SummaryOut
        switch await decoded(prompt, SummaryOut.self, maxTokens: 512) {
        case .failure(let failure): tally.note(failure); return tally.result
        case .success(let value): out = value
        }
        let topic = MemoryText.cleanLabel(out.topic)
        guard !topic.isEmpty, !MemoryText.isJunkLabel(topic) else {
            // A summary with no usable topic is a malformed result, not an empty one.
            tally.note(.parse("unusable_topic")); return tally.result
        }
        let itemKey = "summary|\(threadId)|\(turnRange.lowerBound)-\(turnRange.upperBound)"
        if alreadyCommitted(.summarize, item: itemKey) { return tally.result }
        let t = now()
        let extra: [String: Any] = [
            "concepts": out.concepts, "intent": out.intent ?? "", "decisions": out.decisions ?? [],
            "importance": out.importance ?? 0.5, "threadId": threadId,
            "turnRange": [turnRange.lowerBound, turnRange.upperBound],
        ]
        let extraJSON = (try? JSONSerialization.data(withJSONObject: extra)).flatMap { String(data: $0, encoding: .utf8) }
        let prose = (out.summary?.isEmpty == false) ? out.summary! : topic
        let body = out.concepts.isEmpty ? prose : prose + " · " + out.concepts.joined(separator: ", ")
        let node = Node(id: UUID().uuidString, kind: NodeKind.summary.rawValue, label: topic, body: body,
                        layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 4,
                        decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                        ttlExpiresAt: nil, sourceRef: threadId, origin: .extracted, serverId: nil,
                        dirty: true, deleted: false, extra: extraJSON)
        let conceptText = ([topic] + out.concepts).joined(separator: " ")
        let emb = (try? embedder?.embed(conceptText)) ?? nil
        switch persist("summary", { try store.upsertMergingSemantic(node, embedding: emb, embedder: embedder) }) {
        case .failure(let problem): tally.note(problem)
        case .success:
            tally.committed += 1
            noteCommitted(.summarize, item: itemKey)
            onProgress?("+1 summary")
        }
        return tally.result
    }

    /// Light, immediate summarization of the current unconsolidated conversation(s) so each session
    /// has its structured `summary` node promptly (cross-session recall before the full sleep cycle).
    /// Does NOT mark turns consolidated — the full cycle still extracts entities/edges later.
    ///
    /// A thread that was already summarized is not skipped wholesale: only the turns a summary
    /// already covers are, so the turns spoken since the last pass still get summarized.
    public func summarizeRecent() async { _ = await summarizeRecentPhase() }

    func summarizeRecentPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.summarize)
        let rows = ((try? transcriptStore.unconsolidated(limit: 200)) ?? [])
        guard !rows.isEmpty else { return tally.result }
        let watermark = (try? store.summarizedUpTo()) ?? [:]
        let fresh = rows.filter { $0.seq > (watermark[$0.threadId] ?? 0) }
        guard !fresh.isEmpty else { return tally.result }
        for segment in ConsolidationSegment.segments(fresh) {
            tally.absorb(await summarize(segment: segment))
        }
        return tally.result
    }

    // MARK: Detect — mine unresolved threads into follow_up nodes
    private struct FollowUpsOut: Decodable {
        struct F: Decodable { let text: String; let sources: [String]? }
        let followUps: [F]?
        let resolvedTexts: [String]?
    }

    /// Detect unresolved intents / open conversational threads from the recent episodes,
    /// storing them as pending `follow_up` nodes for proactive surfacing on wake,
    /// and marking previously pending follow-ups as completed when resolved.
    public func detectFollowUps(episodeTexts: [String]) async {
        _ = await detectFollowUps(segment: ConsolidationSegment(threadID: "", texts: episodeTexts))
    }

    func detectFollowUps(segment: ConsolidationSegment) async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.detect)
        guard !segment.texts.isEmpty else { return tally.result }
        withAnchor(segment)
        let convo = segment.texts.joined(separator: "\n")
        let allNodes = (try? store.allNodes()) ?? []
        let pendingNodes = allNodes.filter { $0.kind == NodeKind.followUp.rawValue && NodeAttributes.from($0.extra).status != "completed" }
        let pendingList = pendingNodes.prefix(20).map { "- \($0.body)" }.joined(separator: "\n")
        let pendingBlock = pendingList.isEmpty ? "None" : pendingList

        let prompt = """
        This is a recent conversation with ONE user.
        Current pending follow-ups:
        \(pendingBlock)

        Tasks:
        1. List any NEW unresolved loose ends worth following up on later (tasks/intentions, open questions, or unfinished stories).
        2. List exact texts of any pending follow-ups above that were RESOLVED or COMPLETED in this conversation.

        Output JSON only. Don't invent; only genuine loose ends.
        Example: {"followUps":[{"text":"call dentist","sources":["dentist"]}],"resolvedTexts":["hear about trip"]}
        Schema: {"followUps":[{"text":"<short follow-up>","sources":["<entity label>"]}],"resolvedTexts":["<text of resolved follow-up>"]}
        Conversation:
        \(convo)
        JSON:
        """
        let out: FollowUpsOut
        switch await decoded(prompt, FollowUpsOut.self, maxTokens: 512) {
        case .failure(let failure): tally.note(failure); return tally.result
        case .success(let value): out = value
        }

        // Process resolved follow-ups
        for resText in out.resolvedTexts ?? [] {
            let resKey = MemoryText.dedupKey(resText)
            guard let match = pendingNodes.first(where: { MemoryText.dedupKey($0.body) == resKey || MemoryText.dedupKey($0.label) == resKey })
            else { continue }
            let itemKey = "resolved|\(match.id)"
            if alreadyCommitted(.detect, item: itemKey) { continue }
            var attrs = NodeAttributes.from(match.extra)
            attrs.status = "completed"
            var updated = match
            updated.extra = attrs.toJSON()
            updated.deleted = true
            updated.dirty = true
            switch persist("followup_resolved", { try store.upsert(updated) }) {
            case .failure(let problem): tally.note(problem)
            case .success: tally.committed += 1; noteCommitted(.detect, item: itemKey)
            }
        }

        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            return allNodes.first { MemoryText.dedupKey($0.label) == key }
        }
        var existing = Set(allNodes.filter { $0.kind == NodeKind.followUp.rawValue }.map { MemoryText.dedupKey($0.body) })
        var added = 0
        for f in out.followUps ?? [] {
            let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = MemoryText.dedupKey(text)
            if text.isEmpty || existing.contains(key) { continue }
            existing.insert(key)
            let itemKey = "followup|\(key)"
            if alreadyCommitted(.detect, item: itemKey) { continue }
            let t = now()
            var attrs = NodeAttributes(); attrs.status = "pending"
            let node = Node(id: UUID().uuidString, kind: NodeKind.followUp.rawValue, label: String(text.prefix(60)),
                            body: text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
            let fEmb = (try? embedder?.embed(node.label)) ?? nil
            let saved = persist("followup", { () -> String in
                if let embedder, embedder.dimension > 16 {
                    return try store.upsertMergingSemantic(node, embedding: fEmb, embedder: embedder, threshold: 0.15)
                }
                return try store.upsertMerging(node)
            })
            guard case .success(let canonicalID) = saved else {
                if case .failure(let problem) = saved { tally.note(problem) }
                continue
            }
            // Link the follow_up to self:user and to each resolved source entity, always using the
            // id the store kept — a merge may have folded this node into an existing one.
            if let selfNode = try? store.selfNode(), selfNode.id != canonicalID {
                if case .failure(let problem) = persist("followup_self_link", {
                    try store.upsert(Edge(id: UUID().uuidString, srcId: selfNode.id, dstId: canonicalID, relation: .relatedTo, weight: 1,
                                          confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                }) { tally.note(problem) }
            }
            for src in (f.sources ?? []).compactMap(resolve) where src.id != canonicalID {
                if case .failure(let problem) = persist("followup_source_link", {
                    try store.upsert(Edge(id: UUID().uuidString, srcId: canonicalID, dstId: src.id, relation: .relatedTo, weight: 1,
                                          confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                }) { tally.note(problem) }
            }
            added += 1
            tally.committed += 1
            noteCommitted(.detect, item: itemKey)
        }
        onProgress?("+\(added) follow-ups")
        return tally.result
    }

    // MARK: REM — Associate

    private struct EdgesOut: Decodable { struct E: Decodable { let from: String; let relation: String; let to: String }; let edges: [E] }

    public func associate() async { _ = await associatePhase() }

    func associatePhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.rem)
        let nodes = (try? store.allNodes().filter { $0.kind != NodeKind.conversation.rawValue }) ?? []
        guard nodes.count >= 2 else { return tally.result }
        let labels = nodes.prefix(60).map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
        let relations = Relation.allCases.map { $0.rawValue }.joined(separator: ", ")
        let prompt = """
        These memory entities are all facts about ONE person (the user). Propose meaningful relationships between them. Output JSON only.
        The `self` node is the USER (the person you're talking to); connect the user (self) to their preferences (likes/dislikes), places they work or go (locatedAt/worksWith), and the people they know (knows/worksWith/family). Other `person` nodes are third parties — link each to the self with the right relation (family for relatives, knows for friends, worksWith for colleagues). Link genuinely related items with relatedTo. Don't invent entities not listed.
        Use ONLY these relation types: \(relations).
        Example: entities `self: Ana`, `preference: pizza`, `person: María` → {"edges":[{"from":"Ana","relation":"likes","to":"pizza"},{"from":"Ana","relation":"family","to":"María"}]}
        Schema: {"edges":[{"from":"<entity label>","relation":"<one of the types>","to":"<entity label>"}]}
        Entities:
        \(labels)
        JSON:
        """
        let out: EdgesOut
        switch await decoded(prompt, EdgesOut.self, maxTokens: 512) {
        case .failure(let failure): tally.note(failure); return tally.result
        case .success(let value): out = value
        }
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            if key == "self" || key == "user" || key == "me" || key == "yo" {
                if let selfN = try? store.selfNode() { return selfN }
            }
            if let n = nodes.first(where: { MemoryText.dedupKey($0.label) == key }) { return n }
            if let selfN = try? store.selfNode(), MemoryText.dedupKey(selfN.label) == key { return selfN }
            // 0.25 is intentionally looser than upsertMergingSemantic's 0.2 dedup default: linking
            // an edge endpoint tolerates more drift than merging two nodes into one.
            if let emb = (try? embedder?.embed(label)) ?? nil,
               let hit = (try? store.nearest(to: emb, k: 1))?.first, hit.distance <= 0.25 {
                return try? store.node(id: hit.id)
            }
            return nil
        }
        var existing = Set((try? store.allEdges())?.map { "\($0.srcId)|\($0.relation.rawValue)|\($0.dstId)" } ?? [])
        for e in out.edges {
            guard let rel = Relation(rawValue: e.relation), let s = resolve(e.from), let d = resolve(e.to), s.id != d.id else { continue }
            let key = "\(s.id)|\(rel.rawValue)|\(d.id)"
            if existing.contains(key) { continue }
            existing.insert(key)
            let t = now()
            switch persist("edge", {
                try store.upsert(Edge(id: UUID().uuidString, srcId: s.id, dstId: d.id, relation: rel, weight: 1,
                                      confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            }) {
            case .failure(let problem): tally.note(problem)
            case .success: tally.committed += 1
            }
        }
        onProgress?("+\(tally.committed) connections")
        return tally.result
    }

    // MARK: Reflect — Abstract (grounded insights)
    private struct InsightsOut: Decodable { struct I: Decodable { let text: String; let sourceEntities: [String]; let confidence: String? }; let insights: [I] }

    // MARK: Reflect Topics — Topic/Event-based implicit synthesis (travel, health, projects)
    private struct TopicReflectionOut: Decodable {
        struct Insight: Decodable { let text: String; let sourceEntities: [String]? }
        struct ImplicitTask: Decodable { let text: String; let horizon: String? }
        let insights: [Insight]?
        let implicitTasks: [ImplicitTask]?
        let companions: [String]?
    }

    public func reflectTopics() async { _ = await reflectTopicsPhase() }

    func reflectTopicsPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.reflect)
        let allNodes = (try? store.allNodes()) ?? []
        let topics = allNodes.filter {
            $0.kind == NodeKind.event.rawValue || $0.kind == NodeKind.plan.rawValue || $0.kind == NodeKind.topic.rawValue
        }
        guard !topics.isEmpty else { return tally.result }

        var addedInsights = 0
        var addedTasks = 0

        for topic in topics.prefix(15) {
            let edges = (try? store.edges(from: topic.id)) ?? []
            let neighbors = edges.compactMap { try? store.node(id: $0.dstId) }
            let memberText = ([topic] + neighbors).map { "\($0.kind): \($0.label) (\($0.body))" }.joined(separator: "\n")

            let prompt = """
            Today is \(todayString()). Analyze this topic/event/plan about the user:
            Topic: \(topic.label) (\(topic.body))
            Associated entities:
            \(memberText)

            Synthesize implicit knowledge about this topic:
            1. `insights`: Higher-level grounded facts or patterns about the user and this topic. CRITICAL: Insights MUST describe persistent user habits, preferences, relations, or long-term patterns. NEVER output an insight describing a single specific event, a specific date, or containing temporal words like 'today', 'hoy', 'tomorrow', 'mañana', 'yesterday', 'ayer', 'this weekend', etc. Generalize instead.
            2. `implicitTasks`: IMPLICIT preparation needs, requirements, packing, flights, reservations, or follow-up tasks logically implied by this topic that the user may not have explicitly stated.
            3. `companions`: Exact names of people involved or traveling/participating with the user.

            Output JSON only.
            Schema: {"insights":[{"text":"...","sourceEntities":["..."]}],"implicitTasks":[{"text":"...","horizon":"short|long"}],"companions":["..."]}
            JSON:
            """
            let out: TopicReflectionOut
            switch await decoded(prompt, TopicReflectionOut.self, maxTokens: 512) {
            case .failure(let failure): tally.note(failure); continue
            case .success(let value): out = value
            }

            let t = now()
            for ins in out.insights ?? [] {
                let text = ins.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let node = Node(id: UUID().uuidString, kind: NodeKind.insight.rawValue, label: String(text.prefix(60)),
                                body: text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 4,
                                decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                                ttlExpiresAt: nil, sourceRef: topic.id, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
                let emb = (try? embedder?.embed(node.label)) ?? nil
                let saved = persist("topic_insight", { () -> String in
                    if let embedder, embedder.dimension > 16 {
                        return try store.upsertMergingSemantic(node, embedding: emb, embedder: embedder, threshold: 0.15)
                    }
                    return try store.upsertMerging(node)
                })
                guard case .success(let canonicalID) = saved else {
                    if case .failure(let problem) = saved { tally.note(problem) }
                    continue
                }
                // Provenance runs FROM the insight TO its source, and always references the id the
                // store kept: a merged insight must not leave an edge on a pre-merge id.
                if canonicalID != topic.id {
                    if case .failure(let problem) = persist("topic_insight_provenance", {
                        try store.upsert(Edge(id: UUID().uuidString, srcId: canonicalID, dstId: topic.id, relation: .derivesFrom,
                                              weight: 1, confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                    }) { tally.note(problem) }
                }
                if let selfNode = try? store.selfNode(), selfNode.id != canonicalID {
                    if case .failure(let problem) = persist("topic_insight_self_link", {
                        try store.upsert(Edge(id: UUID().uuidString, srcId: selfNode.id, dstId: canonicalID, relation: .relatedTo,
                                              weight: 1, confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                    }) { tally.note(problem) }
                }
                addedInsights += 1
                tally.committed += 1
            }

            for task in out.implicitTasks ?? [] {
                let text = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                var attrs = NodeAttributes(); attrs.status = "pending"; attrs.horizon = task.horizon ?? "short"
                let node = Node(id: UUID().uuidString, kind: NodeKind.task.rawValue, label: String(text.prefix(60)),
                                body: text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                                decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                                ttlExpiresAt: nil, sourceRef: topic.id, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
                let emb = (try? embedder?.embed(node.label)) ?? nil
                let saved = persist("implicit_task", { () -> String in
                    if let embedder, embedder.dimension > 16 {
                        return try store.upsertMergingSemantic(node, embedding: emb, embedder: embedder, threshold: 0.15)
                    }
                    return try store.upsertMerging(node)
                })
                guard case .success(let canonicalID) = saved else {
                    if case .failure(let problem) = saved { tally.note(problem) }
                    continue
                }
                if canonicalID != topic.id {
                    if case .failure(let problem) = persist("implicit_task_link", {
                        try store.upsert(Edge(id: UUID().uuidString, srcId: topic.id, dstId: canonicalID, relation: .relatedTo,
                                              weight: 1, confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                    }) { tally.note(problem) }
                }
                addedTasks += 1
                tally.committed += 1
            }

            for cName in out.companions ?? [] {
                let key = MemoryText.dedupKey(cName)
                if let cNode = allNodes.first(where: { $0.kind == NodeKind.person.rawValue && MemoryText.dedupKey($0.label) == key }) {
                    if case .failure(let problem) = persist("companion_link", {
                        try store.upsert(Edge(id: UUID().uuidString, srcId: topic.id, dstId: cNode.id, relation: .relatedTo,
                                              weight: 1, confidence: .sure, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                    }) { tally.note(problem) }
                    if let selfNode = try? store.selfNode() {
                        if case .failure(let problem) = persist("companion_family_link", {
                            try store.upsert(Edge(id: UUID().uuidString, srcId: selfNode.id, dstId: cNode.id, relation: .family,
                                                  weight: 1, confidence: .sure, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                        }) { tally.note(problem) }
                    }
                }
            }
        }

        if addedInsights > 0 || addedTasks > 0 {
            onProgress?("+\(addedInsights) topic insights, +\(addedTasks) implicit tasks")
        }
        return tally.result
    }

    public func reflect() async { _ = await reflectPhase() }

    func reflectPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.reflect)
        tally.absorb(await reflectTopicsPhase())
        let clusters = (try? store.clusterNodes()) ?? []
        guard !clusters.isEmpty else { return tally.result }
        // Dedup against insights already in the store (runLight reflects frequently over stable clusters).
        var existingInsights = Set(((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.insight.rawValue }.map { MemoryText.dedupKey($0.body) })
        var added = 0
        for cluster in clusters {
            let memberIds = ((try? store.edges(from: cluster.id)) ?? []).filter { $0.relation == .belongsToCluster }.map { $0.dstId }
            let members = memberIds.compactMap { try? store.node(id: $0) }
            guard members.count >= 3 else { continue }   // need a substantial cluster to abstract from
            let labels = members.map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
            let prompt = """
            These memories form ONE thematic group about the user. Infer 1-2 higher-level insights or patterns they reveal. Output JSON only.
            Each insight MUST be grounded in at least TWO of the listed entities (cite their exact labels in sourceEntities). Do not speculate beyond the evidence.
            CRITICAL: Insights MUST describe persistent user habits, preferences, relations, or long-term patterns. NEVER output an insight describing a single specific event, a specific date, or containing temporal words like 'today', 'hoy', 'tomorrow', 'mañana', 'yesterday', 'ayer', 'this weekend', etc. Generalize instead.
            Example: from `preference: sushi`, `preference: ramen` → {"insights":[{"text":"enjoys Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"}]}
            Schema: {"insights":[{"text":"...","sourceEntities":["label1","label2"],"confidence":"probable|maybe"}]}
            Memories:
            \(labels)
            JSON:
            """
            let out: InsightsOut
            switch await decoded(prompt, InsightsOut.self, maxTokens: 512) {
            case .failure(let failure): tally.note(failure); continue
            case .success(let value): out = value
            }
            func resolve(_ label: String) -> Node? {
                let key = MemoryText.dedupKey(label)
                return members.first { MemoryText.dedupKey($0.label) == key }
            }
            for ins in out.insights {
                let sources = ins.sourceEntities.compactMap(resolve)
                if Set(sources.map { $0.id }).count < 2 { continue }   // anti-fabrication: grounded in ≥2 members
                let key = MemoryText.dedupKey(ins.text)
                if existingInsights.contains(key) { continue }
                existingInsights.insert(key)
                let t = now()
                let conf = Confidence(rawValue: ins.confidence ?? "probable") ?? .probable
                // Cluster size and model confidence do not supply independent identity evidence.
                let layer: MemoryLayer = .daily
                let node = Node(id: UUID().uuidString, kind: NodeKind.insight.rawValue, label: String(ins.text.prefix(60)),
                                body: ins.text, layer: layer, createdAt: t, updatedAt: t, lastSeenAt: t,
                                salience: 3, decayRate: Decay.defaultDecayRate(for: layer), confidence: conf,
                                mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                                dirty: true, deleted: false, extra: nil)
                let insEmb = (try? embedder?.embed(node.label)) ?? nil
                let saved = persist("insight", { () -> String in
                    if let embedder, embedder.dimension > 16 {
                        return try store.upsertMergingSemantic(node, embedding: insEmb, embedder: embedder, threshold: 0.15)
                    }
                    return try store.upsertMerging(node)
                })
                guard case .success(let canonicalID) = saved else {
                    if case .failure(let problem) = saved { tally.note(problem) }
                    continue
                }
                // insight → derivesFrom → member, on the id the store kept.
                for s in sources where s.id != canonicalID {
                    if case .failure(let problem) = persist("insight_provenance", {
                        try store.upsert(Edge(id: UUID().uuidString, srcId: canonicalID, dstId: s.id, relation: .derivesFrom, weight: 1,
                                              confidence: conf, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                    }) { tally.note(problem) }
                }
                added += 1
                tally.committed += 1
            }
        }
        onProgress?("+\(added) insights")
        return tally.result
    }

    // MARK: Compress — merge near-duplicate insights into one canonical node
    public func compress() async { _ = await compressPhase() }

    func compressPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.compress)
        switch persist("compress", { try store.compressInsights(embedder: embedder) }) {
        case .failure(let problem): tally.note(problem); return tally.result
        case .success(let n):
            tally.committed += n
            if n > 0 { onProgress?("-\(n) duplicate insight\(n == 1 ? "" : "s")") }
        }
        tally.committed += repointProvenanceOntoCanonicalNodes(&tally)
        return tally.result
    }

    /// Move provenance off nodes that compression folded away.
    ///
    /// `compressInsights` keeps the highest-salience node, soft-deletes the duplicate and leaves a
    /// `sameAs` edge from the folded node to the survivor. Any `derivesFrom` edge still attached to
    /// the folded node would be swept away by `forget()`'s dangling-edge prune, silently costing an
    /// insight its evidence trail — so each one is re-pointed at the canonical node instead.
    private func repointProvenanceOntoCanonicalNodes(_ tally: inout PhaseTally) -> Int {
        let live = Set(((try? store.allNodes()) ?? []).map { $0.id })
        let edges = (try? store.allEdges()) ?? []
        var canonical: [String: String] = [:]
        for e in edges where e.relation == .sameAs && !live.contains(e.srcId) && live.contains(e.dstId) {
            canonical[e.srcId] = e.dstId
        }
        guard !canonical.isEmpty else { return 0 }
        var existing = Set(edges.map { "\($0.srcId)|\($0.relation.rawValue)|\($0.dstId)" })
        var moved = 0
        for e in edges where e.relation == .derivesFrom {
            let src = canonical[e.srcId] ?? e.srcId
            let dst = canonical[e.dstId] ?? e.dstId
            guard src != e.srcId || dst != e.dstId else { continue }
            guard live.contains(src), live.contains(dst), src != dst else { continue }
            let key = "\(src)|\(Relation.derivesFrom.rawValue)|\(dst)"
            if existing.contains(key) { continue }
            existing.insert(key)
            let t = now()
            switch persist("provenance_repoint", {
                try store.upsert(Edge(id: UUID().uuidString, srcId: src, dstId: dst, relation: .derivesFrom,
                                      weight: e.weight, confidence: e.confidence, createdAt: t, updatedAt: t,
                                      dirty: true, deleted: false, extra: nil))
            }) {
            case .failure(let problem): tally.note(problem)
            case .success: moved += 1
            }
        }
        if moved > 0 { onProgress?("~\(moved) provenance edge\(moved == 1 ? "" : "s") re-pointed") }
        return moved
    }

    // MARK: Embeddings stage — ensure every clusterable node has a vector

    /// Clusterable node kinds (durable atomic memories + summaries). Excludes self, hubs, events,
    /// conversation, insight, cluster, follow_up, clarification, day, episode, task.
    private static let clusterableKinds: Set<String> = [
        NodeKind.person.rawValue, NodeKind.place.rawValue, NodeKind.fact.rawValue,
        NodeKind.preference.rawValue, NodeKind.topic.rawValue, NodeKind.trait.rawValue,
        NodeKind.plan.rawValue, NodeKind.summary.rawValue,
    ]

    /// Idempotent: embed every clusterable node that lacks a vector. The substrate for clustering.
    /// Embeddings are an acceleration, never a prerequisite — with no embedder this is an empty
    /// success, not a failure.
    public func embedMissing() async { _ = await embedMissingPhase() }

    func embedMissingPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.embeddings)
        guard let embedder else { return tally.result }
        let embedded = Set(((try? store.allEmbeddings()) ?? []).map { $0.id })
        let nodes = ((try? store.allNodes()) ?? []).filter {
            Self.clusterableKinds.contains($0.kind) && !embedded.contains($0.id)
        }
        for n in nodes {
            let text = n.body.isEmpty ? n.label : n.label + " " + n.body
            guard let v = try? embedder.embed(text) else { continue }
            switch persist("embedding", { try store.setEmbedding(nodeId: n.id, v) }) {
            case .failure(let problem): tally.note(problem)
            case .success: tally.committed += 1
            }
        }
        if tally.committed > 0 { onProgress?("+\(tally.committed) embeddings") }
        return tally.result
    }

    // MARK: Clustering stage — k-NN communities → ephemeral cluster anchors + belongsToCluster edges

    /// Recompute clusters globally: build a k-NN graph over clusterable embeddings, run
    /// label-propagation, and rebuild ephemeral `cluster` anchors + `belongsToCluster` edges.
    public func cluster() async { _ = await clusterPhase() }

    func clusterPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.cluster)
        let nodes = (try? store.allNodes()) ?? []
        // Exclude structural kind-hubs (id "hub:<kind>") regardless of their `kind` — even if a hub
        // were ever mis-kinded into a clusterable kind, it must never be clustered/reflected over.
        let clusterableIds = Set(nodes.filter { Self.clusterableKinds.contains($0.kind) && !$0.id.hasPrefix("hub:") }.map { $0.id })
        let embs = ((try? store.allEmbeddings()) ?? []).filter { clusterableIds.contains($0.id) }
        if case .failure(let problem) = persist("clear_clusters", { try store.clearClusters() }) {
            tally.note(problem); return tally.result
        }
        guard embs.count >= 2 else { return tally.result }
        let adj = Clustering.knnGraph(embs.map { (id: $0.id, vec: $0.vec) }, k: 8, maxDistance: 0.25)
        let communities = Clustering.labelPropagation(adj, minSize: 2)
        let t = now()
        for community in communities {
            let anchorId = UUID().uuidString
            let anchor = Node(id: anchorId, kind: NodeKind.cluster.rawValue, label: "cluster", body: "",
                              layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t,
                              salience: Double(community.count), decayRate: 0, confidence: .probable,
                              mentionCount: community.count, ttlExpiresAt: nil, sourceRef: nil,
                              origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
            if case .failure(let problem) = persist("cluster_anchor", { try store.upsert(anchor) }) {
                tally.note(problem); continue
            }
            for memberId in community {
                if case .failure(let problem) = persist("cluster_member", {
                    try store.upsert(Edge(id: UUID().uuidString, srcId: anchorId, dstId: memberId,
                                          relation: .belongsToCluster, weight: 1, confidence: .probable,
                                          createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
                }) { tally.note(problem) }
            }
            tally.committed += 1
        }
        onProgress?("+\(tally.committed) clusters")
        return tally.result
    }

    // MARK: Tagging stage — cluster→tag with embedding synonym-collapse

    private struct TagsOut: Decodable { let tags: [String] }

    /// Label each cluster with 1-3 canonical thematic tags (cluster→tag) and write them onto the
    /// member nodes. A new tag is collapsed onto an existing near-synonym (embedding ≤ 0.15) so the
    /// vocabulary stays clean without an LLM curation pass.
    public func tagClusters() async { _ = await tagClustersPhase() }

    func tagClustersPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.tag)
        let clusters = (try? store.clusterNodes()) ?? []
        guard !clusters.isEmpty else { return tally.result }
        var vocab: [(tag: String, vec: [Float])] = []
        for tag in (try? store.distinctTags()) ?? [] {
            if let v = (try? embedder?.embed(tag)) ?? nil { vocab.append((tag, v)) }
        }
        func canonical(_ raw: String) -> String? {
            let tag = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return nil }
            if let existing = vocab.first(where: { $0.tag == tag }) { return existing.tag }   // exact reuse
            if let v = (try? embedder?.embed(tag)) ?? nil {
                if let hit = vocab.min(by: { MemoryStore.cosineDistance($0.vec, v) < MemoryStore.cosineDistance($1.vec, v) }),
                   MemoryStore.cosineDistance(hit.vec, v) <= 0.15 { return hit.tag }           // synonym collapse
                vocab.append((tag, v))                                                         // new canonical
            }
            return tag
        }
        var tagged = 0
        var taggedIds = Set<String>()
        for cluster in clusters {
            let memberIds = ((try? store.edges(from: cluster.id)) ?? []).filter { $0.relation == .belongsToCluster }.map { $0.dstId }
            let members = memberIds.compactMap { try? store.node(id: $0) }
            guard !members.isEmpty else { continue }
            let labels = members.map { $0.label }.joined(separator: ", ")
            let prompt = """
            These memories form ONE thematic group about the user: \(labels).
            Give 1-3 short canonical lowercase thematic tags (a single word or two-word phrase each). Output JSON only.
            Schema: {"tags":["..."]}
            JSON:
            """
            let out: TagsOut
            switch await decoded(prompt, TagsOut.self, maxTokens: 128) {
            case .failure(let failure): tally.note(failure); continue
            case .success(let value): out = value
            }
            let tags = Array(out.tags.compactMap(canonical).prefix(3))
            guard !tags.isEmpty else { continue }
            for m in members {
                if case .failure(let problem) = persist("tags", { try store.setTags(nodeId: m.id, tags) }) {
                    tally.note(problem); continue
                }
                taggedIds.insert(m.id)
            }
            if var c = try? store.node(id: cluster.id) {
                c.label = tags[0]; c.updatedAt = now(); c.dirty = true
                if case .failure(let problem) = persist("cluster_label", { try store.upsert(c) }) { tally.note(problem) }
            }
            tagged += 1
            tally.committed += 1
        }
        // Tags reflect CURRENT clustering: clear stale tags from clusterable nodes that dropped out
        // of every cluster this cycle (so a node's tags never outlive its cluster membership).
        for n in ((try? store.allNodes()) ?? []) where Self.clusterableKinds.contains(n.kind) && !taggedIds.contains(n.id) {
            if !((try? store.tagsFor(nodeId: n.id)) ?? []).isEmpty {
                if case .failure(let problem) = persist("stale_tags", { try store.setTags(nodeId: n.id, []) }) {
                    tally.note(problem)
                }
            }
        }
        onProgress?("tagged \(tagged)/\(clusters.count) clusters")
        return tally.result
    }

    // MARK: Clarify — ask the user when consolidation is genuinely unsure about event identity
    private struct ClarifyOut: Decodable { let questions: [String] }

    /// During reflection/sleep: if consolidation is unsure whether two memories are the same
    /// (a task rephrased/extended vs a genuinely new one), ask the USER instead of guessing.
    /// Emits pending `clarification` nodes (surfaced proactively in chat — Task 5). Never invents.
    public func clarify() async { _ = await clarifyPhase() }

    func clarifyPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.clarify)
        let events = ((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.task.rawValue || $0.kind == NodeKind.plan.rawValue }
        guard events.count >= 2 else { return tally.result }
        let list = events.map { "- [\($0.kind)] \($0.label): \($0.body)" }.joined(separator: "\n")
        let prompt = """
        Today is \(todayString()). These are the user's tasks/plans. ONLY if two of them might be the SAME thing
        described twice (a rephrase/extension) and you are genuinely UNSURE, write a short question to ask the user
        to disambiguate. If everything is clearly distinct, return an empty list. Output JSON only. Never invent.
        Schema: {"questions":["<short question>"]}
        Items:
        \(list)
        JSON:
        """
        let out: ClarifyOut
        switch await decoded(prompt, ClarifyOut.self, maxTokens: 256) {
        case .failure(let failure): tally.note(failure); return tally.result
        case .success(let value): out = value
        }
        let existing = Set(((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.clarification.rawValue }.map { MemoryText.dedupKey($0.body) })
        for q in out.questions {
            let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || existing.contains(MemoryText.dedupKey(text)) { continue }
            var attrs = NodeAttributes(); attrs.status = "pending"
            let t = now()
            let node = Node(id: UUID().uuidString, kind: NodeKind.clarification.rawValue, label: String(text.prefix(60)),
                            body: text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 4,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false,
                            extra: attrs.toJSON())
            switch persist("clarification", { try store.upsert(node) }) {
            case .failure(let problem): tally.note(problem)
            case .success: tally.committed += 1
            }
        }
        if tally.committed > 0 { onProgress?("+\(tally.committed) question\(tally.committed == 1 ? "" : "s")") }
        return tally.result
    }

    /// A consolidated event collides with an existing one → don't create it; ask the user (reuses the
    /// existing clarification surfacing). Dedups against existing clarification bodies.
    private func emitConflictClarification(title: String, date: String, time: String, conflicts: [Node]) {
        let others = conflicts.map { $0.label }.joined(separator: ", ")
        let body = "Mencionaste «\(title)» el \(date) a las \(time), pero choca con \(others). ¿Lo agendo igual, lo reprogramo, o cancelo el otro?"
        let existing = Set(((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.clarification.rawValue }.map { MemoryText.dedupKey($0.body) })
        if existing.contains(MemoryText.dedupKey(body)) { return }
        var attrs = NodeAttributes(); attrs.status = "pending"
        let t = now(); let id = UUID().uuidString
        let node = Node(id: id, kind: NodeKind.clarification.rawValue, label: String(body.prefix(60)),
                        body: body, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 4,
                        decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                        ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true,
                        deleted: false, extra: attrs.toJSON())
        try? store.upsert(node)
        for c in conflicts {
            try? store.upsert(Edge(id: UUID().uuidString, srcId: id, dstId: c.id, relation: .clarifies,
                                   weight: 1, confidence: .probable, createdAt: t, updatedAt: t,
                                   dirty: true, deleted: false, extra: nil))
        }
        onProgress?("+1 conflict question")
    }

    // MARK: Curate — fold synonym kinds into a canonical vocabulary
    private struct KindMapOut: Decodable { let map: [String: String] }

    public func curateKinds() async { _ = await curateKindsPhase() }

    func curateKindsPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.curate)
        // `known` includes structural HubKind so a hub is NEVER treated as a foldable memory kind:
        // mapping hub→topic would turn the 18 structural kind-hubs into clusterable `topic` nodes,
        // which then poison cluster→reflect→identity (confabulated "the user categorizes information").
        let standard = NodeKind.allCases.map { $0.rawValue }
        let known = Set(standard + HubKind.allCases.map { $0.rawValue })
        let kinds = (try? store.distinctKinds()) ?? []
        let unknown = kinds.filter { !known.contains($0) }
        guard !unknown.isEmpty else { return tally.result }
        let prompt = """
        Map each non-standard memory kind to the closest STANDARD kind, or keep it if it's genuinely distinct. Output JSON only.
        Standard kinds: \(standard.joined(separator: ", ")). Schema: {"map":{"<kind>":"<standard-or-same>"}}
        Kinds to map: \(unknown.joined(separator: ", "))
        JSON:
        """
        let out: KindMapOut
        switch await decoded(prompt, KindMapOut.self, maxTokens: 512) {
        case .failure(let failure): tally.note(failure); return tally.result
        case .success(let value): out = value
        }
        // Guard `from`: even if the model hallucinates a mapping for a known/structural kind we didn't
        // ask about, never reassign it — only genuinely non-standard kinds get folded.
        for (from, to) in out.map where from != to && !to.isEmpty && !known.contains(from) {
            switch persist("kind_fold", { try store.reassignKind(from: from, to: to) }) {
            case .failure(let problem): tally.note(problem)
            case .success: tally.committed += 1
            }
        }
        return tally.result
    }

    // MARK: SHY — Forget / downscale
    public func forget() async { _ = await forgetPhase() }

    func forgetPhase() async -> ConsolidationPhaseResult {
        var tally = PhaseTally(.shy)
        if case .failure(let problem) = persist("sweep", { try store.sweep(now: now()) }) { tally.note(problem) }
        if case .failure(let problem) = persist("prune_edges", { try store.pruneDanglingEdges() }) { tally.note(problem) }
        return tally.result
    }

    // MARK: Cycle driver (resumable). `@escaping` to match the ConsolidationRunning protocol.

    public func runCycle(isCancelled: @escaping () -> Bool, timeZone: TimeZone = .current) async {
        _ = await runCycleReporting(isCancelled: isCancelled, timeZone: timeZone)
    }

    /// Run (or resume) one full cycle and report, phase by phase, what actually happened.
    ///
    /// Resumption works off two records that the engine can recompute deterministically: the
    /// persisted `sleep_cycle` phase, and a per-phase receipt keyed on the job's stable operation
    /// id. A phase whose receipt already says it succeeded is skipped, so an interruption between
    /// a phase's writes committing and its receipt landing costs at most one convergent re-run —
    /// never a duplicate and never a loss.
    @discardableResult
    func runCycleReporting(isCancelled: @escaping () -> Bool,
                           timeZone: TimeZone = .current) async -> ConsolidationCycleReport {
        currentTimeZone = timeZone
        var state: SleepCycleState
        if let existing = (try? store.loadSleepCycle()) ?? nil {
            state = existing
        } else {
            let pending = ((try? transcriptStore.unconsolidated(limit: 200)) ?? [])
            let batch = pending.map { $0.id }
            guard !batch.isEmpty else { return ConsolidationCycleReport(jobID: "") }
            let texts0 = ConsolidationSegment.segments(pending, maxChars: .max).flatMap { $0.texts }
            let focus = String(texts0.joined(separator: " · ").prefix(100))
            state = SleepCycleState(phase: .nrem, episodeIds: batch, startedAt: now(), focus: focus)
            try? store.saveSleepCycle(state)
        }

        // The job carries the timezone the work started in, so a cycle that resumes tomorrow still
        // resolves the user's relative dates the way the user meant them.
        let proposed = ConsolidationJob(id: ConsolidationJob.identifier(transcriptIDs: state.episodeIds),
                                        phase: state.phase, transcriptIDs: state.episodeIds,
                                        evidenceIDs: [], timeZoneIdentifier: timeZone.identifier,
                                        startedAt: state.startedAt)
        var job = (try? store.openConsolidationJob(proposed)) ?? proposed
        currentTimeZone = job.timeZone
        currentJob = job
        defer { currentJob = nil; currentAnchor = nil }
        var report = ConsolidationCycleReport(jobID: job.id)

        let rows = (try? transcriptStore.rows(ids: state.episodeIds)) ?? []
        let evidenceIDs = recordEvidence(for: rows)
        if job.evidenceIDs != evidenceIDs {
            job.evidenceIDs = evidenceIDs
            try? store.updateConsolidationJob(job)
            currentJob = job
        }

        let order = MemoryConsolidationEngine.cycleOrder
        guard let startIdx = order.firstIndex(of: state.phase) else { return report }
        for phase in order[startIdx...] {
            if isCancelled() {   // leave persisted phase for resume
                report.cancelled = true
                return report
            }
            let operationID = job.operationID(for: phase)
            if let receipt = (try? store.consolidationReceipt(jobID: job.id, operationID: operationID)) ?? nil,
               receipt.succeeded {
                advance(&state, past: phase, in: order)
                continue
            }
            let result = await run(phase, rows: rows, state: &state)
            report.results.append(result)
            try? store.recordConsolidationReceipt(jobID: job.id, result, operationID: operationID, at: now())
            for refusal in result.refusals { onProgress?("withheld: \(refusal.code)") }
            if let failure = result.failure {
                onProgress?("\(phase.rawValue) failed at \(failure.stage.rawValue)"
                            + (phase.consumesJobInputs ? " — turns kept" : ""))
                // Only the phases that read the turns can lose content. One of those failing ends
                // the cycle with the turns still un-consolidated, so a later cycle re-reads them.
                if phase.consumesJobInputs { return report }
            }
            advance(&state, past: phase, in: order)
        }

        // One transaction: the turns are marked, the resume state is retired and the job is stamped
        // together, so "consolidated" and "finished" can never be observed apart.
        let committed = report.results.reduce(0) { $0 + $1.committed }
        do {
            try transcriptStore.completeConsolidation(ids: state.episodeIds, jobID: job.id,
                                                      operationID: job.completionOperationID,
                                                      phase: .shy, committed: committed, at: now())
            report.inputsConsolidated = true
            onProgress?("done")
        } catch {
            onProgress?("completion failed — turns kept")
        }
        return report
    }

    private func advance(_ state: inout SleepCycleState, past phase: SleepPhase, in order: [SleepPhase]) {
        guard let next = order.firstIndex(of: phase).map({ $0 + 1 }), next < order.count else { return }
        state.phase = order[next]
        try? store.saveSleepCycle(state)
    }

    /// One phase of a cycle, over the job's own transcript rows.
    private func run(_ phase: SleepPhase, rows: [TranscriptRow],
                     state: inout SleepCycleState) async -> ConsolidationPhaseResult {
        // Only the phases that read the turns date themselves from those turns. The graph-wide
        // phases reason about the user's memory as it stands now, so they use the clock.
        if !phase.consumesJobInputs { currentAnchor = nil }
        switch phase {
        case .nrem:
            var tally = PhaseTally(.nrem)
            // Segment-sized generation: one coherent slice of one thread per call, each anchored
            // on when it was spoken.
            for segment in ConsolidationSegment.segments(rows) {
                tally.absorb(await consolidate(segment: segment))
            }
            // Refine focus to the consolidated entities (semantic, reads naturally) now that
            // NREM has minted nodes. The initial positional focus set at cycle start stays the
            // fallback if NREM produced nothing. Persist so an interrupted resume keeps it.
            let salient = ((try? store.allNodes()) ?? [])
                .filter { $0.kind != NodeKind.conversation.rawValue
                          && $0.kind != NodeKind.insight.rawValue
                          && $0.kind != NodeKind.episode.rawValue }
                .sorted { $0.salience > $1.salience }
                .prefix(6)
                .map { $0.label }
            if !salient.isEmpty {
                state.focus = String(salient.joined(separator: ", ").prefix(100))
                try? store.saveSleepCycle(state)
            }
            return tally.result
        case .summarize:
            var tally = PhaseTally(.summarize)
            for segment in ConsolidationSegment.segments(rows, maxChars: .max) {
                tally.absorb(await summarize(segment: segment))
            }
            return tally.result
        case .detect:
            var tally = PhaseTally(.detect)
            for segment in ConsolidationSegment.segments(rows) {
                tally.absorb(await detectFollowUps(segment: segment))
            }
            return tally.result
        case .embeddings: return await embedMissingPhase()
        case .cluster: return await clusterPhase()
        case .tag: return await tagClustersPhase()
        case .rem: return await associatePhase()
        case .reflect: return await reflectPhase()
        case .compress: return await compressPhase()
        case .clarify: return await clarifyPhase()
        case .curate: return await curateKindsPhase()
        case .shy: return await forgetPhase()
        }
    }

    /// Adapt the job's raw transcript rows into evidence and return the evidence ids.
    ///
    /// Ids are derived from `(threadId, seq, digest(text))`, so re-running this is a no-op rather
    /// than a second independent root of support. The speaker is the transcript's own `role`: a row
    /// whose role is neither `user` nor `assistant` is skipped rather than attributed to anyone.
    /// Consolidation grants itself only the narrow, server-side authorization this needs — never
    /// `mayForget`, and nothing derived from model output.
    private func recordEvidence(for rows: [TranscriptRow]) -> [String] {
        guard !rows.isEmpty else { return [] }
        let threads = Set(rows.map { $0.threadId })
        let brain = BrainStore(store: store,
                               authorization: ConsolidationEvidenceAdapter.authorization(threads: threads),
                               clock: now)
        var ids: [String] = []
        var unrecorded = 0
        for row in rows {
            // A row the transcript cannot attribute is skipped rather than given a speaker.
            guard let evidence = ConsolidationEvidenceAdapter.evidence(for: row, recordedAt: now()) else { continue }
            // The deterministic id doubles as the idempotency key: the same row always replays onto
            // the same record.
            if (try? brain.recordEvidence(evidence, idempotencyKey: evidence.id)) != nil {
                ids.append(evidence.id)
            } else {
                unrecorded += 1
            }
        }
        if unrecorded > 0 { onProgress?("\(unrecorded) turn(s) could not be recorded as evidence") }
        return ids
    }

    /// Awake light reflection: summarize the current session promptly, then associate + reflect
    /// over current memory, no replay/curate/forget.
    ///
    /// `reflect()` stays out of this path deliberately: it is cluster-dependent, and clusters are
    /// only rebuilt by the full cycle.
    public func runLight(isCancelled: @escaping () -> Bool, timeZone: TimeZone = .current) async {
        _ = await runLightReporting(isCancelled: isCancelled, timeZone: timeZone)
    }

    @discardableResult
    func runLightReporting(isCancelled: @escaping () -> Bool,
                           timeZone: TimeZone = .current) async -> ConsolidationCycleReport {
        currentTimeZone = timeZone
        currentAnchor = nil
        var report = ConsolidationCycleReport(jobID: "light")
        if isCancelled() { report.cancelled = true; return report }
        report.results.append(await summarizeRecentPhase())
        if isCancelled() { report.cancelled = true; return report }
        report.results.append(await associatePhase())
        if isCancelled() { report.cancelled = true; return report }
        report.results.append(await reflectTopicsPhase())
        if isCancelled() { report.cancelled = true; return report }
        report.results.append(await clarifyPhase())
        return report
    }
}
