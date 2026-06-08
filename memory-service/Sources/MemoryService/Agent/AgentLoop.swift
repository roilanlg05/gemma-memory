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
    public func run(text: String, threadId: String, services: Services) async -> String {
        // The language rule ("reply in the same language the user is using") now lives in the
        // system prompt itself, so no per-turn append here. A firmer per-turn language hint derived
        // from the STT-detected language is a separate, planned change.
        let system = AgentPrompt.systemPrompt()
        let tail = AgentPrompt.recallTail(query: text, threadId: threadId, services: services)
        // Iteration 0: recall tail (nowContext + injected memory) prepended so the system-prompt
        // prefix stays byte-stable (mirrors app's Agent.run APC strategy).
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
