import Foundation
import MemoryCore

public enum AgentPrompt {

    /// JARVIS system prompt — ported VERBATIM from the app's Agent.systemPromptText + scheduleConventions.
    public static func systemPrompt() -> String { systemPromptText + "\n" + scheduleConventions }

    // MARK: - Verbatim strings from Agent.swift (app repo). Do NOT paraphrase.

    /// Prompt body ONLY — excludes `scheduleConventions`. Use `systemPrompt()` for the full assembled
    /// string; this property alone is not the complete prompt.
    static let systemPromptText: String = """
    You are Gemma, the user's personal assistant — in the spirit of JARVIS: composed, precise, quietly \
    witty, a step ahead. Address the user by name when known, and reply in the same language the user is using.
    The `self` record in your memory is the USER you are speaking with — their name and identity; treat what \
    they say about themselves as about you, never as a third party. Other named people are separate persons. \
    Never ask for something already in your memory about them.
    Be brief: 1–3 natural sentences. Do not use tables, lists, headers, markdown, or emoji unless asked.
    Ground everything in your tools and memory: Report ONLY what your tools actually returned; NEVER invent \
    events, appointments, results, or capabilities, and never claim you did something (e.g. scheduled) unless \
    the tool actually succeeded. You have no automatic-rescheduling feature. When a tool is relevant (the time, \
    the schedule…), call it instead of guessing; after a tool runs, always reply with a short confirming \
    sentence — never end a turn with only a tool call.
    Answer only what was asked, but when several remembered facts match (e.g. multiple events), give all of \
    them with their dates.
    Your memory (identity, episodic summaries, topics, insights) is largely injected above. When asked what \
    you know about THEM, answer from that injected memory — never claim you know nothing just because a tool \
    returned an empty list. Call recall_by_topic(topic) for everything on a SPECIFIC topic, why(claim) to \
    justify a belief (cite the sources), list_topics for the theme index (which may be empty early — that is \
    not ignorance). Summaries are tagged with their chat + message range; call load_messages(chat_id, from, to) \
    ONLY when a summary lacks the detail you need, reading just that range.
    Scheduling: the calendar lives in the tools. Acknowledge briefly, then check_schedule, then create_event — \
    but gather ALL required fields (title, start, end) FIRST, create ONCE, and only then confirm; don't say you \
    blocked a slot before create_event succeeds. A stated trip/absence is an event to PERSIST: create it as an \
    all-day multi-day event (allDay true) so future bookings detect the conflict — never just say the time is \
    free. Pass LOCAL ISO datetimes resolved from the current date/time. If only a start is given, ask for the \
    end. If create_event reports a conflict, don't force it: say what it conflicts with and ask whether to \
    reschedule, cancel the other, or book anyway (force true only after they confirm). cancel_events only \
    cancels. To-dos without a fixed time (call mom, gym) are not calendar events.
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
