import Foundation
import MemoryCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-backed `ModelTextClient`. Resolves the consolidation provider from `ModelConfigStore` per
/// call: cloud → bearer auth + no mlx quirk; local (or no config) → mlx quirk, no auth.
///
/// `baseURL` ends at the version directory (e.g. `…/openai/v1`); the client appends
/// `chat/completions`. The mlx quirk sets `chat_template_kwargs.enable_thinking = false` because
/// consolidation phases run thinking-OFF (see MemoryConsolidationEngine.generate).
public struct RemoteModelClient: ModelTextClient {
    let configStore: ModelConfigStore?
    let defaultBaseURL: URL
    let defaultModel: String
    public let session: URLSession
    public let timeout: TimeInterval

    public init(configStore: ModelConfigStore?, defaultBaseURL: URL,
                defaultModel: String = "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
                session: URLSession = .shared, timeout: TimeInterval = 120) {
        self.configStore = configStore; self.defaultBaseURL = defaultBaseURL
        self.defaultModel = defaultModel; self.session = session; self.timeout = timeout
    }

    private func resolve() -> (baseURL: URL, model: String, apiKey: String?, isLocal: Bool) {
        if let c = try? configStore?.load() ?? nil, let url = URL(string: c.baseURL) {
            return (url, c.model, c.apiKey, c.provider == "local")
        }
        return (defaultBaseURL, defaultModel, nil, true)
    }

    public func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        let r = resolve()
        var body: [String: Any] = [
            "model": r.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
        ]
        if r.isLocal { body["chat_template_kwargs"] = ["enable_thinking": false] }

        var urlReq = URLRequest(url: r.baseURL.appendingPathComponent("chat/completions"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = r.apiKey, !key.isEmpty { urlReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        urlReq.timeoutInterval = timeout
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: urlReq)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelClientError.remoteFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
        struct OpenAIResp: Decodable { let choices: [Choice] }
        let parsed = try JSONDecoder().decode(OpenAIResp.self, from: data)
        return parsed.choices.first?.message.content ?? ""
    }

    public enum ModelClientError: Error, Equatable { case remoteFailed(status: Int) }
}
