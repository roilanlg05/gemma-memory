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
            // Pre-filter: discard transcription artifacts that are NEVER worth sending to the LLM.
            // These are produced by Whisper when it hears noise, silence, or background room sounds.
            let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let noisePatterns = [
                "\\[.*?\\]",    // [sniffs], [typing], [clears throat], [silence], [music], etc.
                "\\(.*?\\)",    // (sighs), (coughs), etc.
            ]
            var cleaned = lower
            for pattern in noisePatterns {
                cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty after cleaning → pure noise, skip LLM entirely.
            if cleaned.isEmpty { return "" }
            // Very short interjections that are clearly not directed to Gemma (ok, mhm, yeah, sí, no, etc.)
            let shortInterjections: Set<String> = [
                "ok", "okay", "mhm", "mm", "mmm", "uh", "uhh", "um", "umm", "ah", "ahh",
                "yeah", "yes", "no", "sí", "si", "nope", "sure", "right", "got it",
                "alright", "fine", "cool", "wow", "oh", "hmm", "hm", "er"
            ]
            if shortInterjections.contains(cleaned) { return "" }

            let passiveSystemPrompt = """
            You are a SILENT passive observer. The user's microphone picks up everything in the room.
            You hear background conversations and ambient sounds, but you NEVER respond to them.

            The transcribed audio is: "\(text)"

            Your default action is ALWAYS silence. You reply with the SINGLE WORD "IGNORE" unless ALL of the following are true simultaneously:
            1. Someone is giving the user FACTUALLY INCORRECT information that could cause real harm or significant confusion.
            2. There is an immediate safety emergency or security threat the user must know about RIGHT NOW.
            3. You have a single, critically important fact the user urgently needs in THIS exact moment.

            ALWAYS respond with "IGNORE" for:
            - Normal chit-chat, casual conversation between people
            - Questions between other people that don't require your expertise
            - Background TV, radio, music, or media content
            - Affirmations, acknowledgments, or conversational filler
            - Anything where staying quiet is equally or more appropriate
            - If you are even slightly uncertain whether to intervene

            Respond with ONLY "IGNORE" or a single short sentence of intervention. Nothing else.
            """

            do {
                let classification = try await client.complete(
                    systemPrompt: passiveSystemPrompt,
                    userPrompt: "Analyze and decide: IGNORE or intervene?",
                    tools: []
                )
                let result = classification.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.uppercased().hasPrefix("IGNORE") || result.isEmpty { return "" }
                return result
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
