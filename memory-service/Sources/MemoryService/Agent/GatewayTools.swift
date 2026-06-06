import Foundation
import MemoryCore

// MARK: - ISO→epoch helper (mirrors app's ScheduleTime.epoch(fromISO:))

/// Parse a LOCAL ISO-8601 date/datetime string into epoch seconds, using the system timezone.
/// Supports "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd".
/// Returns nil on bad input.
private func isoToEpoch(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    // `.current` = the container's TZ (set to America/Havana in compose). Per-request timezone
    // threading is a deferred follow-up for multi-zone clients; today it must match nowContext's zone.
    f.timeZone = .current
    for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
        f.dateFormat = fmt
        if let d = f.date(from: t) { return d.timeIntervalSince1970 }
    }
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: t)?.timeIntervalSince1970
}

/// Human-readable epoch → "EEE yyyy-MM-dd HH:mm" in local time.
private func epochToHuman(_ e: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "EEE yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: e))
}

/// Human suffix for a schedule event status.
private func statusSuffix(_ status: String?) -> String {
    switch status {
    case "cancelled": return " (cancelado)"
    case "done": return " (hecho)"
    default: return ""
    }
}

/// Format a schedule event node as a one-line string.
private func eventLine(_ n: Node) -> String {
    let a = NodeAttributes.from(n.extra)
    let loc = (a.location?.isEmpty == false) ? " @ \(a.location!)" : ""
    return "\(n.label): \(epochToHuman(a.startAt ?? 0))–\(epochToHuman(a.endAt ?? 0))\(loc)\(statusSuffix(a.status))"
}

// MARK: - 1. CurrentTimeGatewayTool

public struct CurrentTimeGatewayTool: GatewayTool {
    public static let name = "get_current_time"
    public static let description = "Returns the user's current local date and time. Call this whenever the user asks what time or date it is."
    public static let parameters: [GatewayToolParam] = []
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: Date())
    }
}

// MARK: - 2. SaveMemoryGatewayTool

public struct SaveMemoryGatewayTool: GatewayTool {
    public static let name = "save_memory"
    public static let description = """
    Save a durable fact the USER stated about THEMSELVES (a preference, a person, a place, or a \
    personal fact). Only call this for things the user affirmed about themselves — NEVER for a \
    question they asked, NEVER for facts about you/the assistant or the current time, and NEVER \
    guess. Use a short canonical `entity` (e.g. "sushi", "Juan", "Madrid"), not a sentence.
    """
    public static let parameters: [GatewayToolParam] = [
        .init(name: "entity", type: .string,
              description: "Short canonical noun/name to remember, e.g. \"sushi\", \"Juan\". Not a sentence.",
              required: true),
        .init(name: "detail", type: .string,
              description: "Optional free context, e.g. \"likes it a lot\", \"friend, works with the user\".",
              required: false),
        .init(name: "kind", type: .string,
              description: "One of: self (the user's own name/identity), person, place, preference, fact.",
              required: false),
        .init(name: "permanent", type: .boolean,
              description: "true if this is permanent identity (name, lifelong facts).",
              required: false),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let obj = Self.args(argsJSON)
        let rawEntity = ((obj["entity"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawEntity.isEmpty else { return "nothing to save" }
        let detail = (obj["detail"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kindRaw = ((obj["kind"] as? String) ?? "fact")
        let permanent = (obj["permanent"] as? Bool) ?? false
        let kind = kindRaw.isEmpty ? "fact" : kindRaw
        let body = detail.flatMap { $0.isEmpty ? nil : $0 } ?? rawEntity
        let extra: String? = permanent ? #"{"permanent":true}"# : nil

        // Route: kind=="self" → upsertSelf (singleton); else → upsertMergingSemantic.
        if kind == "self" {
            do {
                _ = try services.store.upsertSelf(name: rawEntity, detail: body, embedder: services.embedder)
                return "Saved: \(rawEntity)"
            } catch { return "memory error: \(error)" }
        }

        let now = Date().timeIntervalSince1970
        let layer: MemoryLayer = kind == "identity" ? .identity : .daily
        let candidate = Node(
            id: UUID().uuidString, kind: kind, label: rawEntity, body: body, layer: layer,
            createdAt: now, updatedAt: now, lastSeenAt: now,
            salience: layer == .identity ? 8 : 3,
            decayRate: Decay.defaultDecayRate(for: layer),
            confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
            sourceRef: nil, origin: .explicit, serverId: nil,
            dirty: true, deleted: false, extra: extra
        )
        let embedding: [Float]? = try? services.embedder.embed(rawEntity)
        do {
            _ = try services.store.upsertMergingSemantic(candidate, embedding: embedding, embedder: services.embedder)
            return "Saved: \(rawEntity)"
        } catch { return "memory error: \(error)" }
    }
}

// MARK: - 3. ForgetGatewayTool

public struct ForgetGatewayTool: GatewayTool {
    public static let name = "forget"
    public static let description = "Forget previously remembered facts that match the given keywords."
    public static let parameters: [GatewayToolParam] = [
        .init(name: "query", type: .string,
              description: "Keywords describing what to forget.",
              required: true),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let obj = Self.args(argsJSON)
        let query = ((obj["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "nothing to forget" }
        do {
            let removed = try services.store.forgetByLabel(query)
            return "Forgot \(removed) item(s)."
        } catch { return "memory error: \(error)" }
    }
}

// MARK: - 4. LoadMessagesGatewayTool

public struct LoadMessagesGatewayTool: GatewayTool {
    public static let name = "load_messages"
    public static let description = """
    Load the exact past messages behind an episodic summary, ONLY when a summary doesn't contain \
    the detail you need. Pass the summary's chat_id and the message range (from/to) shown next to it. \
    Read just that range — never a whole chat.
    """
    public static let parameters: [GatewayToolParam] = [
        .init(name: "chat_id", type: .string,
              description: "The chat id shown with the summary, e.g. \"g7y\".",
              required: true),
        .init(name: "from", type: .integer,
              description: "First message number (seq) of the range.",
              required: true),
        .init(name: "to", type: .integer,
              description: "Last message number (seq); omit for a single message.",
              required: false),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let obj = Self.args(argsJSON)
        let chatId = ((obj["chat_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let from = (obj["from"] as? Int)
            ?? (obj["from"] as? Double).map(Int.init)
            ?? (obj["from"] as? String).flatMap { Int($0) }
            ?? 0
        let to = (obj["to"] as? Int)
            ?? (obj["to"] as? Double).map(Int.init)
            ?? (obj["to"] as? String).flatMap { Int($0) }
        guard !chatId.isEmpty, from > 0 else { return "need chat_id and from" }
        // Cap the DB query at 80 rows (mirrors /v1/transcript/range so the gateway can't issue an
        // unbounded fetch when the model passes a large `to`).
        let toRaw = to ?? from
        let cappedTo = min(toRaw, from + 79)
        let truncated = toRaw > cappedTo
        do {
            let rows = try services.transcript.range(threadId: chatId, from: from, to: cappedTo)
            guard !rows.isEmpty else {
                return "no messages found for chat \(chatId) range \(from)-\(cappedTo)"
            }
            let lines = rows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
            let body = lines.joined(separator: "\n")
            let result = truncated ? body + "\n…(truncated — narrow the range for more)" : body
            return String(result.prefix(4000))
        } catch { return "no messages found for chat \(chatId)" }
    }
}

// MARK: - 5. ListTopicsGatewayTool

public struct ListTopicsGatewayTool: GatewayTool {
    public static let name = "list_topics"
    public static let description = "List the topics/themes you have memories about (e.g. when the user asks what you know about them). No arguments."
    public static let parameters: [GatewayToolParam] = []
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let tags = (try? services.store.distinctTags()) ?? []
        guard !tags.isEmpty else { return "no topics yet" }
        return String(("Topics: " + tags.joined(separator: ", ")).prefix(2000))
    }
}

// MARK: - 6. RecallByTopicGatewayTool

public struct RecallByTopicGatewayTool: GatewayTool {
    public static let name = "recall_by_topic"
    public static let description = """
    Return EVERYTHING you remember about one topic/theme (e.g. "finanzas", "trabajo", "salud"), \
    not just what you already see. Use it when the user asks for all you know about a subject.
    """
    public static let parameters: [GatewayToolParam] = [
        .init(name: "topic", type: .string,
              description: "The topic/theme to enumerate, e.g. \"finanzas\".",
              required: true),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let topic = ((Self.args(argsJSON)["topic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return "need a topic" }
        // Resolve the canonical tag first so we can echo it ("About <tag>:") like the app — this
        // grounds the model when the resolved tag differs from what it asked (e.g. "finanzas"→"finance").
        guard let tag = MemoryQueries.resolveTag(topic, store: services.store, embedder: services.embedder) else {
            return "nothing remembered about \"\(topic)\""
        }
        let nodes = MemoryQueries.nodesForTag(tag, store: services.store, limit: 100)
        guard !nodes.isEmpty else { return "nothing remembered about \"\(topic)\"" }
        let lines = nodes.map { "- [\($0.kind)] \($0.label): \($0.body.isEmpty ? $0.label : $0.body)" }
        return String(("About \(tag):\n" + lines.joined(separator: "\n")).prefix(4000))
    }
}

// MARK: - 7. WhyGatewayTool

public struct WhyGatewayTool: GatewayTool {
    public static let name = "why"
    public static let description = """
    Explain WHY you believe something about the user, by tracing it to the source memories. \
    Use it when the user asks why you think that or what you're basing it on. Pass the belief/claim. \
    Cite the sources it returns; don't invent a justification.
    """
    public static let parameters: [GatewayToolParam] = [
        .init(name: "claim", type: .string,
              description: "The belief/claim to justify, e.g. \"the user trades options\".",
              required: true),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let claim = ((Self.args(argsJSON)["claim"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claim.isEmpty else { return "need a claim" }
        let result = MemoryQueries.why(claim, store: services.store, embedder: services.embedder)
        guard let ins = result.insight else { return "I can't trace that to a specific memory" }
        guard !result.sources.isEmpty else { return "I believe \"\(ins.body)\" but have no recorded sources" }
        let src = result.sources.map { $0.label }.joined(separator: ", ")
        return String("I believe \"\(ins.body)\" because of: \(src)".prefix(2000))
    }
}

// MARK: - 8. CheckScheduleGatewayTool

public struct CheckScheduleGatewayTool: GatewayTool {
    public static let name = "check_schedule"
    public static let description = "Check whether a time slot conflicts with existing events. Call BEFORE creating an event. Pass local ISO datetimes like 2026-06-09T08:00."
    public static let parameters: [GatewayToolParam] = [
        .init(name: "start", type: .string,
              description: "Local ISO datetime, e.g. 2026-06-09T08:00",
              required: true),
        .init(name: "end", type: .string,
              description: "Local ISO datetime; the end of the slot.",
              required: true),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let o = Self.args(argsJSON)
        guard let s = (o["start"] as? String).flatMap(isoToEpoch),
              let e = (o["end"] as? String).flatMap(isoToEpoch) else {
            return "I need a start and end time (e.g. 2026-06-09T08:00)."
        }
        do {
            let conflicts = try services.store.scheduleConflicts(start: s, end: e)
            return conflicts.isEmpty ? "No conflicts." : "Conflicts: " + conflicts.map(eventLine).joined(separator: "; ")
        } catch { return "schedule error: \(error)" }
    }
}

// MARK: - 9. CreateEventGatewayTool

public struct CreateEventGatewayTool: GatewayTool {
    public static let name = "create_event"
    public static let description = "Create a calendar event (meeting/appointment/trip). Pass local ISO datetimes. If it conflicts with an existing event, it will NOT be created unless force=true — tell the user about the conflict and ask before forcing."
    public static let parameters: [GatewayToolParam] = [
        .init(name: "title", type: .string,
              description: "Short event title, e.g. \"dentist\", \"Miami meeting\".",
              required: true),
        .init(name: "start", type: .string,
              description: "Local ISO datetime, e.g. 2026-06-09T08:00.",
              required: true),
        .init(name: "end", type: .string,
              description: "Local ISO datetime end. If the user gave only a start, ASK for the end first.",
              required: true),
        .init(name: "allDay", type: .boolean,
              description: "true for all-day/multi-day (e.g. trips).",
              required: false),
        .init(name: "location", type: .string,
              description: "Place only (city/venue), not prose.",
              required: false),
        .init(name: "force", type: .boolean,
              description: "true to book despite a conflict (only after the user confirms).",
              required: false),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let o = Self.args(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              let s = (o["start"] as? String).flatMap(isoToEpoch),
              let e = (o["end"] as? String).flatMap(isoToEpoch) else {
            return "I need a title, start, and end (e.g. 2026-06-09T08:00). If you only gave a start, what's the end time?"
        }
        let allDay = (o["allDay"] as? Bool) ?? false
        let location = (o["location"] as? String)?.trimmingCharacters(in: .whitespaces)
        let force = (o["force"] as? Bool) ?? false
        do {
            let result = try services.store.createEventChecked(
                title: title, start: s, end: e, allDay: allDay,
                location: (location?.isEmpty == false) ? location : nil,
                origin: .explicit, force: force
            )
            if result.id != nil {
                return "Scheduled: \(title) (\(epochToHuman(s)))"
            }
            return "NOT scheduled — conflicts with: "
                + result.conflicts.map(eventLine).joined(separator: "; ")
                + ". Ask the user whether to reschedule, cancel the other event, or book it anyway — if they confirm, call create_event again with force=true."
        } catch { return "schedule error: \(error)" }
    }
}

// MARK: - 10. QueryScheduleGatewayTool

public struct QueryScheduleGatewayTool: GatewayTool {
    public static let name = "query_schedule"
    public static let description = "List the user's events between two local ISO datetimes (use this for \"what's on my schedule this week\"). Pass dates like 2026-06-09 or 2026-06-09T00:00."
    public static let parameters: [GatewayToolParam] = [
        .init(name: "from", type: .string,
              description: "Local ISO datetime/date for the window start.",
              required: true),
        .init(name: "to", type: .string,
              description: "Local ISO datetime/date for the window end.",
              required: true),
        .init(name: "includeCancelled", type: .boolean,
              description: "true to also list cancelled/past events (shown marked '(cancelado)'). Default false — the normal agenda excludes them.",
              required: false),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let o = Self.args(argsJSON)
        guard let f = (o["from"] as? String).flatMap(isoToEpoch),
              let t = (o["to"] as? String).flatMap(isoToEpoch) else {
            return "I need a from/to range (e.g. 2026-06-09 to 2026-06-16)."
        }
        let includeCancelled = (o["includeCancelled"] as? Bool) ?? false
        do {
            let events = try services.store.scheduleWindow(from: f, to: t, includeCancelled: includeCancelled)
            return events.isEmpty ? "Nothing scheduled in that range." : events.map(eventLine).joined(separator: "; ")
        } catch { return "schedule error: \(error)" }
    }
}

// MARK: - 11. CancelEventsGatewayTool

public struct CancelEventsGatewayTool: GatewayTool {
    public static let name = "cancel_events"
    public static let description = "Cancel the user's events in a local ISO datetime range (e.g. \"cancel my appointments this week\"). Events are kept (cancelled), not deleted."
    public static let parameters: [GatewayToolParam] = [
        .init(name: "from", type: .string,
              description: "Local ISO datetime/date window start.",
              required: true),
        .init(name: "to", type: .string,
              description: "Local ISO datetime/date window end.",
              required: true),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let o = Self.args(argsJSON)
        guard let f = (o["from"] as? String).flatMap(isoToEpoch),
              let t = (o["to"] as? String).flatMap(isoToEpoch) else {
            return "I need a from/to range to cancel."
        }
        do {
            let n = try services.store.cancelEvents(ids: nil, from: f, to: t)
            return "Cancelled \(n) event(s)."
        } catch { return "schedule error: \(error)" }
    }
}

// MARK: - Registry

/// All 11 gateway tools, registered for use by the agent loop.
public enum GatewayToolRegistry {
    public static let gatewayTools: [any GatewayTool] = [
        CurrentTimeGatewayTool(),
        SaveMemoryGatewayTool(),
        ForgetGatewayTool(),
        LoadMessagesGatewayTool(),
        ListTopicsGatewayTool(),
        RecallByTopicGatewayTool(),
        WhyGatewayTool(),
        CheckScheduleGatewayTool(),
        CreateEventGatewayTool(),
        QueryScheduleGatewayTool(),
        CancelEventsGatewayTool(),
    ]

    /// OpenAI-style tool specs for all tools (pass directly to the model's `tools` array).
    /// Derived from `gatewayTools` (single source of truth) so the two can never diverge.
    public static let gatewayToolSpecs: [[String: Any]] = gatewayTools.map { type(of: $0).functionSpec }

    /// Look up a tool by its registered name (for the agent loop's dispatch).
    public static func tool(named n: String) -> (any GatewayTool)? {
        gatewayTools.first { type(of: $0).name == n }
    }
}
