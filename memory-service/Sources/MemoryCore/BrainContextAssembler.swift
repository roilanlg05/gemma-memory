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
    private let affect: AffectiveContextService?
    private let recall: AssociativeRetriever?
    private let opportunityGate: RecallOpportunityGate
    public init(store: ConversationStateStore, selector: (any ConversationDetailSelector)? = nil,
                affect: AffectiveContextService? = nil, recall: AssociativeRetriever? = nil,
                opportunityGate: RecallOpportunityGate = .init()) {
        self.store = store; self.selector = selector; self.affect = affect
        self.recall = recall; self.opportunityGate = opportunityGate
    }
    public func context(_ request: BrainContextRequest, recallOptions: RecallContextOptions? = nil) async throws -> BrainContextBundle {
        let snapshot = try store.snapshot(threadID: request.threadID)
        // The envelope and the disclosure floor are checked before the selector runs, so a window
        // that cannot honestly report what it dropped fails before a model is called.
        var empty = Draft()
        empty.truncations = Self.snapshotDisclosureFloor(snapshot).map { $0.1 }
        guard try fits(empty, request: request, revision: snapshot.revision) else { throw BrainContextAssemblyError.insufficientBudget }
        var selection = ConversationSelection(detailEvidenceIDs: request.detailEvidenceIDs ?? [],
                                              quoteEvidenceIDs: request.quoteEvidenceIDs ?? [])
        if let selector, request.detailEvidenceIDs == nil, request.quoteEvidenceIDs == nil {
            let input = try selectionInput(snapshot, request: request)
            do { selection = try await selector.select(input) }
            catch {
                // A failing optional model still must not return data withdrawn during its await.
                selection = .init()
            }
        }
        var vector: [Float]?
        if let recallOptions {
            guard let recall else { throw BrainStoreError.denied }
            if recall.brain !== store.brain {
                guard recall.brain.isOwnerSharedRecall(for: store.brain, threadID: request.threadID),
                      recallOptions.scope == .user, recallOptions.quoteEvidenceIDs.isEmpty,
                      recallOptions.detailEvidenceIDs.isEmpty else { throw BrainStoreError.denied }
            }
            guard recallOptions.asOf.isFinite else { throw BrainStoreError.invalid }
            if recallOptions.finalizedCue == nil {
                vector = try await recall.queryVector(request.query, threadID: request.threadID, scope: recallOptions.scope)
            }
            try Task.checkCancellation()
        }
        let result = try store.validatedInTransaction(snapshot) { current, db in
            let interaction = try affect?.interaction(threadID: request.threadID, authorizedBy: store.brain, db: db)
            if let recall, let recallOptions, let content = try RecallContextContent.build(retriever: recall,
                request: request, current: current, options: recallOptions, gate: opportunityGate, vector: vector, db: db) {
                let assembled = try assemble(current, request: request, selection: selection, interaction: interaction, recall: content)
                if recallOptions.acceptsPrepared(brain: recall.brain, request: request) { return assembled }
            }
            return try assemble(current, request: request, selection: selection, interaction: interaction, recall: nil)
        }
        try Task.checkCancellation()
        return result
    }
    private struct Draft {
        var blocks = [String]()
        var units = [BrainMessageUnit]()
        var references = [String: BrainEvidence]()
        var truncations = [BrainContextTruncation]()
        var sourceUses = [String: [BrainContextSourceUse]]()

        mutating func recordUse(_ use: BrainContextSourceUse, id: String) {
            if sourceUses[id]?.contains(use) != true {
                sourceUses[id, default: []].append(use)
            }
        }
    }
    private struct SelectedOriginal {
        let id: String
        let text: String
        let reason: DisclosureReason

        var omission: BrainContextTruncation {
            .init(evidenceID: id, originalUTF8Bytes: text.utf8.count,
                  includedUTF8Bytes: 0, reason: reason.rawValue)
        }
    }
    /// Each omission class reserves room for one aggregate before any content is admitted.
    enum DisclosureReason: String, CaseIterable, Sendable {
        /// An original the model asked to quote or to see in detail was not delivered.
        case quoteOmittedBudget
        case detailOmittedBudget
        case recalledQuoteOmittedBudget
        case recalledDetailOmittedBudget
        /// A recent raw turn was delivered as a marked prefix of itself.
        case recentPrefixBudget
        /// The agent identity section did not fit.
        case agentIdentityOmittedBudget
        /// A recent raw group did not fit, not even as a prefix of every member.
        case groupOmittedBudget

        static let selectedOmissions: [Self] = [.quoteOmittedBudget, .detailOmittedBudget]
        static let recalledOmissions: [Self] = [.recalledQuoteOmittedBudget, .recalledDetailOmittedBudget]
        var isRecalled: Bool { Self.recalledOmissions.contains(self) }
        var isQuote: Bool { self == .quoteOmittedBudget || self == .recalledQuoteOmittedBudget }
        static let snapshotOmissions: [Self] = [.agentIdentityOmittedBudget, .groupOmittedBudget]

        /// Reserve only snapshot classes that might have something to omit.
        func canFire(_ snapshot: ConversationSnapshot) -> Bool {
            switch self {
            case .agentIdentityOmittedBudget:
                return snapshot.identity?.agentProfile != nil
            case .groupOmittedBudget:
                return !snapshot.sources.isEmpty
            case .quoteOmittedBudget, .detailOmittedBudget, .recalledQuoteOmittedBudget,
                 .recalledDetailOmittedBudget, .recentPrefixBudget:
                return false
            }
        }
    }
    /// A maximum-size byte count bounds any actual aggregate from a snapshot class.
    private static func snapshotDisclosureFloor(_ snapshot: ConversationSnapshot)
        -> [(DisclosureReason, BrainContextTruncation)] {
        DisclosureReason.snapshotOmissions.filter { $0.canFire(snapshot) }.map { reason in
            (reason, .init(evidenceID: nil, originalUTF8Bytes: Int.max,
                           includedUTF8Bytes: 0, reason: reason.rawValue))
        }
    }
    private static func aggregateNotice(_ reason: DisclosureReason, entries: [BrainContextTruncation])
        -> BrainContextTruncation {
        var total = 0
        for entry in entries {
            let (sum, overflow) = total.addingReportingOverflow(entry.originalUTF8Bytes)
            total = overflow ? Int.max : sum
        }
        return .init(evidenceID: nil, originalUTF8Bytes: total, includedUTF8Bytes: 0,
                     reason: reason.rawValue,
                     omittedEvidenceCount: (DisclosureReason.selectedOmissions.contains(reason) || reason.isRecalled) ? entries.count : nil)
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
                                totalWindowTokens: request.budget.contextTokens), truncations: draft.truncations,
              sourceUses: draft.sourceUses.isEmpty ? nil : draft.sourceUses)
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
        for claim in snapshot.claims.reversed() where Self.admitsLegacySelection(claim) {
            claims.append(claim)
            if try JSONEncoder().encode(input()).count > limit { claims.removeLast() }
        }
        for source in snapshot.sources.reversed() {
            references.append(Self.metadata(source.evidence))
            if try JSONEncoder().encode(input()).count > limit { references.removeLast() }
        }
        return input()
    }
    private static func admitsLegacySelection(_ claim: BrainClaim) -> Bool {
        !(claim.subject == BrainIdentity.userID && claim.predicate == ConsolidationIdentityClaim.namePredicate)
            && !BrainStore.requiresTurnSource(claim.predicate) && RecallClaimPredicate(rawValue: claim.predicate) == nil
    }

    private func assemble(_ snapshot: ConversationSnapshot, request: BrainContextRequest, selection: ConversationSelection,
                          interaction: BrainInteractionState?, recall: RecallContextContent?) throws -> BrainContextBundle {
        let originals = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.evidence.id, $0.evidence) })
        let claims = Dictionary(uniqueKeysWithValues: snapshot.claims
            .filter(Self.admitsLegacySelection).map { ($0.id, $0) })
        guard selection.detailEvidenceIDs.allSatisfy({ originals[$0] != nil }),
              selection.quoteEvidenceIDs.allSatisfy({ originals[$0] != nil }),
              selection.claimIDs.allSatisfy({ claims[$0] != nil }) else { throw BrainStoreError.denied }
        var available = Dictionary(uniqueKeysWithValues: snapshot.memoryEvidence.map { ($0.id, $0) })
        for (id, source) in originals { available[id] = source }
        for source in recall?.originals ?? [] { available[source.id] = source }
        for source in (recall?.blocks ?? []).flatMap(\.sources) where available[source.id] == nil {
            available[source.id] = source
        }
        var draft = Draft()
        func adding(to old: Draft, block: String? = nil, units: [BrainMessageUnit] = [], ids: [String] = [],
                    renderedUse: BrainContextSourceUse? = nil,
                    truncations: [BrainContextTruncation] = [], prependUnits: Bool = false) -> Draft {
            var next = old
            if let block { next.blocks.append(block) }
            next.units = prependUnits ? units + next.units : next.units + units
            for id in ids {
                guard let evidence = available[id] else { continue }
                next.references[id] = Self.metadata(evidence)
                if let renderedUse { next.recordUse(renderedUse, id: id) }
            }
            for unit in units {
                guard let original = originals[unit.id]?.text else { continue }
                let use: BrainContextSourceUse = unit.text.utf8.count == original.utf8.count ? .recentWhole : .recentPrefix
                next.recordUse(use, id: unit.id)
            }
            next.truncations += truncations
            return next
        }
        @discardableResult func add(block: String? = nil, units: [BrainMessageUnit] = [], ids: [String] = [],
                                    renderedUse: BrainContextSourceUse? = nil,
                                    truncations: [BrainContextTruncation] = [], prependUnits: Bool = false,
                                    maximumInput: Int? = nil) throws -> Bool {
            let next = adding(to: draft, block: block, units: units, ids: ids, renderedUse: renderedUse,
                              truncations: truncations, prependUnits: prependUnits)
            guard try fits(next, request: request, revision: snapshot.revision) else { return false }
            if let maximumInput, try estimatedInput(next, request: request, revision: snapshot.revision) > maximumInput { return false }
            draft = next; return true
        }
        let quotes = Set(selection.quoteEvidenceIDs)
        var seen = Set<String>()
        var selected = try (selection.quoteEvidenceIDs + selection.detailEvidenceIDs).compactMap { id -> SelectedOriginal? in
            guard seen.insert(id).inserted else { return nil }
            guard let text = originals[id]?.text else { throw BrainStoreError.invalid }
            return SelectedOriginal(id: id, text: text,
                                    reason: quotes.contains(id) ? .quoteOmittedBudget : .detailOmittedBudget)
        }
        if let recall {
            for source in recall.originals where seen.insert(source.id).inserted {
                guard let text = source.text else { throw BrainStoreError.invalid }
                selected.append(.init(id: source.id, text: text,
                    reason: recall.quotes.contains(source.id) ? .recalledQuoteOmittedBudget : .recalledDetailOmittedBudget))
            }
        }
        let requested = Dictionary(grouping: selected, by: \.reason)
        var remaining = requested.mapValues(\.count)
        var reservations = Dictionary(uniqueKeysWithValues: Self.snapshotDisclosureFloor(snapshot))
        // One notice per selected class covers the case where every original is omitted. Actual
        // omissions can only shrink the count and byte sum, so their aggregate also fits.
        for (reason, originals) in requested {
            reservations[reason] = Self.aggregateNotice(reason, entries: originals.map(\.omission))
        }
        draft.truncations = (DisclosureReason.selectedOmissions + DisclosureReason.snapshotOmissions)
            .compactMap { reservations[$0] }
        guard try fits(draft, request: request, revision: snapshot.revision) else {
            throw BrainContextAssemblyError.insufficientBudget
        }
        var pending = [DisclosureReason: [BrainContextTruncation]]()
        func disclose(_ reason: DisclosureReason, _ entries: [BrainContextTruncation]) {
            precondition(reservations[reason] != nil, "\(reason.rawValue) has no disclosure reservation")
            pending[reason, default: []] += entries
        }
        func releasing(_ reason: DisclosureReason, from draft: Draft) -> Draft {
            guard let reserved = reservations[reason] else { return draft }
            var released = draft
            released.truncations.removeAll { $0 == reserved }
            return released
        }
        let timeline = Dictionary(uniqueKeysWithValues: snapshot.sources.enumerated().map { ($0.element.evidence.id, $0.offset) })
        let groups = ConversationCompactor.groups(snapshot.sources).sorted {
            (timeline[$0.last?.evidence.id ?? ""] ?? -1) < (timeline[$1.last?.evidence.id ?? ""] ?? -1)
        }
        func recentUnits(_ group: [ConversationSource], cap: Int? = nil) -> [BrainMessageUnit] {
            group.map { source in
                let original = source.evidence.text ?? ""
                let text = cap.map { Self.prefix(original, maximumUTF8Bytes: $0) } ?? original
                return .init(id: source.evidence.id, speakerID: source.evidence.speakerID, text: text,
                             observedAt: source.evidence.observedAt, evidenceIDs: [source.evidence.id], groupID: source.groupID)
            }
        }
        func fitsWithNewestGroup(_ draft: Draft) throws -> Bool {
            guard let newest = groups.last else { return false }
            let withNewest = adding(to: draft, units: recentUnits(newest), ids: newest.map { $0.evidence.id })
            return try fits(withNewest, request: request, revision: snapshot.revision)
        }
        func finalizeDisclosures(_ reasons: [DisclosureReason], preserveNewest: Bool = false) throws {
            for reason in reasons {
                let released = releasing(reason, from: draft)
                guard let entries = pending[reason], !entries.isEmpty else {
                    draft = released
                    continue
                }
                let aggregate = Self.aggregateNotice(reason, entries: entries)
                let collapsed = adding(to: released, truncations: [aggregate])
                guard try fits(collapsed, request: request, revision: snapshot.revision) else {
                    throw BrainContextAssemblyError.insufficientBudget
                }
                // Prefer names, registering their metadata with the notice. When finalizing
                // selected omissions early, keep room for a newest whole group that could fit
                // with the aggregate. The group remains higher priority than extra metadata.
                let itemized = adding(to: released, ids: entries.compactMap(\.evidenceID), truncations: entries)
                if try fits(itemized, request: request, revision: snapshot.revision),
                   try (!preserveNewest || !fitsWithNewestGroup(collapsed) || fitsWithNewestGroup(itemized)) {
                    draft = itemized
                } else {
                    draft = collapsed
                }
            }
        }
        // The agent's identity gets its own section. It goes in before any conversation content,
        // so sheer conversation volume cannot evict who the assistant is, and after the mandatory
        // omission notices, so it cannot take the space an original's disclosure is owed. It is
        // never folded in with user memories: a `[memory]` block is something the user told the
        // brain, an `[agent ...]` block is not, and a reader must be able to tell which is which.
        if let identity = snapshot.identity, identity.agentProfile != nil {
            for evidence in snapshot.identityEvidence { available[evidence.id] = evidence }
            let identityIDs = snapshot.identityEvidence.map(\.id)
            let core = Self.identityCoreBlock(identity, sourceIDs: identityIDs)
            // The core is one indivisible unit, offered against the capacity that remains rather
            // than against the section's own slice. An identity assertion that keeps `name=` and
            // drops the values and the boundaries — the only statement in the system that the
            // agent has no childhood, body or suffering — is strictly worse than no identity
            // section at all, so this is a mandatory reservation and not a best effort.
            if try add(block: core, ids: identityIDs, renderedUse: .derivedSupport) {
                let base = try estimatedInput(draft, request: request, revision: snapshot.revision)
                let limit = base + max(0, (capacity(request.budget) - base) / 4)
                // The optional tail lives in its own quarter of what is left, so the identity
                // cannot evict the conversation. Priority descends — character, then what this
                // installation can do, then experience — and the first block that does not fit
                // stops the rest, so two budgets differ by a prefix of the section rather than by
                // an arbitrary subset of it.
                for (block, ids) in Self.identityOptionalBlocks(identity, resolvable: { available[$0] != nil }) {
                    if try !add(block: block, ids: ids, renderedUse: .derivedSupport, maximumInput: limit) { break }
                }
            } else {
                // Nothing goes missing silently: the caller is told the section did not fit,
                // through the same disclosure mechanism an omitted original uses. The entry
                // carries no `evidenceID` — it describes a rendered section, and `self:agent` is
                // a subject, not a source a caller could look up in `sourceReferences`.
                disclose(.agentIdentityOmittedBudget,
                         [.init(evidenceID: nil, originalUTF8Bytes: core.utf8.count,
                                includedUTF8Bytes: 0,
                                reason: DisclosureReason.agentIdentityOmittedBudget.rawValue)])
            }
        }
        if let name = snapshot.confirmedUserName {
            try add(block: "Confirmed user name: \(name.value)", ids: [name.evidenceID], renderedUse: .derivedSupport)
        }
        func admitOriginal(_ original: SelectedOriginal) throws {
            let reason = original.reason
            let isQuote = reason.isQuote
            let label = (reason.isRecalled ? "recalled " : "") + (isQuote ? "original quote" : "original detail")
            let base = remaining[reason] == 1 ? releasing(reason, from: draft) : draft
            let delivered = adding(to: base, block: "[\(label) source=\(original.id)]\n\(original.text)",
                                   ids: [original.id], renderedUse: isQuote ? .renderedQuote : .renderedDetail)
            if try fits(delivered, request: request, revision: snapshot.revision) {
                draft = delivered
                remaining[reason, default: 0] -= 1
            } else {
                disclose(reason, [original.omission])
            }
        }
        for original in selected where !original.reason.isRecalled { try admitOriginal(original) }
        try finalizeDisclosures(DisclosureReason.selectedOmissions, preserveNewest: true)
        for id in selection.claimIDs {
            guard let claim = claims[id] else { continue }
            try add(block: "[memory]\n" + BrainStore.encode(claim), ids: snapshot.claimEvidenceIDs[id] ?? [],
                    renderedUse: .derivedSupport)
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
                        try add(block: block, ids: statement.evidenceIDs, renderedUse: .derivedSupport,
                                maximumInput: stateLimit)
                    }
                }
            }
        }
        // Recent raw groups are adaptive to budget. Summarized old groups default to gist;
        // the newest group remains raw even when a background compaction just covered it.
        let covered = Set(snapshot.segments.flatMap { $0.sources.map(\.evidenceID) })
        let newest = groups.last?.first?.groupID
        let recent = groups.filter { group in group.first?.groupID == newest || group.contains { !covered.contains($0.evidence.id) } }
        func admitRecentGroup(_ group: [ConversationSource]) throws {
            let ids = group.map { $0.evidence.id }
            if try add(units: recentUnits(group), ids: ids, prependUnits: true) { return }
            // Keep all members of an oversized group, or none. Each retained prefix is marked.
            var low = 0, high = group.map { $0.evidence.text?.utf8.count ?? 0 }.max() ?? 0
            var best: Draft?
            while low <= high {
                let mid = low + (high - low) / 2
                let partial = recentUnits(group, cap: mid)
                let truncations = zip(group, partial).compactMap { source, unit -> BrainContextTruncation? in
                    let bytes = source.evidence.text?.utf8.count ?? 0
                    guard unit.text.utf8.count < bytes else { return nil }
                    return .init(evidenceID: source.evidence.id, originalUTF8Bytes: bytes,
                                 includedUTF8Bytes: unit.text.utf8.count,
                                 reason: DisclosureReason.recentPrefixBudget.rawValue)
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
                disclose(.groupOmittedBudget, group.map { .init(evidenceID: $0.evidence.id,
                    originalUTF8Bytes: $0.evidence.text?.utf8.count ?? 0, includedUTF8Bytes: 0,
                    reason: DisclosureReason.groupOmittedBudget.rawValue) })
            }
        }
        if let newestGroup = recent.last { try admitRecentGroup(newestGroup) }
        // Explicit recalled originals reserve their mandatory omission notice only after
        // the baseline newest local group has been admitted without optional recall pressure.
        let recalledReservations = DisclosureReason.recalledOmissions.compactMap { reservations[$0] }
        guard try add(truncations: recalledReservations) else { throw BrainContextAssemblyError.insufficientBudget }
        for original in selected where original.reason.isRecalled { try admitOriginal(original) }
        try finalizeDisclosures(DisclosureReason.recalledOmissions)
        var deferredRecall = [RecallContextContent.Block]()
        if let recall, !recall.blocks.isEmpty {
            let spent = try estimatedInput(draft, request: request, revision: snapshot.revision)
            let room = capacity(request.budget) - spent
            let firstLimit = spent + (recent.count > 1 ? room / 2 : room)
            for block in recall.blocks {
                if try !add(block: block.text, ids: block.sources.map(\.id), renderedUse: block.use,
                            maximumInput: firstLimit) { deferredRecall.append(block) }
            }
        }
        for group in recent.dropLast().reversed() { try admitRecentGroup(group) }
        try finalizeDisclosures(DisclosureReason.snapshotOmissions)
        for block in deferredRecall {
            try add(block: block.text, ids: block.sources.map(\.id), renderedUse: block.use)
        }
        // Guidance uses whatever capacity remains after original evidence and required notices.
        // Render only bounded cues, never the model's affect label or the source text again.
        if let advice = AffectiveContextService.advice(claims: snapshot.claims, threadID: request.threadID,
                                                       evidence: { $0.compactMap { available[$0] } }) {
            let guidance = advice.mode == .listen ? "Listen without offering unsolicited advice."
                : "Offer advice when it is useful and relevant to the request."
            try add(block: "[expressed conversation preference]\n" + guidance, ids: advice.evidenceIDs,
                    renderedUse: .derivedSupport)
        }
        if let interaction, interaction.evidenceIDs.allSatisfy({ originals[$0] != nil }) {
            let cues = interaction.cues
            var guidance = [String]()
            if cues.focus == .stayWithTopic { guidance.append("Stay with the current topic.") }
            if cues.focus == .clarifyGoal { guidance.append("Clarify the goal briefly if needed.") }
            if cues.interest == .exploreTopic { guidance.append("Leave room to explore the topic.") }
            if cues.interest == .acknowledgeProgress { guidance.append("Acknowledge progress when it is grounded.") }
            if cues.tension == .slowDown { guidance.append("Use a patient pace and keep the response easy to follow.") }
            if cues.tension == .respondCalmly { guidance.append("Respond calmly and directly.") }
            try add(block: "[optional conversation guidance]\n" + guidance.joined(separator: " "),
                    ids: interaction.evidenceIDs, renderedUse: .derivedSupport)
        }
        draft.units.sort { (timeline[$0.id] ?? -1) < (timeline[$1.id] ?? -1) }
        let estimate = try estimatedInput(draft, request: request, revision: snapshot.revision)
        guard estimate <= capacity(request.budget) else { throw BrainContextAssemblyError.insufficientBudget }
        return bundle(draft, request: request, revision: snapshot.revision, estimate: estimate)
    }
    /// Who the agent is, what it works by, and what it must not claim about itself — one block,
    /// because the parts are not separable. An empty string when there is no agent profile, which
    /// `add` treats as nothing to add.
    ///
    /// `name=` is configuration, not a quotation. It is the current value of a setting the owner
    /// chose, the same in every thread, so it renders in every thread and advertises no source id
    /// of its own; the thread that happened to carry the configuring turn has no claim on it. The
    /// `sources=` header therefore covers only the evidence this block cites — the admitted
    /// identity evidence, passed in by a caller that has already thread-scoped it — and is absent
    /// when there is none. Nothing here is ever rendered as a prefix: a half-written boundary is
    /// worse than no boundary.
    private static func identityCoreBlock(_ identity: BrainIdentity, sourceIDs: [String]) -> String {
        guard let profile = identity.agentProfile else { return "" }
        let sources = sourceIDs.isEmpty ? "" : "\nsources=" + sourceIDs.joined(separator: ",")
        return "[agent identity]\nname=\(identity.displayName)\nnature=\(profile.core.nature)\(sources)\n"
            + "[agent values]\n" + profile.core.values.joined(separator: "\n") + "\n"
            + "[agent boundaries]\n" + profile.core.boundaries.joined(separator: "\n")
    }

    /// Everything after the core, in descending priority: how it was configured to come across,
    /// what this installation can actually do, then the few most recent things that actually
    /// happened. Each carries the ids it cites so they land in `sourceReferences`.
    ///
    /// An experience is only offered when every source it names resolves. An id printed in a
    /// `sources=` header that a caller cannot look up is worse than silence: it invites a later
    /// task to trust an identifier that does not resolve and cannot be forgotten. An experience is
    /// also never rendered as a prefix — a half-quoted utterance of its own is exactly the kind of
    /// thing an assistant should not be left to complete from memory.
    private static func identityOptionalBlocks(_ identity: BrainIdentity,
                                               resolvable: (String) -> Bool) -> [(String, [String])] {
        guard let profile = identity.agentProfile else { return [] }
        let character = profile.character
        var blocks = [("[agent character]\nhumor=\(character.humor.rawValue)\npace=\(character.pace.rawValue)\nformality=\(character.formality.rawValue)\nverbosity=\(character.verbosity.rawValue)", [String]())]
        if !profile.capabilityAddenda.isEmpty {
            blocks.append(("[agent capabilities]\n" + profile.capabilityAddenda.joined(separator: "\n"), []))
        }
        let citable = profile.autobiography.filter { !$0.evidenceIDs.isEmpty && $0.evidenceIDs.allSatisfy(resolvable) }
        for entry in citable.suffix(3) {
            let header = "[agent experience \(entry.qualification.rawValue)"
                + (entry.status.map { " status=\($0.rawValue)" } ?? "")
                + " sources=\(entry.evidenceIDs.joined(separator: ","))]"
            blocks.append((header + "\n" + (entry.redacted ? "(text withheld)" : entry.text), entry.evidenceIDs))
        }
        return blocks
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
