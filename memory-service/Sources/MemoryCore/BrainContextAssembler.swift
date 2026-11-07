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
        // The envelope and the disclosure floor are checked before the selector runs, so a window
        // that cannot honestly report what it dropped fails before a model is called.
        var empty = Draft()
        empty.truncations = Self.disclosureFloor(snapshot)
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
    /// The disclosure classes whose omissions can only be discovered after content has already
    /// been offered space: the agent identity section, and a recent raw group that would not fit
    /// even as a prefix. Every other omission in this file is known before the thing it describes
    /// is offered, and is reserved at that point.
    ///
    /// One entry per class is reserved before any content is spent. A bundle must never render
    /// with admitted content excluded and no `truncations` to say so, and a disclosure that is
    /// merely attempted after the content has eaten the window is not a disclosure. Reserving
    /// first means the space is already there when the omission is discovered; if the window
    /// cannot hold even this floor, the request is unsatisfiable and fails with
    /// `BrainContextAssemblyError.insufficientBudget` instead of rendering a silent bundle.
    ///
    /// `Int.max` is what makes the reservation sound: a placeholder encodes to at least as many
    /// bytes as the single aggregate notice that may replace it, because that notice carries the
    /// same `reason`, no `evidenceID`, and a byte count that cannot have more decimal digits than
    /// `Int.max` has. Unused placeholders are stripped before the bundle is returned, so a caller
    /// never sees one.
    /// The whole disclosure vocabulary, in one place. The reason strings used to be literals
    /// duplicated across the declaration, the two call sites and the finalizer, which is how a
    /// reason that matched nothing could be recorded and then silently never rendered.
    enum DisclosureReason: String, CaseIterable, Sendable {
        /// An original the model asked to quote or to see in detail was not delivered.
        case quoteOmittedBudget
        case detailOmittedBudget
        /// A recent raw turn was delivered as a marked prefix of itself.
        case recentPrefixBudget
        /// The agent identity section did not fit.
        case agentIdentityOmittedBudget
        /// A recent raw group did not fit, not even as a prefix of every member.
        case groupOmittedBudget

        /// The classes whose omission can only be discovered after content has been offered space,
        /// and which therefore need a reservation held for them through the whole assembly. Every
        /// other reason is reserved against the very thing it describes, at the moment that thing
        /// is offered, which is Task 8's rule and still runs first.
        static let lateDiscovered: [DisclosureReason] = [.agentIdentityOmittedBudget, .groupOmittedBudget]

        /// Whether this class has anything at all it could omit, decided from the snapshot alone
        /// and therefore before a single byte of content has been spent.
        ///
        /// Deliberately conservative: each predicate is a *superset* of the condition that
        /// actually produces the disclosure — any non-empty source set could yield a recent group,
        /// whether or not this budget ends up omitting one — so a class that might fire is always
        /// reserved for. The cost of being wrong in this direction is a reservation nobody uses,
        /// stripped before the bundle is returned. The cost of being wrong in the other direction
        /// would be an omission with no room left to disclose it, which the invariant forbids.
        ///
        /// The early reasons answer `false` because they never go through the floor.
        func canFire(_ snapshot: ConversationSnapshot) -> Bool {
            switch self {
            case .agentIdentityOmittedBudget:
                return snapshot.identity?.agentProfile != nil
            case .groupOmittedBudget:
                return !snapshot.sources.isEmpty
            case .quoteOmittedBudget, .detailOmittedBudget, .recentPrefixBudget:
                return false
            }
        }
    }
    /// One placeholder per late class that can actually fire for this snapshot. A class that
    /// provably cannot produce a disclosure is charged nothing: a caller with no agent identity at
    /// all was paying 101 bytes for the identity notice, and losing its newest turn across the band
    /// those bytes came out of.
    private static func disclosureFloor(_ snapshot: ConversationSnapshot) -> [BrainContextTruncation] {
        DisclosureReason.lateDiscovered.filter { $0.canFire(snapshot) }.map {
            .init(evidenceID: nil, originalUTF8Bytes: Int.max, includedUTF8Bytes: 0, reason: $0.rawValue)
        }
    }
    private static func isDisclosurePlaceholder(_ truncation: BrainContextTruncation) -> Bool {
        guard truncation.evidenceID == nil, truncation.originalUTF8Bytes == Int.max,
              let reason = DisclosureReason(rawValue: truncation.reason) else { return false }
        return DisclosureReason.lateDiscovered.contains(reason)
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
                         reason: (quotes.contains(id) ? DisclosureReason.quoteOmittedBudget
                                                      : .detailOmittedBudget).rawValue)
        }
        // The notice and the metadata for the id it names are reserved together. An id advertised
        // in a disclosure has to resolve in `sourceReferences`, because that is what makes it
        // followable and a valid forget target; registering it only on a successful delivery meant
        // the entries that reported an omission were exactly the ones whose id resolved to nothing.
        // Registering here, before anything is spent, is also what keeps the reservation honest:
        // the bytes are accounted for whether the original is later delivered or not.
        draft = adding(to: draft, ids: selected, truncations: disclosures)
        // Then the floor for the omissions nobody can predict yet. This comes after the selected
        // originals' notices, which are owed to content a model already asked for, and before any
        // block of content at all.
        draft = adding(to: draft, truncations: Self.disclosureFloor(snapshot))
        guard try fits(draft, request: request, revision: snapshot.revision) else {
            throw BrainContextAssemblyError.insufficientBudget
        }
        // Late-discovered omissions are recorded here and rendered once, in `finalizeDisclosures`.
        // Recording rather than rendering is what keeps the reservation intact while later
        // sections are still being offered content, and it is the single place a disclosure is
        // produced: a future section that omits something calls `disclose` and cannot reintroduce
        // the shape where a failed add silently drops the notice.
        var pending = [DisclosureReason: [BrainContextTruncation]]()
        func disclose(_ reason: DisclosureReason, _ entries: [BrainContextTruncation]) {
            // A reason the finalizer does not visit would be recorded and then never rendered and
            // never reported — the quiet drop this mechanism exists to make impossible. The enum
            // already rules out an unknown string; this rules out a known one that has no
            // reservation behind it. Both are programmer errors, not budget outcomes.
            precondition(DisclosureReason.lateDiscovered.contains(reason),
                         "\(reason.rawValue) is not reserved through the disclosure floor")
            guard !entries.isEmpty else { return }
            pending[reason, default: []] += entries
        }
        func finalizeDisclosures() throws {
            for reason in DisclosureReason.lateDiscovered {
                var released = draft
                released.truncations.removeAll {
                    Self.isDisclosurePlaceholder($0) && $0.reason == reason.rawValue
                }
                guard let entries = pending[reason], !entries.isEmpty else {
                    draft = released
                    continue
                }
                // Prefer naming every omission. The per-original batch is the useful form, so it
                // gets the first chance against whatever capacity is left — and it carries the
                // metadata for every id it names, so those ids resolve.
                let itemized = adding(to: released, ids: entries.compactMap(\.evidenceID),
                                      truncations: entries)
                if try fits(itemized, request: request, revision: snapshot.revision) {
                    draft = itemized
                    continue
                }
                // Otherwise one aggregate notice stands for the whole class. It carries no
                // `evidenceID` because it describes several originals, and the summed byte count
                // saturates rather than overflowing. This is the form the placeholder reserved
                // room for, so it fits; the guard is here because a disclosure that cannot be
                // rendered must fail loudly, never be dropped.
                var total = 0
                for entry in entries {
                    let (sum, overflow) = total.addingReportingOverflow(entry.originalUTF8Bytes)
                    total = overflow ? Int.max : sum
                }
                let aggregate = BrainContextTruncation(evidenceID: nil, originalUTF8Bytes: total,
                                                       includedUTF8Bytes: 0, reason: reason.rawValue)
                let collapsed = adding(to: released, truncations: [aggregate])
                guard try fits(collapsed, request: request, revision: snapshot.revision) else {
                    throw BrainContextAssemblyError.insufficientBudget
                }
                draft = collapsed
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
            if try add(block: core, ids: identityIDs) {
                let base = try estimatedInput(draft, request: request, revision: snapshot.revision)
                let limit = base + max(0, (capacity(request.budget) - base) / 4)
                // The optional tail lives in its own quarter of what is left, so the identity
                // cannot evict the conversation. Priority descends — character, then what this
                // installation can do, then experience — and the first block that does not fit
                // stops the rest, so two budgets differ by a prefix of the section rather than by
                // an arbitrary subset of it.
                for (block, ids) in Self.identityOptionalBlocks(identity, resolvable: { available[$0] != nil }) {
                    if try !add(block: block, ids: ids, maximumInput: limit) { break }
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
        try finalizeDisclosures()
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
