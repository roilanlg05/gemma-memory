import Foundation

/// Brain-like consolidation operations over the memory graph, driven by the local model.
/// Phases are independent units (testable with a fake runtime). The resumable cycle driver
/// (`runCycle`) and the awake-light path (`runLight`) compose these phases. A persisted
/// `sleep_cycle` lets a cycle resume from where it was interrupted.
public final class MemoryConsolidationEngine: ConsolidationRunning, @unchecked Sendable {
    private let store: MemoryStore
    private let embedder: Embedder?
    private let runtime: any ModelTextClient
    private let transcriptStore: TranscriptStore
    private let now: () -> Double
    /// Timezone for the in-flight cycle (set by runCycle/runLight). Cycles are serialized by the
    /// scheduler, so a single instance var is safe. Defaults to server tz for direct phase tests.
    private var currentTimeZone: TimeZone = .current
    public var onProgress: ((String) -> Void)?   // e.g. "+2 entities", "+1 edge"

    public init(store: MemoryStore, embedder: Embedder?, runtime: any ModelTextClient,
                transcriptStore: TranscriptStore? = nil,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store; self.embedder = embedder; self.runtime = runtime
        self.transcriptStore = transcriptStore ?? TranscriptStore(dbQueue: store.dbQueue); self.now = now
    }

    // MARK: shared

    /// Run one plain-text generation and return its full text.
    ///
    /// All consolidation phases run thinking-OFF (the runtime's default): verified against the
    /// real 26B, this model over-reasons and truncates the JSON (often to empty — 0 entities)
    /// when thinking is on, and is ~3.5-5x slower. Thinking-off is reliable and fast across every
    /// phase (consolidate/detect/associate/reflect/curate), and 512 tokens is enough for the
    /// JSON-only output we ask for (verified).
    private func generate(_ prompt: String, maxTokens: Int = 512) async -> String {
        do {
            return try await runtime.generate(prompt: prompt,
                                              options: ModelTextOptions(maxTokens: maxTokens, temperature: 0.3))
        } catch {
            return ""
        }
    }

    /// Outermost {...} JSON object from noisy model output.
    static func extractJSON(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b])
    }
    private func parse<T: Decodable>(_ raw: String, _ type: T.Type) -> T? {
        guard let j = Self.extractJSON(raw), let d = j.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    // MARK: NREM — Consolidate

    private func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd (EEEE)"; f.timeZone = currentTimeZone
        return f.string(from: Date(timeIntervalSince1970: now()))
    }

    private struct EntitiesOut: Decodable {
        struct E: Decodable { let entity: String; let kind: String?; let detail: String?; let permanent: Bool?
            struct Attr: Decodable { let status: String?; let horizon: String?; let date: String?
                let startTime: String?; let endTime: String?; let allDay: Bool?; let location: String? }
            let attributes: Attr? }
        let entities: [E]
    }

    public func consolidate(episodeTexts: [String]) async {
        guard !episodeTexts.isEmpty else { return }
        let convo = episodeTexts.joined(separator: "\n")
        let prompt = """
        Today is \(todayString()). Resolve any relative date (today/tomorrow/a weekday) to an absolute date and put it in attributes.date as "yyyy-MM-dd".
        Extract durable facts the USER stated about themselves from this conversation. Output JSON only.
        Use a short canonical `entity` (a noun/name, not a sentence). The "entity" MUST be a short canonical noun/name (1-3 words), NEVER a sentence (e.g. "Roilan", not "the user's name is Roilan"). Choose a `kind`: person, place, \
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
        guard let out = parse(await generate(prompt, maxTokens: 512), EntitiesOut.self) else { return }
        var added = 0
        for e in out.entities {
            // Structured event: a timed entity with a local date+time → first-class `event`, conflict-checked.
            if let date = e.attributes?.date, let startTime = e.attributes?.startTime,
               let st = ScheduleTime.epoch(date: date, time: startTime, tz: currentTimeZone) {
                let en = e.attributes?.endTime.flatMap { ScheduleTime.epoch(date: date, time: $0, tz: currentTimeZone) } ?? (st + 3600)
                let evLabel = MemoryText.canonicalEntityLabel(e.entity)
                if !MemoryText.isJunkLabel(evLabel), en > st {
                    let allDay = e.attributes?.allDay ?? false
                    if let result = try? store.createEventChecked(title: evLabel, start: st, end: en, allDay: allDay,
                                                                  location: e.attributes?.location, origin: .extracted, force: false) {
                        if let evId = result.id {
                            if let emb = (try? embedder?.embed(evLabel)) ?? nil { try? store.setEmbedding(nodeId: evId, emb) }
                            added += 1
                        } else {
                            emitConflictClarification(title: evLabel, date: date, time: startTime, conflicts: result.conflicts)
                        }
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
            let kind = rawKind
            let layer: MemoryLayer = (e.permanent ?? false) ? .identity : .daily
            var attrs = NodeAttributes(); attrs.status = e.attributes?.status; attrs.horizon = e.attributes?.horizon; attrs.date = e.attributes?.date
            let t = now()
            let baseBody = e.detail ?? label
            let body = (attrs.date != nil) ? baseBody + " (fecha: \(attrs.date!))" : baseBody
            let node = Node(id: UUID().uuidString, kind: kind, label: label, body: body, layer: layer,
                            createdAt: t, updatedAt: t, lastSeenAt: t, salience: (e.permanent ?? false) ? 8 : 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                            dirty: true, deleted: false, extra: attrs.toJSON())
            let eventKinds: Set<String> = [NodeKind.task.rawValue, NodeKind.plan.rawValue]
            let emb = (try? embedder?.embed(label)) ?? nil
            if eventKinds.contains(kind) {
                // Events are distinct occurrences — never auto-merge (would lose a meeting).
                // Ambiguous same-vs-different is resolved by clarify() asking the user (Task 3).
                do {
                    try store.upsert(node)
                    if let emb { try store.setEmbedding(nodeId: node.id, emb) }
                    added += 1
                } catch {}
            } else if (try? store.upsertMergingSemantic(node, embedding: emb, embedder: embedder)) != nil {
                added += 1
            }
        }
        onProgress?("+\(added) entities")
    }

    // MARK: Transcript helper

    private func episodeTexts(ids: [String]) -> [String] {
        let rows = (try? transcriptStore.rows(ids: ids)) ?? []
        return rows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
    }

    // MARK: Summarize — distill segment into a structured summary node

    private struct SummaryOut: Decodable {
        let topic: String; let concepts: [String]
        let intent: String?; let decisions: [String]?; let importance: Double?; let summary: String?
    }

    /// Distill one chat segment into a structured `summary` node ("the ruta"): topic + condensed
    /// concepts, embedded on the concepts (not raw turns) for precise recall. Records threadId +
    /// turnRange in `extra` for later drill-down (M2d-3).
    public func summarize(episodeTexts: [String], threadId: String, turnRange: ClosedRange<Int>) async {
        guard !episodeTexts.isEmpty else { return }
        let convo = episodeTexts.joined(separator: "\n")
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
        guard let out = parse(await generate(prompt, maxTokens: 512), SummaryOut.self) else { return }
        let topic = MemoryText.cleanLabel(out.topic)
        guard !topic.isEmpty, !MemoryText.isJunkLabel(topic) else { return }
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
        _ = try? store.upsertMergingSemantic(node, embedding: emb, embedder: embedder)
        onProgress?("+1 summary")
    }

    /// Light, immediate summarization of the current unconsolidated conversation(s) so each session
    /// has its structured `summary` node promptly (cross-session recall before the full sleep cycle).
    /// Does NOT mark turns consolidated — the full cycle still extracts entities/edges later.
    /// Skips a thread that already has a summary (avoids re-summarizing on every pause).
    public func summarizeRecent() async {
        let rows = ((try? transcriptStore.unconsolidated(limit: 200)) ?? [])
        guard !rows.isEmpty else { return }
        let alreadySummarized = Set(((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.summary.rawValue }
            .compactMap { $0.sourceRef })
        let groups = Dictionary(grouping: rows, by: { $0.threadId })
            .sorted { ($0.value.map(\.createdAt).min() ?? 0) < ($1.value.map(\.createdAt).min() ?? 0) }
        for (threadId, tRows) in groups where !alreadySummarized.contains(threadId) {
            let turns = tRows.map { $0.turnIndex }
            let range = (turns.min() ?? 0)...(turns.max() ?? 0)
            let texts = tRows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
            await summarize(episodeTexts: texts, threadId: threadId, turnRange: range)
        }
    }

    // MARK: Detect — mine unresolved threads into follow_up nodes
    private struct FollowUpsOut: Decodable { struct F: Decodable { let text: String; let sources: [String]? }; let followUps: [F] }

    /// Detect unresolved intents / open conversational threads from the recent episodes,
    /// storing them as pending `follow_up` nodes for proactive surfacing on wake.
    public func detectFollowUps(episodeTexts: [String]) async {
        guard !episodeTexts.isEmpty else { return }
        let convo = episodeTexts.joined(separator: "\n")
        let prompt = """
        This is a recent conversation with ONE user. List anything LEFT UNRESOLVED that's worth following up on later: tasks/intentions the user mentioned, open questions, or a topic/story they started but didn't finish. Output JSON only. Don't invent; only genuine loose ends.
        Example: user said "tengo que llamar al dentista" and "te iba a contar de mi viaje pero…" → {"followUps":[{"text":"call the dentist","sources":[]},{"text":"hear about the user's trip","sources":[]}]}
        Schema: {"followUps":[{"text":"<short follow-up>","sources":["<entity label>"]}]}
        Conversation:
        \(convo)
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 512), FollowUpsOut.self) else { return }
        // Label-only resolution (like reflect): a source must match an existing node's label
        // by dedupKey; unresolvable labels are skipped.
        let allNodes = (try? store.allNodes()) ?? []
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            return allNodes.first { MemoryText.dedupKey($0.label) == key }
        }
        var existing = Set(allNodes.filter { $0.kind == NodeKind.followUp.rawValue }.map { MemoryText.dedupKey($0.body) })
        var added = 0
        for f in out.followUps {
            let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = MemoryText.dedupKey(text)
            if text.isEmpty || existing.contains(key) { continue }
            existing.insert(key)
            let t = now()
            var attrs = NodeAttributes(); attrs.status = "pending"
            let node = Node(id: UUID().uuidString, kind: NodeKind.followUp.rawValue, label: String(text.prefix(60)),
                            body: text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
            try? store.upsert(node)
            // Link the follow_up to each resolved source entity (mirrors reflect()'s source edges).
            for src in (f.sources ?? []).compactMap(resolve) where src.id != node.id {
                try? store.upsert(Edge(id: UUID().uuidString, srcId: node.id, dstId: src.id, relation: .relatedTo, weight: 1,
                                       confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            }
            added += 1
        }
        onProgress?("+\(added) follow-ups")
    }

    // MARK: REM — Associate

    private struct EdgesOut: Decodable { struct E: Decodable { let from: String; let relation: String; let to: String }; let edges: [E] }

    public func associate() async {
        let nodes = (try? store.allNodes().filter { $0.kind != NodeKind.conversation.rawValue }) ?? []
        guard nodes.count >= 2 else { return }
        let labels = nodes.prefix(60).map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
        let relations = Relation.allCases.map { $0.rawValue }.joined(separator: ", ")
        let prompt = """
        These memory entities are all facts about ONE person (the user). Propose meaningful relationships between them. Output JSON only.
        The `person` node is usually the user; connect the user to their preferences (likes/dislikes), places they work or go (locatedAt/worksWith), people they know (knows/worksWith/family), and link genuinely related items (relatedTo). Don't invent entities not listed.
        Use ONLY these relation types: \(relations).
        Example: entities `person: Ana`, `preference: pizza`, `place: office` → {"edges":[{"from":"Ana","relation":"likes","to":"pizza"},{"from":"Ana","relation":"locatedAt","to":"office"}]}
        Schema: {"edges":[{"from":"<entity label>","relation":"<one of the types>","to":"<entity label>"}]}
        Entities:
        \(labels)
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 512), EdgesOut.self) else { return }
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            if let n = nodes.first(where: { MemoryText.dedupKey($0.label) == key }) { return n }
            // 0.25 is intentionally looser than upsertMergingSemantic's 0.2 dedup default: linking
            // an edge endpoint tolerates more drift than merging two nodes into one.
            if let emb = (try? embedder?.embed(label)) ?? nil,
               let hit = (try? store.nearest(to: emb, k: 1))?.first, hit.distance <= 0.25 {
                return try? store.node(id: hit.id)
            }
            return nil
        }
        let existing = Set((try? store.allEdges())?.map { "\($0.srcId)|\($0.relation.rawValue)|\($0.dstId)" } ?? [])
        var added = 0
        for e in out.edges {
            guard let rel = Relation(rawValue: e.relation), let s = resolve(e.from), let d = resolve(e.to), s.id != d.id else { continue }
            let key = "\(s.id)|\(rel.rawValue)|\(d.id)"
            if existing.contains(key) { continue }
            let t = now()
            try? store.upsert(Edge(id: UUID().uuidString, srcId: s.id, dstId: d.id, relation: rel, weight: 1,
                                   confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            added += 1
        }
        onProgress?("+\(added) connections")
    }

    // MARK: Reflect — Abstract (grounded insights)
    private struct InsightsOut: Decodable { struct I: Decodable { let text: String; let sourceEntities: [String]; let confidence: String? }; let insights: [I] }

    public func reflect() async {
        let nodes = (try? store.allNodes().filter { $0.kind != NodeKind.conversation.rawValue && $0.kind != NodeKind.insight.rawValue }) ?? []
        guard nodes.count >= 2 else { return }
        let labels = nodes.prefix(60).map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
        let prompt = """
        These memories are all about ONE person (the user). Infer a few higher-level insights or patterns about them. Output JSON only.
        Each insight MUST be grounded in at least TWO of the listed entities (cite their exact labels in sourceEntities). Look for themes (e.g. shared interests, lifestyle, goals). Do not speculate beyond the evidence.
        Example: from `preference: sushi`, `preference: ramen` → {"insights":[{"text":"enjoys Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"}]}
        Schema: {"insights":[{"text":"...","sourceEntities":["label1","label2"],"confidence":"probable|maybe"}]}
        Memories:
        \(labels)
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 512), InsightsOut.self) else { return }
        // Label-only resolution by design: sources must be among the entities shown to the model
        // (unlike `associate`, which also falls back to semantic nearest-neighbor).
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            return nodes.first { MemoryText.dedupKey($0.label) == key }
        }
        // Dedup: runLight runs reflect() frequently over stable memory; without this guard,
        // each run would re-mint near-identical insight nodes with fresh UUIDs.
        var existingInsights = Set(((try? store.allNodes()) ?? []).filter { $0.kind == NodeKind.insight.rawValue }.map { MemoryText.dedupKey($0.body) })
        var added = 0
        for ins in out.insights {
            let sources = ins.sourceEntities.compactMap(resolve)
            if Set(sources.map { $0.id }).count < 2 { continue }   // anti-fabrication
            let key = MemoryText.dedupKey(ins.text)
            if existingInsights.contains(key) { continue }         // already have this insight
            existingInsights.insert(key)                            // collapse duplicates within this batch too
            let t = now()
            let conf = Confidence(rawValue: ins.confidence ?? "probable") ?? .probable
            let node = Node(id: UUID().uuidString, kind: NodeKind.insight.rawValue, label: String(ins.text.prefix(60)),
                            body: ins.text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: conf, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
            try? store.upsert(node)
            for s in sources {
                try? store.upsert(Edge(id: UUID().uuidString, srcId: node.id, dstId: s.id, relation: .relatedTo, weight: 1,
                                       confidence: conf, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            }
            added += 1
        }
        onProgress?("+\(added) insights")
    }

    // MARK: Compress — merge near-duplicate insights into one canonical node
    public func compress() async {
        let n = (try? store.compressInsights(embedder: embedder)) ?? 0
        if n > 0 { onProgress?("-\(n) duplicate insight\(n == 1 ? "" : "s")") }
    }

    // MARK: Clarify — ask the user when consolidation is genuinely unsure about event identity
    private struct ClarifyOut: Decodable { let questions: [String] }

    /// During reflection/sleep: if consolidation is unsure whether two memories are the same
    /// (a task rephrased/extended vs a genuinely new one), ask the USER instead of guessing.
    /// Emits pending `clarification` nodes (surfaced proactively in chat — Task 5). Never invents.
    public func clarify() async {
        let events = ((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.task.rawValue || $0.kind == NodeKind.plan.rawValue }
        guard events.count >= 2 else { return }
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
        guard let out = parse(await generate(prompt, maxTokens: 256), ClarifyOut.self) else { return }
        let existing = Set(((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.clarification.rawValue }.map { MemoryText.dedupKey($0.body) })
        var added = 0
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
            try? store.upsert(node); added += 1
        }
        if added > 0 { onProgress?("+\(added) question\(added == 1 ? "" : "s")") }
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

    public func curateKinds() async {
        let known = NodeKind.allCases.map { $0.rawValue }
        let kinds = (try? store.distinctKinds()) ?? []
        let unknown = kinds.filter { !known.contains($0) }
        guard !unknown.isEmpty else { return }
        let prompt = """
        Map each non-standard memory kind to the closest STANDARD kind, or keep it if it's genuinely distinct. Output JSON only.
        Standard kinds: \(known.joined(separator: ", ")). Schema: {"map":{"<kind>":"<standard-or-same>"}}
        Kinds to map: \(unknown.joined(separator: ", "))
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 512), KindMapOut.self) else { return }
        for (from, to) in out.map where from != to && !to.isEmpty {
            try? store.reassignKind(from: from, to: to)
        }
    }

    // MARK: SHY — Forget / downscale
    public func forget() async {
        try? store.sweep()
        try? store.pruneDanglingEdges()
    }

    // MARK: Cycle driver (resumable). `@escaping` to match the ConsolidationRunning protocol (Task 6).
    public func runCycle(isCancelled: @escaping () -> Bool, timeZone: TimeZone = .current) async {
        currentTimeZone = timeZone
        // Load or start a cycle.
        var state: SleepCycleState
        if let existing = (try? store.loadSleepCycle()) ?? nil {
            state = existing
        } else {
            let pending = ((try? transcriptStore.unconsolidated(limit: 200)) ?? [])
            let batch = pending.map { $0.id }
            guard !batch.isEmpty else { return }
            let texts0 = episodeTexts(ids: batch)
            let focus = String(texts0.joined(separator: " · ").prefix(100))
            state = SleepCycleState(phase: .nrem, episodeIds: batch, startedAt: now(), focus: focus)
            try? store.saveSleepCycle(state)
        }
        let order: [SleepPhase] = [.nrem, .summarize, .detect, .rem, .reflect, .compress, .clarify, .curate, .shy]
        guard let startIdx = order.firstIndex(of: state.phase) else { return }
        for phase in order[startIdx...] {
            if isCancelled() { return }   // leave persisted phase for resume
            switch phase {
            case .nrem:
                let texts = episodeTexts(ids: state.episodeIds)
                await consolidate(episodeTexts: texts)
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
            case .summarize:
                let rows = (try? transcriptStore.rows(ids: state.episodeIds)) ?? []
                // One summary per session (threadId). user+assistant of a turn share a turnIndex
                // by design, so a single-turn group yields turnRange i...i.
                let groups = Dictionary(grouping: rows, by: { $0.threadId })
                    .sorted { ($0.value.map(\.createdAt).min() ?? 0) < ($1.value.map(\.createdAt).min() ?? 0) }
                for (threadId, tRows) in groups {
                    let turns = tRows.map { $0.turnIndex }
                    let range = (turns.min() ?? 0)...(turns.max() ?? 0)
                    let texts = tRows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
                    await summarize(episodeTexts: texts, threadId: threadId, turnRange: range)
                }
            case .detect:
                await detectFollowUps(episodeTexts: episodeTexts(ids: state.episodeIds))
            case .rem: await associate()
            case .reflect: await reflect()
            case .compress: await compress()
            case .clarify: await clarify()
            case .curate: await curateKinds()
            case .shy: await forget()
            }
            // advance persisted phase (so resume skips this one)
            if let next = order.firstIndex(of: phase).map({ $0 + 1 }), next < order.count {
                state.phase = order[next]; try? store.saveSleepCycle(state)
            }
        }
        // Non-atomic by design: if the process dies after .shy advances but before this mark,
        // resume re-enters at .shy, re-runs the idempotent forget(), then marks — so episodes are
        // never lost, only a redundant forget() is paid.
        try? transcriptStore.markConsolidated(ids: state.episodeIds)
        try? store.clearSleepCycle()
        onProgress?("done")
    }

    /// Awake light reflection: summarize the current session promptly, then associate + reflect
    /// over current memory, no replay/curate/forget.
    public func runLight(isCancelled: @escaping () -> Bool, timeZone: TimeZone = .current) async {
        currentTimeZone = timeZone
        if isCancelled() { return }
        await summarizeRecent()
        if isCancelled() { return }
        await associate()
        if isCancelled() { return }
        await reflect()
        if isCancelled() { return }
        await clarify()
    }
}
