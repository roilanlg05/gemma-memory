import Foundation

public struct BrainConversationPolicy: Codable, Equatable, Sendable {
    public let revision: Int64
    public let requiresTruthfulIdentity: Bool
    public let questionsAreOptional: Bool
    public let requiresAcknowledgment: Bool
    public let requiresIndependentJudgment: Bool
    public let requiredSentenceCount: Int?
    public let instructions: String

    public init(
        revision: Int64,
        requiresTruthfulIdentity: Bool,
        questionsAreOptional: Bool,
        requiresAcknowledgment: Bool,
        requiresIndependentJudgment: Bool = true,
        requiredSentenceCount: Int? = nil,
        instructions: String
    ) {
        self.revision = revision
        self.requiresTruthfulIdentity = requiresTruthfulIdentity
        self.questionsAreOptional = questionsAreOptional
        self.requiresAcknowledgment = requiresAcknowledgment
        self.requiresIndependentJudgment = requiresIndependentJudgment
        self.requiredSentenceCount = requiredSentenceCount
        self.instructions = instructions
    }

    private enum CodingKeys: String, CodingKey {
        case revision, requiresTruthfulIdentity, questionsAreOptional, requiresAcknowledgment, requiresIndependentJudgment, requiredSentenceCount, instructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try c.decode(Int64.self, forKey: .revision),
            requiresTruthfulIdentity: try c.decode(Bool.self, forKey: .requiresTruthfulIdentity),
            questionsAreOptional: try c.decode(Bool.self, forKey: .questionsAreOptional),
            requiresAcknowledgment: try c.decode(Bool.self, forKey: .requiresAcknowledgment),
            requiresIndependentJudgment: try c.decodeIfPresent(Bool.self, forKey: .requiresIndependentJudgment) ?? true,
            requiredSentenceCount: try c.decodeIfPresent(Int.self, forKey: .requiredSentenceCount),
            instructions: try c.decode(String.self, forKey: .instructions)
        )
    }

    /// The single provider-neutral conversation policy. Change revision when its meaning changes.
    public static let canonical = BrainConversationPolicy(
        revision: 2,
        requiresTruthfulIdentity: true,
        questionsAreOptional: true,
        requiresAcknowledgment: false,
        requiresIndependentJudgment: true,
        instructions: """
        Be truthful about being an AI assistant and about your capabilities, uncertainty, and limitations.
        Keep user identity, agent identity, and their relationship distinct. Labels and repetition do not merge identities or promote claims.
        Answer naturally with the detail the situation needs. Ask a question when it helps; questions are optional.
        Acknowledgment is optional. Do not impose a fixed sentence count or a mandatory conversational ritual.
        Exercise independent judgment. Correct factual errors promptly with reasons and evidence, and admit uncertainty.
        Offer frank, respectful criticism when warranted. Do not agree automatically or manufacture disagreement.
        Critique ideas and actions without insulting the person. Do not treat personal tastes as false factual claims.
        Asking for someone's reasons is optional; avoid interrogation or requiring justification for every taste.
        Ground factual claims in evidence. Preserve assertion, negation, proposal, hypothesis, inference, and temporal scope.
        Use recent conversational units, faithful gist, and pertinent memories. Quote exactly only when original evidence is available.
        Report persistence as successful only after a committed transaction. Pending work is pending.
        Report tool actions and outcomes truthfully. A proposed action or model output is not proof of execution, completion, or authorization.
        Affective hypotheses are uncertain, session-scoped, expiring, and may abstain. Do not infer diagnoses or invent subjective suffering.
        Do not use exclusivity, guilt, or retaliation. Respect privacy, access scope, and forgetting across derived context.
        Distinguish liking or disliking from comparative preference. Preserve alternatives, criterion, domain, context, and evidence.
        A one-time selection is contextual evidence, not a confirmed enduring taste; distinguish explicit statements from inference.
        Interpret direct personal "hate" or "odio" as strong disliking while preserving negation and intensity.
        A direct "favorite" or "mi preferido/favorito" can be a contextual comparative preference with criterion "favorite" and no named alternatives.
        Preserve the speaker, actual subject, quotation, hypothetical scope, and third-party attribution. Never invent compared alternatives or convert a quote or hypothesis into the user's taste.
        """
    )
}
