import Foundation
import MemoryCore

/// Non-streamed agentic loop: recall → call model → execute tool calls → re-feed → final reply.
/// Mirrors the app's `Agent.run` tool-loop logic (prompt augmentation, max-iteration cap, error
/// fallback), adapted for the gateway's server-side tool set.
public struct AgentLoop {
    /// Non-answer replies the loop emits on failure. The endpoint skips persisting these as assistant
    /// turns so apologies/placeholders don't pollute recall + consolidation.
    public static let modelUnreachableReply = "I can't reach my model right now."
    public static let incompleteReply = "(no pude completar la respuesta)"
    public static let fallbackReplies: Set<String> = [modelUnreachableReply, incompleteReply]

    let client: AgentModelClient
    let maxIterations: Int

    public init(client: AgentModelClient, maxIterations: Int = 5) {
        self.client = client
        self.maxIterations = maxIterations
    }

    /// Run one agentic turn (non-streamed): returns the model's final reply text.
    /// - Parameters:
    ///   - text:     The user's message for this turn.
    ///   - threadId: The conversation thread identifier (scopes recall / episodic context).
    ///   - services: Process-wide service container (store, embedder, retriever, …).
    ///   - language: Optional STT-detected language code (e.g. "en"/"es"). When present, a firm
    ///               "Reply in <Language>." directive rides the per-turn tail to pin the reply
    ///               language to what the user actually spoke (the prompt's general rule alone
    ///               sometimes flips EN↔ES on voice turns).
    public func run(text: String, threadId: String, services: Services, language: String? = nil, isPassive: Bool = false) async -> String {
        if isPassive {
            // ── Tier 1: Pure noise artifacts ─────────────────────────────────────────────
            // Whisper emits bracketed labels ([sniffs], [silence], [typing], [Music], etc.)
            // when it hears non-speech sounds. Strip them and see if any real words remain.
            // If nothing is left, this is pure noise — discard entirely (no memory, no LLM).
            var cleaned = text
            // Remove [bracket] and (paren) noise markers produced by Whisper
            cleaned = cleaned.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "\\([^\\)]*\\)", with: "", options: .regularExpression)
            // Collapse whitespace
            cleaned = cleaned.components(separatedBy: .whitespacesAndNewlines)
                             .filter { !$0.isEmpty }.joined(separator: " ")
            // Discard if nothing real remains — pure noise/silence, skip everything
            if cleaned.isEmpty { return "" }

            // ── Tier 2: Passive ambient gate ─────────────────────────────────────────────
            // Real words were spoken (by anyone in the room). The user turn WILL be stored
            // in the transcript by the handler for ambient context — Gemma learns what's
            // happening around the user. Now decide if a vocal response is warranted.
            // The bar is extremely high: Gemma behaves like a smart friend in the room —
            // fully aware, almost always silent, only speaks when it truly matters.
            let passiveSystemPrompt = """
            You are Gemma, a personal AI assistant. Right now you are in passive listening mode.
            You can hear everything in the room via the microphone, but you are NOT being spoken to.
            
            Transcribed ambient audio: "\(text)"
            
            Your role is like a brilliant, discreet friend sitting nearby:
            - You absorb everything happening around the user as context.
            - You NEVER comment on normal conversations, even interesting ones.
            - You NEVER volunteer opinions, suggestions, or information unprompted.
            - You stay completely silent unless a very specific critical threshold is met.
            
            You MAY speak ONLY if the following condition is clearly true:
            • Someone near the user is stating something FACTUALLY INCORRECT that could cause the user real harm, financial loss, health risk, or significant confusion — AND you know the correct fact.
            • There is an immediate safety or security threat that the user needs to know about RIGHT NOW.
            
            You MUST stay silent (set intervene to false) for ALL of the following:
            • Normal conversation between people, even if interesting or related to you
            • Casual discussion, opinions, small talk, jokes, stories
            • Questions that aren't addressed to you
            • Background TV, radio, music, podcasts
            • Someone speaking to someone else (not the user)
            • Anything where staying quiet is equally valid
            • When in doubt
            
            Respond with JSON only. If you decide to intervene, set intervene to true and reply with ONE short natural sentence in 'reply'. Otherwise, set intervene to false and leave 'reply' empty.
            
            Schema: {"intervene": false, "reply": ""}
            """

            do {
                let gate = try await client.complete(
                    systemPrompt: passiveSystemPrompt,
                    userPrompt: "Output JSON deciding whether to intervene or not.",
                    tools: []
                )
                let cleanedText = gate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                struct PassiveDecision: Decodable {
                    let intervene: Bool
                    let reply: String?
                }
                
                // Helper to extract JSON from raw response block
                func extractJSON(_ s: String) -> String? {
                    guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
                    return String(s[a...b])
                }
                
                if let jsonStr = extractJSON(cleanedText),
                   let jsonData = jsonStr.data(using: .utf8),
                   let decision = try? JSONDecoder().decode(PassiveDecision.self, from: jsonData) {
                    if decision.intervene, let reply = decision.reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return ""
            } catch {
                return ""
            }
        }

        // The general language rule ("reply in the same language the user is using") lives in the
        // system prompt. The per-turn directive below (from the STT-detected language) is firmer and
        // rides the tail so the system prefix stays byte-stable (mirrors app's APC strategy).
        let system = AgentPrompt.systemPrompt()
        var tail = AgentPrompt.recallTail(query: text, threadId: threadId, services: services)
        let langDir = AgentPrompt.languageDirective(language)
        if !langDir.isEmpty { tail = tail.isEmpty ? langDir : tail + "\n\n" + langDir }
        // Iteration 0: recall tail (nowContext + recent turns + injected memory + language) prepended
        var currentPrompt = tail.isEmpty ? text : tail + "\n\n" + text
        let specs = GatewayToolRegistry.gatewayToolSpecs
        var lastText = ""

        for iteration in 0..<maxIterations {
            let result: AgentModelResult
            do {
                result = try await client.complete(
                    systemPrompt: system,
                    userPrompt: currentPrompt,
                    tools: specs
                )
            } catch {
                return Self.modelUnreachableReply
            }

            lastText = result.text

            // No tool calls → final answer.
            if result.toolCalls.isEmpty { return result.text }

            // Execute every pending tool call and augment the prompt — mirrors the app's loop over
            // `pendingToolCalls` in Agent.run (all calls in one iteration before the next model call).
            for tc in result.toolCalls {
                let out: String
                if let tool = GatewayToolRegistry.tool(named: tc.name) {
                    out = await tool.run(argsJSON: tc.args, services: services)
                } else {
                    out = "error: no tool named \(tc.name)"
                }
                // Augmentation note — verbatim from app's Agent.run (Agent.swift line ~170).
                currentPrompt += "\n\n[You called the tool `\(tc.name)` with arguments \(tc.args); it returned: \(out). Now reply to the user in a short natural sentence using this result.]"
            }

            // Safety cap: hit the ceiling while still getting tool calls — return whatever we have.
            // `lastText` here is the INTERMEDIATE text from this same tool-using turn (the model's
            // pre-final chatter), not a true final answer — the model never got a turn to conclude.
            if iteration == maxIterations - 1 {
                return lastText.isEmpty ? Self.incompleteReply : lastText
            }
        }

        return lastText
    }
}
