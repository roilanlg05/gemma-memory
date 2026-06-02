import Foundation
import MemoryCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-backed `ModelTextClient` that adapts an OpenAI-compatible chat endpoint
/// (the macOS mlx-vlm server) to the protocol expected by the consolidation engine.
///
/// The request body sets `chat_template_kwargs.enable_thinking = false` because every
/// consolidation phase runs thinking-OFF (see MemoryConsolidationEngine.generate).
public struct RemoteModelClient: ModelTextClient {
    public let baseURL: URL
    public let session: URLSession
    public let timeout: TimeInterval
    public let model: String

    /// - Parameters:
    ///   - model: model id to send in the OpenAI-compatible `model` field. mlx_vlm.server
    ///     falls back to its built-in default (e.g. nanoLLaVA) if the field is missing, which
    ///     triggers an on-demand load + breaks our speculative drafter. Always send the model
    ///     we actually want consolidation phases to run against.
    public init(baseURL: URL,
                model: String = "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
                session: URLSession = .shared,
                timeout: TimeInterval = 120) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.timeout = timeout
    }

    public func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        struct Msg: Encodable { let role: String; let content: String }
        struct Req: Encodable {
            let model: String
            let messages: [Msg]
            let max_tokens: Int
            let temperature: Double
            let chat_template_kwargs: [String: Bool]
        }
        let req = Req(model: model,
                      messages: [.init(role: "user", content: prompt)],
                      max_tokens: options.maxTokens,
                      temperature: options.temperature,
                      chat_template_kwargs: ["enable_thinking": false])
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("/v1/chat/completions"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = timeout
        urlReq.httpBody = try JSONEncoder().encode(req)

        let (data, resp) = try await session.data(for: urlReq)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelClientError.remoteFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
        struct OpenAIResp: Decodable { let choices: [Choice] }
        let r = try JSONDecoder().decode(OpenAIResp.self, from: data)
        return r.choices.first?.message.content ?? ""
    }

    public enum ModelClientError: Error, Equatable { case remoteFailed(status: Int) }
}
