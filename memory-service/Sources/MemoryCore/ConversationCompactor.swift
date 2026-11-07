import Foundation
import BrainContract

/// A model candidate preserves modality explicitly. Structural validation checks provenance,
/// not language understanding; a production model's semantic fidelity needs separate evaluation.
public struct ConversationStatement: Codable, Equatable, Sendable {
    public let text: String
    public let evidenceIDs: [String]
    public let modality: BrainClaimModality
    public init(text: String, evidenceIDs: [String], modality: BrainClaimModality) {
        self.text = text; self.evidenceIDs = evidenceIDs; self.modality = modality
    }
}
public struct ConversationStateCandidate: Codable, Equatable, Sendable {
    public let gist: [ConversationStatement]
    public let subjects: [ConversationStatement]
    public let intent: [ConversationStatement]
    public let decisions: [ConversationStatement]
    public let constraints: [ConversationStatement]
    public let openReferents: [ConversationStatement]
    public init(gist: [ConversationStatement] = [], subjects: [ConversationStatement] = [],
                intent: [ConversationStatement] = [], decisions: [ConversationStatement] = [],
                constraints: [ConversationStatement] = [], openReferents: [ConversationStatement] = []) {
        self.gist = gist; self.subjects = subjects; self.intent = intent
        self.decisions = decisions; self.constraints = constraints; self.openReferents = openReferents
    }
    var statements: [ConversationStatement] { gist + subjects + intent + decisions + constraints + openReferents }
    var sections: [(String, [ConversationStatement])] {
        [("constraint", constraints), ("referent", openReferents), ("decision", decisions),
         ("intent", intent), ("subject", subjects), ("gist", gist)]
    }
}
public protocol ConversationSummaryModel {
    /// Only raw originals are supplied. Configure the adapter to honor the compactor's separate
    /// modelBudget, including its real system prompt, tools and maximum generated output.
    func summarize(sources: [BrainEvidence]) async throws -> ConversationStateCandidate
}

public final class ConversationCompactor {
    private let store: ConversationStateStore
    private let model: (any ConversationSummaryModel)?
    private let modelBudget: BrainContextBudget
    public init(store: ConversationStateStore, model: (any ConversationSummaryModel)?, modelBudget: BrainContextBudget? = nil) {
        self.store = store; self.model = model
        self.modelBudget = modelBudget ?? (try! BrainContextBudget(contextTokens: 8192, outputTokens: 1024, systemTokens: 512))
    }
    public func update(threadID: String, throughEvidenceID: String) async throws {
        let snapshot = try store.snapshot(threadID: threadID)
        guard let model else { return }
        guard let end = snapshot.sources.firstIndex(where: { $0.evidence.id == throughEvidenceID }) else { throw BrainStoreError.invalid }
        let prefix = Array(snapshot.sources[...end])
        let prefixIDs = Set(prefix.map { $0.evidence.id })
        // Do not compact half of a tool interaction or durable conversation group.
        let groups = Self.groups(snapshot.sources).filter { group in group.allSatisfy { prefixIDs.contains($0.evidence.id) } }
        let covered = Set(snapshot.segments.flatMap { $0.sources.map(\.evidenceID) })
        let remaining = groups.filter { group in group.allSatisfy { !covered.contains($0.evidence.id) } }
        let capacity = modelBudget.contextTokens - modelBudget.outputTokens - modelBudget.systemTokens - modelBudget.toolTokens
        func fits(_ raw: [ConversationSource]) throws -> Bool {
            let count = try JSONEncoder().encode(raw.map(\.evidence)).count
            return capacity >= 64 && count <= capacity - 64
        }
        var chunks = [[ConversationSource]](), chunk = [ConversationSource]()
        for group in remaining {
            guard try fits(group) else {
                // Oversized originals remain available for explicitly truncated recent context.
                if !chunk.isEmpty { chunks.append(chunk); chunk = [] }
                continue
            }
            if try !fits(chunk + group), !chunk.isEmpty { chunks.append(chunk); chunk = [] }
            chunk += group
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        for raw in chunks {
            let candidate: ConversationStateCandidate
            do { candidate = try await model.summarize(sources: raw.map(\.evidence)) }
            catch {
                _ = try store.validated(snapshot) { $0.revision }
                throw error
            }
            // save checks both the global revision and every original after this await.
            try store.save(candidate, sources: raw, snapshot: snapshot)
        }
    }
    static func groups(_ sources: [ConversationSource]) -> [[ConversationSource]] {
        var indexes = [String: Int](), result = [[ConversationSource]]()
        for source in sources {
            if let index = indexes[source.groupID] { result[index].append(source) }
            else { indexes[source.groupID] = result.count; result.append([source]) }
        }
        return result
    }
}
