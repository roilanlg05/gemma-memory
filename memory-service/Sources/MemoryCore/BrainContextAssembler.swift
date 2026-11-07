import Foundation
import BrainContract

public enum BrainContextAssemblyError: Error, Equatable { case insufficientBudget }

public struct ConversationSelection: Sendable {
    public let detailEvidenceIDs: [String]
    public let quoteEvidenceIDs: [String]
    public let claimIDs: [String]
    public init(detailEvidenceIDs: [String] = [], quoteEvidenceIDs: [String] = [], claimIDs: [String] = []) {
        self.detailEvidenceIDs = detailEvidenceIDs; self.quoteEvidenceIDs = quoteEvidenceIDs; self.claimIDs = claimIDs
    }
}
/// Bounded progressive-selection input: segment state and original metadata, never all raw text.
public struct ConversationSelectionInput: Codable, Sendable {
    public let query: String
    public let segments: [ConversationSegment]
    public let claims: [BrainClaim]
    public let sourceReferences: [BrainEvidence]
}
public protocol ConversationDetailSelector {
    func select(_ input: ConversationSelectionInput) async throws -> ConversationSelection
}

/// Provider-neutral context construction. One UTF-8 byte counts as one estimated token;
/// serialization overhead, both rendered and structured representations, query and framing count.
/// This deliberately overestimates. Provider integrations must use actual system/tool reserves.
public final class BrainContextAssembler {
    private let store: ConversationStateStore
    private let selector: (any ConversationDetailSelector)?
    public init(store: ConversationStateStore, selector: (any ConversationDetailSelector)? = nil) {
        self.store = store; self.selector = selector
    }
    public func context(_ request: BrainContextRequest) async throws -> BrainContextBundle {
        let snapshot = try store.snapshot(threadID: request.threadID)
        let empty = Draft()
        guard try fits(empty, request: request, revision: snapshot.revision) else { throw BrainContextAssemblyError.insufficientBudget }
        var selection = ConversationSelection()
        if let selector {
            let input = try selectionInput(snapshot, request: request)
            do { selection = try await selector.select(input) }
            catch {
                // A failing optional model still must not return data withdrawn during its await.
                return try store.validated(snapshot) { try assemble($0, request: request, selection: .init()) }
            }
        }
        return try store.validated(snapshot) { try assemble($0, request: request, selection: selection) }
    }
    private struct Draft {
        var blocks = [String]()
        var units = [BrainMessageUnit]()
        var references = [String: BrainEvidence]()
        var truncations = [BrainContextTruncation]()
    }
    private func capacity(_ budget: BrainContextBudget) -> Int {
        budget.contextTokens - budget.outputTokens - budget.systemTokens - budget.toolTokens
    }
    private func bundle(_ draft: Draft, request: BrainContextRequest, revision: Int64, estimate: Int) -> BrainContextBundle {
        .init(renderedContext: draft.blocks.joined(separator: "\n"), recentMessageUnits: draft.units,
              sourceReferences: draft.references.values.sorted { $0.id < $1.id }, revision: revision,
              policyRevision: BrainConversationPolicy.canonical.revision,
              accounting: .init(estimatedInputTokens: estimate, reservedOutputTokens: request.budget.outputTokens,
                                reservedSystemTokens: request.budget.systemTokens, reservedToolTokens: request.budget.toolTokens,
                                totalWindowTokens: request.budget.contextTokens), truncations: draft.truncations)
    }
    private func estimatedInput(_ draft: Draft, request: BrainContextRequest, revision: Int64) throws -> Int {
        // Int.max's numeric encoding bounds the shorter estimate eventually put on the wire.
        let count = try JSONEncoder().encode(bundle(draft, request: request, revision: revision, estimate: Int.max)).count
        let (withQuery, overflow) = count.addingReportingOverflow(request.query.utf8.count)
        let (withFrame, frameOverflow) = withQuery.addingReportingOverflow(64)
        guard !overflow, !frameOverflow else { throw BrainContextAssemblyError.insufficientBudget }
        return withFrame
    }
    private func fits(_ draft: Draft, request: BrainContextRequest, revision: Int64) throws -> Bool {
        try estimatedInput(draft, request: request, revision: revision) <= capacity(request.budget)
    }
    private static func metadata(_ evidence: BrainEvidence) -> BrainEvidence {
        .init(id: evidence.id, sourceKind: evidence.sourceKind, speakerID: evidence.speakerID,
              threadID: evidence.threadID, observedAt: evidence.observedAt, recordedAt: evidence.recordedAt,
              span: evidence.span, accessScope: evidence.accessScope, text: nil, parentEvidenceIDs: evidence.parentEvidenceIDs)
    }
    private func selectionInput(_ snapshot: ConversationSnapshot, request: BrainContextRequest) throws -> ConversationSelectionInput {
        let limit = min(8192, max(0, capacity(request.budget) - 64))
        var segments = [ConversationSegment](), claims = [BrainClaim](), references = [BrainEvidence]()
        func input() -> ConversationSelectionInput {
            .init(query: request.query, segments: segments, claims: claims, sourceReferences: references)
        }
        guard try JSONEncoder().encode(input()).count <= limit else { throw BrainContextAssemblyError.insufficientBudget }
        for segment in snapshot.segments.reversed() {
            segments.append(segment)
            if try JSONEncoder().encode(input()).count > limit { segments.removeLast() }
        }
        for claim in snapshot.claims.reversed() {
            claims.append(claim)
            if try JSONEncoder().encode(input()).count > limit { claims.removeLast() }
        }
        for source in snapshot.sources.reversed() {
            references.append(Self.metadata(source.evidence))
            if try JSONEncoder().encode(input()).count > limit { references.removeLast() }
        }
        return input()
    }
    private func assemble(_ snapshot: ConversationSnapshot, request: BrainContextRequest, selection: ConversationSelection) throws -> BrainContextBundle {
        let originals = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.evidence.id, $0.evidence) })
        let claims = Dictionary(uniqueKeysWithValues: snapshot.claims.map { ($0.id, $0) })
        guard selection.detailEvidenceIDs.allSatisfy({ originals[$0] != nil }),
              selection.quoteEvidenceIDs.allSatisfy({ originals[$0] != nil }),
              selection.claimIDs.allSatisfy({ claims[$0] != nil }) else { throw BrainStoreError.denied }
        var available = Dictionary(uniqueKeysWithValues: snapshot.memoryEvidence.map { ($0.id, $0) })
        for (id, source) in originals { available[id] = source }
        var draft = Draft()
        func adding(to old: Draft, block: String? = nil, units: [BrainMessageUnit] = [], ids: [String] = [],
                    truncations: [BrainContextTruncation] = [], prependUnits: Bool = false) -> Draft {
            var next = old
            if let block { next.blocks.append(block) }
            next.units = prependUnits ? units + next.units : next.units + units
            for id in ids { if let evidence = available[id] { next.references[id] = Self.metadata(evidence) } }
            next.truncations += truncations
            return next
        }
        @discardableResult func add(block: String? = nil, units: [BrainMessageUnit] = [], ids: [String] = [],
                                    truncations: [BrainContextTruncation] = [], prependUnits: Bool = false,
                                    maximumInput: Int? = nil) throws -> Bool {
            let next = adding(to: draft, block: block, units: units, ids: ids, truncations: truncations, prependUnits: prependUnits)
            guard try fits(next, request: request, revision: snapshot.revision) else { return false }
            if let maximumInput, try estimatedInput(next, request: request, revision: snapshot.revision) > maximumInput { return false }
            draft = next; return true
        }
        let quotes = Set(selection.quoteEvidenceIDs)
        var detailed = Set<String>()
        let selected = (selection.quoteEvidenceIDs + selection.detailEvidenceIDs).filter { detailed.insert($0).inserted }
        // Every selected original must be delivered fully or explicitly accounted for. Reserve
        // all omission notices first, so an earlier quote cannot consume a later disclosure.
        let disclosures = try selected.map { id -> BrainContextTruncation in
            guard let text = originals[id]?.text else { throw BrainStoreError.invalid }
            return .init(evidenceID: id, originalUTF8Bytes: text.utf8.count, includedUTF8Bytes: 0,
                         reason: quotes.contains(id) ? "quoteOmittedBudget" : "detailOmittedBudget")
        }
        draft = adding(to: draft, truncations: disclosures)
        guard try fits(draft, request: request, revision: snapshot.revision) else {
            throw BrainContextAssemblyError.insufficientBudget
        }
        for id in selected {
            guard let text = originals[id]?.text else { throw BrainStoreError.invalid }
            let label = quotes.contains(id) ? "original quote" : "original detail"
            var withoutDisclosure = draft
            withoutDisclosure.truncations.removeAll { $0.evidenceID == id }
            let delivered = adding(to: withoutDisclosure, block: "[\(label) source=\(id)]\n\(text)", ids: [id])
            if try fits(delivered, request: request, revision: snapshot.revision) { draft = delivered }
        }
        for id in selection.claimIDs {
            guard let claim = claims[id] else { continue }
            try add(block: "[memory]\n" + BrainStore.encode(claim), ids: snapshot.claimEvidenceIDs[id] ?? [])
        }
        // Reserve half the remaining input capacity for recent raw groups. Continuity state
        // gets the other half first, so one oversized new message cannot evict an old constraint.
        let stateStart = try estimatedInput(draft, request: request, revision: snapshot.revision)
        let stateLimit = stateStart + (capacity(request.budget) - stateStart) / 2
        // Carry constraints/referents/decisions before incidental gist, with explicit modality.
        for label in ["constraint", "referent", "decision", "intent", "subject", "gist"] {
            for segment in snapshot.segments.reversed() {
                for (section, statements) in segment.state.sections where section == label {
                    for statement in statements {
                        let block = "[\(label) \(statement.modality.rawValue) sources=\(statement.evidenceIDs.joined(separator: ","))]\n\(statement.text)"
                        try add(block: block, ids: statement.evidenceIDs, maximumInput: stateLimit)
                    }
                }
            }
        }
        // Recent raw groups are adaptive to budget. Summarized old groups default to gist;
        // the newest group remains raw even when a background compaction just covered it.
        let covered = Set(snapshot.segments.flatMap { $0.sources.map(\.evidenceID) })
        let groups = ConversationCompactor.groups(snapshot.sources)
        let newest = groups.last?.first?.groupID
        let recent = groups.filter { group in group.first?.groupID == newest || group.contains { !covered.contains($0.evidence.id) } }
        for group in recent.reversed() {
            let ids = group.map { $0.evidence.id }
            func units(cap: Int?) -> [BrainMessageUnit] {
                group.map { source in
                    let original = source.evidence.text ?? ""
                    let text = cap.map { Self.prefix(original, maximumUTF8Bytes: $0) } ?? original
                    return .init(id: source.evidence.id, speakerID: source.evidence.speakerID, text: text,
                                 observedAt: source.evidence.observedAt, evidenceIDs: [source.evidence.id], groupID: source.groupID)
                }
            }
            if try add(units: units(cap: nil), ids: ids, prependUnits: true) { continue }
            // Keep all members of an oversized group, or none. Each retained prefix is marked.
            var low = 0, high = group.map { $0.evidence.text?.utf8.count ?? 0 }.max() ?? 0
            var best: Draft?
            while low <= high {
                let mid = low + (high - low) / 2
                let partial = units(cap: mid)
                let truncations = zip(group, partial).compactMap { source, unit -> BrainContextTruncation? in
                    let bytes = source.evidence.text?.utf8.count ?? 0
                    guard unit.text.utf8.count < bytes else { return nil }
                    return .init(evidenceID: source.evidence.id, originalUTF8Bytes: bytes,
                                 includedUTF8Bytes: unit.text.utf8.count, reason: "recentPrefixBudget")
                }
                let next = adding(to: draft, units: partial, ids: ids, truncations: truncations, prependUnits: true)
                if try fits(next, request: request, revision: snapshot.revision) {
                    if partial.allSatisfy({ !$0.text.isEmpty }) { best = next }
                    if mid == Int.max { break }
                    low = mid + 1
                } else { high = mid - 1 }
            }
            if let best { draft = best }
            else {
                try add(truncations: group.map { .init(evidenceID: $0.evidence.id,
                    originalUTF8Bytes: $0.evidence.text?.utf8.count ?? 0, includedUTF8Bytes: 0, reason: "groupOmittedBudget") })
            }
        }
        let estimate = try estimatedInput(draft, request: request, revision: snapshot.revision)
        guard estimate <= capacity(request.budget) else { throw BrainContextAssemblyError.insufficientBudget }
        return bundle(draft, request: request, revision: snapshot.revision, estimate: estimate)
    }
    private static func prefix(_ text: String, maximumUTF8Bytes: Int) -> String {
        var result = "", count = 0
        for character in text {
            let next = String(character)
            guard next.utf8.count <= maximumUTF8Bytes - count else { break }
            result += next; count += next.utf8.count
        }
        return result
    }
}
