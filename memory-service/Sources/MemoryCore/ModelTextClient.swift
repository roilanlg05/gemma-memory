import Foundation

/// Minimal text-generation client used by the consolidation engine. Replaces the app's
/// richer runtime protocols (which carry tool wiring and streaming events the service
/// doesn't need). The MemoryService HTTP layer adapts an upstream local model
/// (e.g. the macOS mlx-vlm server) to this protocol.
public protocol ModelTextClient: Sendable {
    func generate(prompt: String, options: ModelTextOptions) async throws -> String
}

public struct ModelTextOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public init(maxTokens: Int = 800, temperature: Double = 0.7) {
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}
