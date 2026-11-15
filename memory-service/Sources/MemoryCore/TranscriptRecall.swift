import BrainContract
import Foundation
import GRDB

/// Bounded, source-backed recall for explicit references to past conversations.
struct TranscriptRecall {
    private static let assistantReference = #"\b(me dijiste|me contaste|me recomendaste|you told|you said|you recommended)\b"#
    private static let reference = #"\b(anteriormente|lo de antes|de la otra vez|recuerda|recuerdo|recuerdas|acuerdas|retoma|te pedi|te dije|te conte|hablamos|mencione|previously|earlier|remember|last time|we discussed|i (asked|said|told))\b"#
    private static let filler: Set<String> = [
        "anterior", "anteriormente", "antes", "asked", "ayudame", "can", "come", "conversacion", "conte", "contaste",
        "agenda", "agendar", "crea", "creame", "cual", "cuentame", "deje", "dije", "dijiste", "dijimos", "dime", "discussed",
        "donde", "don", "earlier", "eso", "esto", "estaba", "estabamos", "find", "fue", "habia", "hablamos", "hace",
        "hablaste", "haz", "hazlo", "last", "mencione", "meses", "month", "months", "pasado",
        "oye", "otro", "otra", "pedi", "pediste", "pedimos", "please", "pon", "previously", "puedes", "quedamos",
        "recordar", "recuerda", "recuerdo", "acuerdas", "recomendaste", "recommended", "retoma", "said", "sobre", "tema", "tell", "tiempo", "time",
        "told", "vez", "want", "year", "years", "ano", "anos", "ago", "chat", "conversation", "would"
    ]

    let query: String
    let asOf: Double

    var isExplicit: Bool {
        asksAboutAssistant || normalized.range(of: Self.reference, options: .regularExpression) != nil
    }

    private var asksAboutAssistant: Bool {
        normalized.range(of: Self.assistantReference, options: .regularExpression) != nil
    }

    private var normalized: String {
        query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    func sources(brain: BrainStore, threadID: String, scope: BrainAccessScope,
                 current: ConversationSnapshot, snapshot: GraphRecallSnapshot, db: Database) throws -> [BrainEvidence] {
        guard isExplicit, scope == .user else { return [] }
        let cue = RecallCue(query)
        let terms = Set(cue.terms.filter { $0.count > 2 && !$0.allSatisfy(\.isNumber) }).subtracting(Self.filler)
        let role = asksAboutAssistant ? "assistant" : "user"
        let sourceKind: BrainSourceKind = asksAboutAssistant ? .assistantMessage : .userMessage
        let speaker = asksAboutAssistant ? BrainIdentity.agentID : BrainIdentity.userID
        let explicitlyOtherChat = normalized.range(of: #"\b(otro chat|chat anterior|otra conversacion|previous chat|another chat)\b"#,
                                                   options: .regularExpression) != nil
        let dates = searchDates(year: cue.year)
        if !explicitlyOtherChat, dates.lower == 0, current.sources.contains(where: { item in
            guard item.evidence.sourceKind == sourceKind, let text = item.evidence.text, text != query else { return false }
            return terms.isEmpty || !terms.isDisjoint(with: RecallCue(text).terms)
        }) { return [] }

        let rows: [TranscriptRow]
        if let pattern = FTS5Pattern(matchingAnyTokenIn: terms.sorted().joined(separator: " ")), !terms.isEmpty {
            rows = try TranscriptRow.fetchAll(db, sql: """
                SELECT t.* FROM transcript_fts JOIN transcript t ON t.rowid=transcript_fts.rowid
                WHERE transcript_fts MATCH ? AND t.threadId<>? AND t.role=? AND t.createdAt BETWEEN ? AND ?
                ORDER BY rank, t.createdAt DESC LIMIT 32
                """, arguments: [pattern.rawPattern, threadID, role, dates.lower, dates.upper])
        } else {
            rows = try TranscriptRow.fetchAll(db, sql: """
                SELECT * FROM transcript WHERE threadId<>? AND role=? AND createdAt BETWEEN ? AND ?
                ORDER BY createdAt DESC, seq DESC LIMIT 12
                """, arguments: [threadID, role, dates.lower == 0 ? asOf - 86_400 : dates.lower, dates.upper])
        }
        var resolver = GraphMemoryQuery.EvidenceResolver(brain: brain, threadID: threadID,
                                                        scope: scope, asOf: asOf, db: db)
        let candidates = try rows.compactMap { row -> (source: BrainEvidence, matches: Int)? in
            guard cue.allows(row.createdAt),
                  try !BrainStore.isExcluded(db, kind: .transcript, id: row.id, fingerprint: BrainStore.transcriptFingerprint(row.text)),
                  let source = try resolver.evidence(ConsolidationEvidenceAdapter.evidenceID(for: row)),
                  source.sourceKind == sourceKind, source.speakerID == speaker, !snapshot.blockedOriginals.contains(source.id) else { return nil }
            guard let text = source.text else { return nil }
            let prior = TranscriptRecall(query: text, asOf: asOf)
            guard prior.normalized != normalized else { return nil }
            let priorTerms = RecallCue(text).terms
            let matches = terms.intersection(priorTerms).count
            // A previous bare reference is a pointer. Keep looking for the message with its details.
            guard !prior.isExplicit || !priorTerms.subtracting(terms.union(Self.filler)).isEmpty else { return nil }
            guard terms.isEmpty || matches > 0 else { return nil }
            return (source, matches)
        }
        return Array(candidates.sorted {
            ($0.matches, $0.source.observedAt, $0.source.id) > ($1.matches, $1.source.observedAt, $1.source.id)
        }.prefix(terms.isEmpty ? 1 : 2).map(\.source))
    }

    private func searchDates(year: Int?) -> (lower: Double, upper: Double) {
        if let year {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            if let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
               let end = calendar.date(byAdding: .year, value: 1, to: start) {
                return (start.timeIntervalSince1970, min(asOf, end.timeIntervalSince1970))
            }
        }
        if normalized.range(of: #"\b(hace un ano|a year ago|one year ago)\b"#,
                            options: .regularExpression) != nil {
            return (asOf - 425 * 86_400, asOf - 305 * 86_400)
        }
        return (0, asOf)
    }

    func excerpt(from source: BrainEvidence) -> String {
        guard let text = source.text else { return "" }
        let terms = RecallCue(query).terms.subtracting(Self.filler)
        let match = terms.compactMap {
            text.range(of: $0, options: [.diacriticInsensitive, .caseInsensitive])?.lowerBound
        }.min()
        let start = match.flatMap { text.index($0, offsetBy: -90, limitedBy: text.startIndex) } ?? text.startIndex
        var bytes = text[start...].utf8.prefix(288)
        var excerpt = String(decoding: bytes, as: UTF8.self)
        while excerpt.hasSuffix("�"), !bytes.isEmpty {
            bytes = bytes.dropLast()
            excerpt = String(decoding: bytes, as: UTF8.self)
        }
        return (start == text.startIndex ? "" : "…") + excerpt + (bytes.count < text[start...].utf8.count ? "…" : "")
    }
}
