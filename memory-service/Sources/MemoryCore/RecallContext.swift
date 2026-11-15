import Foundation
import BrainContract
import GRDB

/// Trusted host input for optional cross-conversation context. Quote/detail IDs are explicit
/// requests to resolve originals. The source reference itself grants no original access.
public struct RecallContextOptions: Sendable {
    public let asOf: Double
    public let scope: BrainAccessScope
    public let includeStartupOrientation: Bool
    public let conversation: RecallConversation?
    public let finalizedCue: RecallFinalization?
    public let quoteEvidenceIDs: [String]
    public let detailEvidenceIDs: [String]
    public let budget: BrainRecallBudget

    public init(asOf: Double, scope: BrainAccessScope = .user, includeStartupOrientation: Bool = false,
                conversation: RecallConversation? = nil, finalizedCue: RecallFinalization? = nil,
                quoteEvidenceIDs: [String] = [], detailEvidenceIDs: [String] = [], budget: BrainRecallBudget = .init()) {
        self.asOf = asOf; self.scope = scope; self.includeStartupOrientation = includeStartupOrientation
        self.conversation = conversation; self.finalizedCue = finalizedCue
        self.quoteEvidenceIDs = quoteEvidenceIDs; self.detailEvidenceIDs = detailEvidenceIDs; self.budget = budget
    }
    func acceptsPrepared(brain: BrainStore, request: BrainContextRequest) -> Bool {
        guard let finalizedCue else { return true }
        guard let conversation else { return false }
        return finalizedCue.matches(brain: brain, connectionID: conversation.connectionID,
            turnID: request.clientOperationID, threadID: request.threadID, scope: scope, query: request.query)
    }
}

struct RecallContextContent {
    struct Block {
        let text: String
        let sources: [BrainEvidence]
        let use: BrainContextSourceUse
        let isRequestedHistory: Bool
    }
    let originals: [BrainEvidence]
    let quotes: Set<String>
    let blocks: [Block]

    static func build(retriever: AssociativeRetriever, request: BrainContextRequest, current: ConversationSnapshot,
                      options: RecallContextOptions, gate: RecallOpportunityGate, vector: IndexEmbedding?, db: Database) throws -> Self? {
        guard options.acceptsPrepared(brain: retriever.brain, request: request) else { return nil }
        let graph = try GraphMemoryQuery(brain: retriever.brain).snapshot(threadID: request.threadID,
            scope: options.scope, asOf: options.asOf, db: db)
        let quoteIDs = Set(options.quoteEvidenceIDs)
        guard options.quoteEvidenceIDs.count <= 16, options.detailEvidenceIDs.count <= 16 else { throw BrainStoreError.invalid }
        var seen = Set<String>()
        let ids = (options.quoteEvidenceIDs + options.detailEvidenceIDs).filter { seen.insert($0).inserted }
        let originals = try EpisodeReconstructor.authorizedOriginals(ids, snapshot: graph)
        let detectedRequest = request.query.range(of: #"\b(remember|recall|recuerdas|acuerdas)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let conversation = options.conversation ?? .init(connectionID: "", topic: "", mode: .taskFocused,
                                                        explicitlyRequested: detectedRequest)
        let wantsProject = request.query.range(of: #"\b(project|proyecto|resume|continue|retomar|seguir|sigamos|continuemos)\b"#,
                                               options: [.regularExpression, .caseInsensitive]) != nil
        var project = (result: ProjectRecallResult.none, sources: [BrainEvidence]())
        if wantsProject {
            project = EpisodeReconstructor.project(query: request.query, snapshot: graph, budget: options.budget)
        }
        let focus = request.query
        var retrieved = [Block]()
        switch project.result {
        case .none:
            let query = referentialQuery(focus, current: current, conversation: conversation)
            let recall = try retriever.rank(query: query, asOf: options.asOf, budget: options.budget, strategy: .hybrid,
                vector: options.finalizedCue?.vector ?? vector, snapshot: graph, db: db)
            for candidate in recall.candidates {
                let action = gate.opportunity(candidate: candidate, conversation: conversation, now: options.asOf)
                guard action == .mention || action == .contextOnly else { continue }
                let state: String
                switch RecallClaimPredicate(rawValue: candidate.claim.predicate) {
                case .episode: state = "historical episode"
                case .state: state = "current state report"
                default: state = "evidenced claim"
                }
                let usage = action == .mention ? "mention if relevant" : "context only, keep silent unless asked"
                retrieved.append(block(label: "recalled \(state) \(usage)", text: candidate.gist,
                    sources: candidate.sources, claim: candidate.claim))
            }
        case .clarify(let names):
            let prompt = "Which project did you mean?" + (names.isEmpty ? "" : " " + names.joined(separator: " / "))
            retrieved.append(block(label: "recalled project clarification", text: prompt, sources: project.sources))
        case .resolved(let match):
            retrieved.append(block(label: "recalled project", text: match.name, sources: project.sources))
            func append(_ item: ProjectRecallItem, label: String) {
                retrieved.append(block(label: "recalled project \(label)", text: item.text, sources: item.sources,
                    claim: item.claim, associations: item.associationSources))
            }
            if let checkpoint = match.checkpoint { append(checkpoint, label: "reported checkpoint") }
            for item in match.decisions { append(item, label: "decision") }
            for item in match.progress { append(item, label: item.verified ? "verified progress" : "reported progress") }
            for item in match.nextSteps { append(item, label: "open next step") }
        }
        var startup = [Block]()
        if options.includeStartupOrientation,
           let orientation = try EpisodeReconstructor(brain: retriever.brain).orientation(threadID: request.threadID,
                scope: options.scope, asOf: options.asOf, snapshot: graph, db: db) {
            for (label, fragment) in [("opening", orientation.opening), ("closing", orientation.closing)] {
                guard let fragment else { continue }
                startup.append(block(label: "previous exchange \(label) orientation historical excerpt speaker=\(fragment.source.speakerID)", text: fragment.text,
                    sources: [fragment.source], use: .startupOrientation))
            }
        }
        let transcriptRecall = TranscriptRecall(query: request.query, asOf: options.asOf)
        let excerpts = try transcriptRecall.sources(brain: retriever.brain, threadID: request.threadID,
            scope: options.scope, current: current, snapshot: graph, db: db).map { source in
            let timestamp = Date(timeIntervalSince1970: source.observedAt).ISO8601Format()
            let author = source.sourceKind == .assistantMessage ? "assistant reply" : "user message"
            return block(label: "prior \(author) on \(timestamp), historical data; anchor dates here; verify current state",
                         text: transcriptRecall.excerpt(from: source), sources: [AssociativeRetriever.metadata(source)], requestedHistory: true)
        }
        let blocks = if wantsProject { retrieved + excerpts + startup }
            else if !excerpts.isEmpty { excerpts + retrieved }
            else if transcriptRecall.isExplicit || conversation.explicitlyRequested { retrieved + startup }
            else { startup + retrieved }
        return .init(originals: originals, quotes: quoteIDs, blocks: blocks)
    }

    private static func block(label: String, text: String, sources: [BrainEvidence], use: BrainContextSourceUse = .recalledSupport,
                              claim: BrainClaim? = nil, associations: [BrainEvidence] = [], requestedHistory: Bool = false) -> Block {
        let ids = Set(sources.map(\.id)).sorted().joined(separator: ",")
        let related = Set(associations.map(\.id)).sorted().joined(separator: ",")
        var header = label + " sources=" + ids
        if let claim {
            let speakers = Set(sources.map(\.speakerID)).sorted().joined(separator: ",")
            header += " subject=\(claim.subject) modality=\(claim.modality.rawValue) valid-from=\(claim.validFrom) speakers=\(speakers)"
        }
        if !related.isEmpty { header += " membership-sources=" + related }
        return .init(text: "[\(header)]\n\(text)", sources: sources + associations, use: use, isRequestedHistory: requestedHistory)
    }

    private static func referentialQuery(_ query: String, current: ConversationSnapshot, conversation: RecallConversation) -> String {
        let terms = RecallCue(query).terms
        guard !conversation.topicChanged, terms.count <= 2,
              !terms.isDisjoint(with: ["rematch", "revancha", "again", "otra", "eso", "ese", "that"]) else { return query }
        guard let prior = current.sources.reversed().first(where: {
            $0.evidence.sourceKind == .userMessage && $0.evidence.text != query
        })?.evidence.text else { return query }
        return query + " " + String(prior.prefix(384))
    }
}
