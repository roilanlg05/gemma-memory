import Foundation

/// contextTokens is the total context window; outputTokens reserves a nonnegative part of that window.

public struct BrainContextBudget: Codable, Equatable, Sendable {
    public let contextTokens: Int
    public let outputTokens: Int

    public init(
        contextTokens: Int,
        outputTokens: Int
    ) throws {
        try BrainValidation.budget(contextTokens, outputTokens)
        self.contextTokens = contextTokens
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case contextTokens, outputTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contextTokens: try c.decode(Int.self, forKey: .contextTokens),
            outputTokens: try c.decode(Int.self, forKey: .outputTokens)
        )
    }
}

public enum BrainTokenizerEstimatePolicy: String, Codable, Equatable, Sendable {
    case conservative, exact, unavailable
}

/// Tool names describe only tools actually available in this environment.

public struct BrainModelCapabilities: Codable, Equatable, Sendable {
    public let contextTokens: Int
    public let outputTokens: Int
    public let tools: [String]
    public let structuredOutput: Bool
    public let images: Bool
    public let tokenizerEstimatePolicy: BrainTokenizerEstimatePolicy

    public init(
        contextTokens: Int,
        outputTokens: Int,
        tools: [String],
        structuredOutput: Bool,
        images: Bool,
        tokenizerEstimatePolicy: BrainTokenizerEstimatePolicy
    ) throws {
        try BrainValidation.budget(contextTokens, outputTokens)
        self.contextTokens = contextTokens
        self.outputTokens = outputTokens
        self.tools = tools
        self.structuredOutput = structuredOutput
        self.images = images
        self.tokenizerEstimatePolicy = tokenizerEstimatePolicy
    }

    private enum CodingKeys: String, CodingKey {
        case contextTokens, outputTokens, tools, structuredOutput, images, tokenizerEstimatePolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contextTokens: try c.decode(Int.self, forKey: .contextTokens),
            outputTokens: try c.decode(Int.self, forKey: .outputTokens),
            tools: try c.decode([String].self, forKey: .tools),
            structuredOutput: try c.decode(Bool.self, forKey: .structuredOutput),
            images: try c.decode(Bool.self, forKey: .images),
            tokenizerEstimatePolicy: try c.decode(BrainTokenizerEstimatePolicy.self, forKey: .tokenizerEstimatePolicy)
        )
    }
}
