import Foundation
import Crypto
import BrainContract

/// One-way digest used for deterministic ids. A digest of content, never the content.
enum ConsolidationDigest {
    static func hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Turns raw legacy transcript rows into `BrainEvidence` so consolidation's output can be bound
/// back to what was actually said.
///
/// Two rules make this safe to run repeatedly:
///
/// 1. **Deterministic ids and payloads.** An evidence id is derived from
///    `(threadId, seq, digest(text))`, and every field of the record comes from the row, so
///    re-adapting the same row produces a byte-identical record. It cannot become a second,
///    independent root of support for the same sentence, a retry after a crash converges, and a
///    claim may carry its own supporting evidence without colliding with the copy an earlier
///    cycle already stored.
/// 2. **No invented speaker.** The speaker comes from the transcript's own `role` column and from
///    nothing else. A row whose role is neither `user` nor `assistant` yields no evidence at all,
///    because recording it would mean guessing who said it.
public enum ConsolidationEvidenceAdapter {
    /// The principal consolidation acts as. Single-owner brain: the server is acting for the user
    /// whose database this is, so the owner binding is stable across restarts.
    public static let ownerID = "user"
    public static let userSpeakerID = selfUserID
    public static let agentSpeakerID = "self:agent"

    public enum Speaker: Equatable, Sendable {
        case user, agent
        var speakerID: String {
            self == .user ? ConsolidationEvidenceAdapter.userSpeakerID
                          : ConsolidationEvidenceAdapter.agentSpeakerID
        }
        var sourceKind: BrainSourceKind { self == .user ? .userMessage : .assistantMessage }
    }

    /// The transcript's own role, normalised. `nil` means "unknown speaker" — never "the user".
    public static func speaker(role: String) -> Speaker? {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user": return .user
        case "assistant": return .agent
        default: return nil
        }
    }

    /// Stable, content-derived evidence id for a transcript row.
    public static func evidenceID(threadID: String, seq: Int, text: String) -> String {
        "transcript:" + ConsolidationDigest.hex("\(threadID)\u{1}\(seq)\u{1}\(text)")
    }

    public static func evidenceID(for row: TranscriptRow) -> String {
        evidenceID(threadID: row.threadId, seq: row.seq, text: row.text)
    }

    /// The evidence record for one row, or nil when the row cannot be attributed or has no text.
    ///
    /// `recordedAt` is the row's own `createdAt`, not the moment consolidation happened to read
    /// it: the transcript row *is* the record, and it was written when the turn was spoken.
    /// Taking it from the row is also what keeps the payload deterministic, so the same row always
    /// adapts to the same bytes however many cycles touch it.
    public static func evidence(for row: TranscriptRow,
                                scope: BrainAccessScope = .user) -> BrainEvidence? {
        guard let speaker = speaker(role: row.role) else { return nil }
        let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, row.createdAt.isFinite else { return nil }
        return BrainEvidence(id: evidenceID(for: row), sourceKind: speaker.sourceKind,
                             speakerID: speaker.speakerID, threadID: row.threadId,
                             observedAt: row.createdAt, recordedAt: row.createdAt,
                             span: nil, accessScope: scope, text: row.text)
    }

    /// The authorization consolidation grants *itself*, server-side, to record what it read.
    ///
    /// It is deliberately narrow: the owner's own threads, the user scope, the two speakers a
    /// transcript can hold, and nothing else. It never carries `mayForget` — erasure is a
    /// user-driven operation, not something a sleep cycle performs — and none of it is ever
    /// derived from model output.
    public static func authorization(threads: Set<String>) -> BrainAuthorization {
        BrainAuthorization(principal: ownerID, owner: ownerID,
                           subjects: [selfUserID],
                           scopes: [.user],
                           threads: threads,
                           sourceSpeakers: [.userMessage: [userSpeakerID],
                                            .assistantMessage: [agentSpeakerID]],
                           mayProject: false,
                           legacyBindings: [],
                           allowDelegated: false,
                           mayCommitClaims: true,
                           mayForget: false)
    }
}
