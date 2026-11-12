import Foundation
import BrainContract

/// Why a proposed identity statement was refused.
///
/// There is no "accept it weakly" option: an identity statement that cannot be traced to the user
/// asserting it is rejected outright. Confidence is not a substitute for evidence, and a stored
/// low-confidence identity would still be read back later as who the user is.
public enum SelfAssertionRejection: String, Error, Equatable, Sendable, CaseIterable {
    /// Nothing usable was proposed.
    case emptyStatement
    /// The label names the agent, or a reserved identity. `self:user`, `self:agent` and
    /// `relationship:user:agent` are different subjects and must never collide by label.
    case reservedSubject
    /// The evidence's access scope does not permit writing the user's identity.
    case scopeNotPermitted
    /// No turn spoken by the user supports this statement (the model paraphrased or invented it).
    case noUserSource
    /// The user's turn mentions it, but not as a first-person assertion about themselves.
    case notFirstPersonAssertion
    /// The user asserted it about themselves, but it is not their name. `self:user` carries only
    /// the name predicate here; traits and autobiography have their own vocabulary elsewhere.
    case notANameAssertion
    /// It appears inside a quotation — someone else's words, repeated.
    case quoted
    /// The user denied it.
    case negated
    /// It was hypothetical, proposed or imagined rather than asserted.
    case hypothetical
    /// Someone else said it about the user.
    case thirdPartyAttributed
    /// The user explicitly marked it as not meant seriously.
    case sarcasmMarked
}

/// The transcript turn that supports an accepted identity statement, and the evidence id that
/// turn adapts to. Identity is written only together with this binding.
public struct SelfAssertionSupport: Equatable, Sendable {
    public let rowID: String
    public let threadID: String
    public let seq: Int
    public let evidenceID: String
}

/// Decides whether a `kind: self` extraction may be written to the singleton `self:user` node.
///
/// The model proposes; this validator is what authorizes. Three things must hold, and all three
/// are checked against the raw transcript rather than against the model's paraphrase:
///
/// 1. **The speaker is the user.** Only rows whose transcript `role` is `user` count. An assistant
///    turn saying "you are Roilan" is the agent's belief, not the user's assertion.
/// 2. **It is an actual naming.** The user's own words must *name* them — "me llamo X", "my name
///    is X", "call me X" — and that clause must not be quoted, negated, hypothetical, attributed
///    to a third party, or explicitly disavowed. A copular self-description ("soy diabético") is a
///    genuine first-person assertion and is still refused here, because the only predicate this
///    path writes is the user's name and a later name supersedes the earlier one: accepting a
///    condition would rename the user and retire their real name.
/// 3. **The scope permits it.** The authorization must hold the `user` scope, and the supporting
///    evidence must not be agent-scoped or shared.
///
/// A model's paraphrase of "my wife says I am stubborn" is therefore not the user asserting that
/// they are stubborn, and is rejected.
public enum SelfAssertionValidator {

    /// Labels that name the agent or a structural identity. A user-identity extraction may never
    /// write one of these, whatever the model proposes.
    static let reservedLabels: Set<String> = [
        "gemma", "jarvis", "assistant", "asistente", "agent", "agente", "ai", "bot",
        "self", "user", "usuario", "yo", "me", "i",
    ]

    /// Explicit namings: the user says what they are *called*. These are the only openings that
    /// may set the `name` predicate, because that predicate answers "who is the user" and a later
    /// value supersedes the earlier one.
    private static let namingPrefixes: [String] = [
        "me llamo ", "mi nombre es ", "mi nombre completo es ", "llamame ", "puedes llamarme ",
        "my name is ", "my full name is ", "call me ", "name's ", "they call me ",
    ]

    /// Copular self-descriptions: the user says what they *are*. "soy diabético" is a true
    /// first-person assertion and is still not a name, so it is recognised in order to be
    /// rejected with that reason rather than written as one. Traits and autobiography have their
    /// own subjects and predicates elsewhere; inventing one here is not this validator's job.
    private static let copularPrefixes: [String] = [
        "yo soy ", "soy ", "i am ", "i'm ", "im ", "me llaman ",
    ]

    /// Verbs that attribute a statement to somebody other than the speaker.
    private static let attributionMarkers: [String] = [
        "dice ", "dicen ", "dijo ", "dijeron ", "decia ", "cree ", "creen ", "piensa ", "piensan ",
        "says ", "say ", "said ", "told ", "claims ", "claimed ", "thinks ", "think ",
        "according to ", "segun ", "me dicen ",
    ]

    private static let negationMarkers: [String] = [
        "no ", "not ", "never ", "nunca ", "jamas ", "tampoco ", "isn't ", "aren't ", "don't ",
    ]

    private static let hypotheticalMarkers: [String] = [
        "si ", "if ", "imagina", "imagine", "supon", "suppose", "pretend", "digamos",
        "let's say ", "lets say ", "hypothetic", "hipotetic", "sería", "seria ", "would be ",
        "ojala", "quisiera ", "me gustaria ", "i wish ", "podria llamarme ",
    ]

    private static let disavowalMarkers: [String] = [
        "just kidding", "kidding", " jk", "/s", "es broma", "era broma", "es mentira",
        "mentira", "sarcasm", "sarcasmo", "ironia", "ironía",
    ]

    /// Accept only an entire, unqualified introduction for immediate admission. Longer or
    /// ambiguous statements may still be evaluated by the existing source-bound validator.
    static func directName(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = fold(trimmed)
        guard !disavowalMarkers.contains(where: normalized.contains),
              let prefix = namingPrefixes.first(where: normalized.hasPrefix) else { return nil }
        let raw = String(trimmed.dropFirst(prefix.count))
        let name = raw.last.map { ".!".contains($0) } == true ? String(raw.dropLast()) : raw
        let words = name.split(separator: " ")
        let qualifiers: Set<String> = ["and", "or", "but", "because", "y", "o", "pero", "aunque", "porque",
                                       "said", "says", "dijo", "dice", "segun", "si", "if", "would", "seria"]
        guard (1...4).contains(words.count), name.count <= 64,
              name.range(of: #"\A[\p{L}][\p{L}\p{M}'’ -]*[\p{L}\p{M}]\z|\A[\p{L}]\z"#,
                         options: .regularExpression) != nil,
              words.allSatisfy({ !qualifiers.contains(fold(String($0))) }),
              !reservedLabels.contains(MemoryText.dedupKey(name)), !MemoryText.isJunkLabel(name) else { return nil }
        return name
    }

    /// Validate a proposed identity statement against the turns it supposedly came from.
    ///
    /// - Parameters:
    ///   - label: the canonical label the model proposed for the user.
    ///   - sources: the transcript rows of the segment the extraction was made from.
    ///   - permittedScopes: scopes the engine's own trusted authorization holds.
    ///   - evidenceScope: the access scope the adapted evidence carries.
    public static func validate(label: String,
                                sources: [TranscriptRow],
                                permittedScopes: Set<BrainAccessScope>,
                                evidenceScope: BrainAccessScope) -> Result<SelfAssertionSupport, SelfAssertionRejection> {
        let canonical = MemoryText.canonicalEntityLabel(label)
        guard !canonical.isEmpty else { return .failure(.emptyStatement) }
        // The reserved check comes first: naming the agent is a more specific and more useful
        // refusal than "unusable label", even when the label would also be rejected as junk.
        guard !reservedLabels.contains(MemoryText.dedupKey(canonical)) else { return .failure(.reservedSubject) }
        guard !MemoryText.isJunkLabel(canonical) else { return .failure(.emptyStatement) }
        guard permittedScopes.contains(.user), evidenceScope == .user || evidenceScope == .thread else {
            return .failure(.scopeNotPermitted)
        }

        let needle = fold(canonical)
        guard !needle.isEmpty else { return .failure(.emptyStatement) }

        var best: SelfAssertionRejection = .noUserSource
        // Newest turn first: the most recent self-identification is the one that counts.
        for row in sources.filter({ ConsolidationEvidenceAdapter.speaker(role: $0.role) == .user })
                          .sorted(by: { $0.seq > $1.seq }) {
            switch inspect(row: row, needle: needle) {
            case .success:
                return .success(SelfAssertionSupport(rowID: row.id, threadID: row.threadId, seq: row.seq,
                                                     evidenceID: ConsolidationEvidenceAdapter.evidenceID(for: row)))
            case .failure(let rejection):
                if rank(rejection) > rank(best) { best = rejection }
            }
        }
        return .failure(best)
    }

    // MARK: single row

    private static func inspect(row: TranscriptRow,
                                needle: String) -> Result<Void, SelfAssertionRejection> {
        let text = fold(normalizeQuotes(row.text))
        guard text.range(of: needle) != nil else { return .failure(.noUserSource) }
        if disavowalMarkers.contains(where: { text.contains($0) }) { return .failure(.sarcasmMarked) }

        let quoted = quotedRanges(in: text)
        var best: SelfAssertionRejection = .notFirstPersonAssertion
        func escalate(_ rejection: SelfAssertionRejection) {
            if rank(rejection) > rank(best) { best = rejection }
        }
        for clause in clauses(of: text) {
            guard let hit = clause.text.range(of: needle) else { continue }
            // Where does this occurrence sit in the whole turn? Needed for quote detection.
            let offset = clause.text.distance(from: clause.text.startIndex, to: hit.lowerBound)
            let absolute = text.index(clause.start, offsetBy: offset)
            if quoted.contains(where: { $0.contains(absolute) }) { escalate(.quoted); continue }
            let prefix = String(clause.text[clause.text.startIndex..<hit.lowerBound])
            if attributionMarkers.contains(where: { prefix.contains($0) }) {
                escalate(.thirdPartyAttributed); continue
            }
            if hypotheticalMarkers.contains(where: { prefix.contains($0) }) {
                escalate(.hypothetical); continue
            }
            if negationMarkers.contains(where: { prefix.contains($0) }) { escalate(.negated); continue }
            if namingPrefixes.contains(where: { prefix.hasSuffix($0) }) { return .success(()) }
            if copularPrefixes.contains(where: { prefix.hasSuffix($0) }) {
                escalate(.notANameAssertion); continue
            }
            escalate(.notFirstPersonAssertion)
        }
        return .failure(best)
    }

    /// How informative a rejection is, so the reported reason is the most specific one found.
    private static func rank(_ rejection: SelfAssertionRejection) -> Int {
        switch rejection {
        case .noUserSource: return 0
        case .notFirstPersonAssertion: return 1
        case .notANameAssertion: return 2
        case .quoted: return 3
        case .hypothetical: return 4
        case .negated: return 5
        case .thirdPartyAttributed: return 6
        case .sarcasmMarked: return 7
        case .emptyStatement, .reservedSubject, .scopeNotPermitted: return 8
        }
    }

    // MARK: text helpers

    /// Case- and accent-insensitive folding. Quote characters and punctuation survive, and the
    /// folded string is the only string we index into, so offsets stay consistent.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizeQuotes(_ s: String) -> String {
        var out = s
        for ch in ["\u{201C}", "\u{201D}", "\u{00AB}", "\u{00BB}", "\u{2018}", "\u{2019}"] {
            out = out.replacingOccurrences(of: ch, with: "\"")
        }
        return out
    }

    /// Ranges covered by paired double quotes. An unpaired quote covers nothing.
    private static func quotedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var open: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\"" {
                if let start = open { ranges.append(start..<i); open = nil } else { open = text.index(after: i) }
            }
            i = text.index(after: i)
        }
        return ranges
    }

    private struct Clause { let text: String; let start: String.Index }

    /// Split a turn into clauses on sentence and comma boundaries, keeping each clause's offset in
    /// the original turn. Clause-level checks keep "no me gusta el sushi, me llamo Roilan" from
    /// being read as a negation of the name.
    private static func clauses(of text: String) -> [Clause] {
        var out: [Clause] = []
        var start = text.startIndex
        var i = text.startIndex
        let separators: Set<Character> = [".", ";", "!", "?", "\n", ",", ":"]
        while i < text.endIndex {
            if separators.contains(text[i]) {
                if start < i { out.append(Clause(text: String(text[start..<i]), start: start)) }
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        if start < text.endIndex { out.append(Clause(text: String(text[start..<text.endIndex]), start: start)) }
        return out
    }
}
