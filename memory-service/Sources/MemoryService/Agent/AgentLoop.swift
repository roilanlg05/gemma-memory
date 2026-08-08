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
            let passiveSystemPrompt = """
            You are a silent, passive AI assistant listening to background conversation around your user.
            The user is NOT talking to you unless they explicitly ask you or mention your name, or unless it's a critical moment.
            
            Read the background text:
            "\(text)"
            
            Determine if you should intervene. You MUST remain silent (reply with "IGNORE") unless:
            1. There is an immediate safety/security hazard or warning you must give.
            2. Someone is giving the user incorrect/misleading information about a fact you know.
            3. You have a highly relevant, crucial piece of information or fact that would immediately help the user in this exact moment.
            
            If none of these apply, or if it is a normal/casual conversation, or nonsense/silence, reply with exactly the word:
            IGNORE
            
            Otherwise, if you MUST intervene, reply with the short, natural sentence you want to say to help or warn the user.
            """
            
            do {
                let classification = try await client.complete(
                    systemPrompt: passiveSystemPrompt,
                    userPrompt: "Analyze the conversation.",
                    tools: []
                )
                let cleaned = classification.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.uppercased().contains("IGNORE") {
                    return ""
                }
                return cleaned
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
