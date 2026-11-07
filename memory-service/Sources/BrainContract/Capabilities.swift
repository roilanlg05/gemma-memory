import Foundation

/// contextTokens is the total context window; outputTokens reserves a nonnegative part of that window.

public struct BrainContextBudget: Codable, Equatable, Sendable {
    public let contextTokens: Int
    public let outputTokens: Int
    public let systemTokens: Int
    public let toolTokens: Int

    public init(
        contextTokens: Int,
        outputTokens: Int,
        systemTokens: Int = 0,
        toolTokens: Int = 0
    ) throws {
        try BrainValidation.budget(contextTokens, outputTokens)
        // Subtraction avoids overflow even for adversarial Int.max wire values.
        guard systemTokens >= 0, toolTokens >= 0,
              systemTokens <= contextTokens - outputTokens,
              toolTokens <= contextTokens - outputTokens - systemTokens else {
            throw BrainContractError.invalidBudget(contextTokens: contextTokens, outputTokens: outputTokens)
        }
        self.contextTokens = contextTokens
        self.outputTokens = outputTokens
        self.systemTokens = systemTokens
        self.toolTokens = toolTokens
    }

    // Preserve pre-extension canonical request hashes for durable operation retries. New
    // nonzero reservations still participate in the encoded request and conflict fingerprint.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contextTokens, forKey: .contextTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        if systemTokens != 0 { try c.encode(systemTokens, forKey: .systemTokens) }
        if toolTokens != 0 { try c.encode(toolTokens, forKey: .toolTokens) }
    }

    private enum CodingKeys: String, CodingKey {
        case contextTokens, outputTokens, systemTokens, toolTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contextTokens: try c.decode(Int.self, forKey: .contextTokens),
            outputTokens: try c.decode(Int.self, forKey: .outputTokens),
            systemTokens: try c.decodeIfPresent(Int.self, forKey: .systemTokens) ?? 0,
            toolTokens: try c.decodeIfPresent(Int.self, forKey: .toolTokens) ?? 0
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
