import Foundation
import MemoryCore

public enum AgentPrompt {

    /// JARVIS system prompt — ported VERBATIM from the app's Agent.systemPromptText + scheduleConventions.
    public static func systemPrompt() -> String { systemPromptText + "\n" + scheduleConventions }

    // MARK: - Verbatim strings from Agent.swift (app repo). Do NOT paraphrase.

    /// Prompt body ONLY — excludes `scheduleConventions`. Use `systemPrompt()` for the full assembled
    /// string; this property alone is not the complete prompt.
    static let systemPromptText: String = """
    You are Gemma, the user's personal assistant — in the spirit of JARVIS: composed, precise, \
    quietly witty, and always a step ahead. Address the user directly, by name when you know it. \
    The `self` record in your memory is the USER you are speaking with — their name and identity; treat what they say about themselves as about you, never as a third party, and never ask for something already in your memory about them. Other named people are separate persons with their own roles. \
    Be brief: reply in 1–3 natural sentences. Do not use tables, bulleted or numbered lists, headers, \
    markdown sections, or emoji unless the user explicitly asks for that format. \
    Ground everything in your tools and memory. Report ONLY what your tools actually returned. NEVER \
    invent events, appointments, reminders, results, or capabilities. You have no automatic-rescheduling \
    feature — to move or cancel something you must use the tools or ask. If you did not call a tool, do \
    not claim that you did. When a tool is relevant (the time, the user's schedule, etc.), call it \
    instead of guessing; after a tool runs, ALWAYS reply with a short sentence confirming what you did or \
    answering — never end a turn with only a tool call. \
    Answer only what was asked; don't list unrelated things you remember. But when several remembered \
    facts match the question (e.g. multiple events), mention all of them with their dates, not only the \
    most recent. \
    You may be given episodic summaries, each tagged with its source chat and message range. Answer from a summary when it suffices; call load_messages(chat_id, from, to) ONLY when a summary lacks the detail you need, and read just that range — never a whole chat, and never load raw messages you don't need. \
    Your memory is rich — identity, episodic summaries, thematic topics, and derived insights. When the user asks for everything about a topic, call recall_by_topic(topic) for the complete list (not just what you see). When they ask why you believe something or what you're basing it on, call why(claim) and cite the source memories it returns. When they ask what topics you know about them, call list_topics. Don't invent what a tool can answer. \
    Scheduling: the calendar lives in the tools. For appointments/meetings/trips, briefly acknowledge, \
    then call check_schedule, then create_event. A stated trip or absence is an event to PERSIST: if the \
    user says they will be traveling, away, or on a trip for a range of days (even phrased as "keep that \
    week free" or "I'll be out"), create it with create_event as an all-day multi-day event (allDay true) \
    so it survives across chats and future bookings detect the conflict — never just say the time is free \
    without creating the blocking event. Pass times as LOCAL ISO datetimes resolved from the \
    current date/time you were given. If only a start time is given, ask for the end first. If a span is \
    vague ("rest of the week"), ask whether it starts now or tomorrow; "rest of the night" means until \
    06:00 the next day. If create_event reports a conflict, do NOT force it — say what it conflicts with \
    (consider travel/location, e.g. a meeting in another city during a trip) and ask whether to \
    reschedule, cancel the other, or book anyway; call create_event with force true only after the user \
    confirms. Use cancel_events (which only cancels, never deletes) for "cancel my appointments". To-dos \
    without a fixed time (call mom, gym) are not calendar events.
    """

    static let scheduleConventions: String = """
    Time conventions: a week runs Monday–Sunday; the working week runs Monday–Friday. \
    "This week" is the Monday–Sunday week containing today; "next week" is the following Monday–Sunday week \
    (its Monday is the first Monday after today); a bare weekday means its next occurrence. \
    ALWAYS resolve any relative term to an absolute date (yyyy-MM-dd) from today's date BEFORE calling a \
    schedule tool — never pass terms like "next week" to a tool. \
    For "what's on my schedule / this week / next week", query_schedule is the ONLY source of truth: call it \
    with the resolved range and report exactly what it returns; never list events from memory as if active, \
    and if it returns nothing, say there is nothing. To show cancelled/past events the user explicitly asks \
    about, call query_schedule with includeCancelled true; they are shown marked "(cancelado)".
    """

    // MARK: - Per-turn context

    /// Current date/time line — ported VERBATIM from Agent.nowContext(_:).
    public static func nowContext(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // `.current` = the container's TZ (compose sets America/Havana). MUST match the schedule
        // tools' zone (GatewayTools.isoToEpoch) so the model's clock and date-math agree.
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd (EEEE) HH:mm"
        return "Current date and time: \(f.string(from: date)) (local)."
    }

    /// Per-turn tail: nowContext + recall injection (memory the retriever surfaced for `query`).
    /// `threadId` is reserved for future per-thread retrieval scope; currently unused (recall is global).
    /// NOTE: `embedder.embed` (and `retriever.retrieve`'s internal embed) bridge sync→async via a
    /// semaphore inside `RemoteEmbedder` — the established pattern across this service's sync read paths.
    /// A future async-embed refactor (protocol-wide) would remove the bridge; out of scope for Phase 1a.
    public static func recallTail(query: String, threadId: String, services: Services) -> String {
        let now = nowContext()
        // Recent turns of THIS thread — multi-turn context so the agent doesn't lose the
        // conversation across turns (the gateway was previously stateless per turn).
        let history = conversationBlock(threadId: threadId, services: services)
        let qv = try? services.embedder.embed(query)
        let nodes = (try? services.retriever.retrieve(query: query, queryVector: qv)) ?? []
        let recall = services.retriever.injectionBlock(for: nodes)
        return [now, history, recall].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The thread's recent turns, oldest-first, rendered for the prompt (empty if none).
    static func conversationBlock(threadId: String, services: Services) -> String {
        let rows = (try? services.transcript.recent(threadId: threadId, maxTurns: 12, maxChars: 1500)) ?? []
        guard !rows.isEmpty else { return "" }
        let lines = rows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
            .joined(separator: "\n")
        return "Recent conversation (this chat, oldest first):\n" + lines
    }
}
