import Foundation
import MemoryCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AgentToolCall: Sendable, Equatable {
    public let name: String
    public let args: String
}

public struct AgentModelResult: Sendable {
    public let text: String
    public let toolCalls: [AgentToolCall]
}

/// Model client that can request tools (non-streamed OpenAI chat/completions). Mirrors the app's
/// ServerRuntime tool-calling, server-side. Reuses ModelConfigStore (same config the consolidation
/// client uses). `tools` are already-built OpenAI function specs.
public protocol AgentModelClient: Sendable {
    // TODO: Swift 6 / strict-concurrency — replace [[String:Any]] with a Sendable tool-spec type.
    func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult
}

public struct ToolCallingClient: AgentModelClient {
    let configStore: ModelConfigStore?
    let defaultBaseURL: URL
    let defaultModel: String
    let session: URLSession
    let timeout: TimeInterval

    public init(configStore: ModelConfigStore?, defaultBaseURL: URL,
                defaultModel: String = "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
                session: URLSession = .shared, timeout: TimeInterval = 120) {
        self.configStore = configStore
        self.defaultBaseURL = defaultBaseURL
        self.defaultModel = defaultModel
        self.session = session
        self.timeout = timeout
    }

    private func resolve() -> (baseURL: URL, model: String, apiKey: String?, isLocal: Bool) {
        if let c = try? configStore?.load() ?? nil, let url = URL(string: c.baseURL) {
            return (url, c.model, c.apiKey, c.provider == "local")
        }
        return (defaultBaseURL, defaultModel, nil, true)
    }

    public func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
        let r = resolve()
        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty { messages.append(["role": "system", "content": systemPrompt]) }
        messages.append(["role": "user", "content": userPrompt])

        var body: [String: Any] = [
            "model": r.model,
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.3,
            "stream": false,
        ]
        if r.isLocal { body["chat_template_kwargs"] = ["enable_thinking": false] }
        if !tools.isEmpty { body["tools"] = tools }

        var req = URLRequest(url: r.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = r.apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteModelClient.ModelClientError.remoteFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            return AgentModelResult(text: "", toolCalls: [])
        }

        let text = (msg["content"] as? String) ?? ""
        var calls: [AgentToolCall] = []
        if let tcs = msg["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                if let fn = tc["function"] as? [String: Any],
                   let name = fn["name"] as? String, !name.isEmpty {
                    calls.append(AgentToolCall(name: name, args: (fn["arguments"] as? String) ?? "{}"))
                }
            }
        }
        return AgentModelResult(text: text, toolCalls: calls)
    }
}
