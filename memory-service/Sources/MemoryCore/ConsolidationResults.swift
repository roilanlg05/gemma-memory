import Foundation

/// Where in a phase something went wrong. A stage is about the *mechanism* that failed, never
/// about the content it was processing, so a stage is always safe to log and to persist.
public enum ConsolidationStage: String, Equatable, Sendable, CaseIterable {
    /// The model call itself did not produce usable text (transport error, timeout, empty reply).
    case generation
    /// Text came back but no well-formed result could be decoded from it.
    case parse
    /// The result was understood but could not be written to the database.
    case persist
    /// The write was lawfully refused (a retracted record, a managed node, an unproven identity).
    case authorization
}

/// Why a phase did not finish. Content-free by construction: `code` is drawn from a fixed
/// vocabulary the engine itself writes, never from model output or user text, so a persisted
/// receipt cannot leak what the user said.
public struct ConsolidationFailure: Error, Equatable, Sendable {
    public let stage: ConsolidationStage
    /// Whether running the same phase again could plausibly succeed. A model that returned
    /// garbage is retryable; a write the store refuses on principle is not.
    public let retryable: Bool
    public let code: String

    public init(stage: ConsolidationStage, retryable: Bool, code: String) {
        self.stage = stage; self.retryable = retryable; self.code = code
    }

    public static func generation(_ code: String) -> ConsolidationFailure {
        .init(stage: .generation, retryable: true, code: code)
    }
    public static func parse(_ code: String) -> ConsolidationFailure {
        .init(stage: .parse, retryable: true, code: code)
    }
    public static func persist(_ code: String) -> ConsolidationFailure {
        .init(stage: .persist, retryable: true, code: code)
    }
    /// A write the store rejected on principle rather than by accident — a merge whose subject
    /// does not match, a constraint the content violates. Running it again changes nothing, so it
    /// is not retryable, and that distinction is what makes a receipt's `retryable` worth reading.
    public static func constraint(_ code: String) -> ConsolidationFailure {
        .init(stage: .persist, retryable: false, code: code)
    }
}

/// A write the store lawfully refused. Kept separate from a failure: the refusal *is* the correct
/// outcome (the user retracted that content, or the node is owned by the claim store), so it must
/// be reported rather than retried, and it must not stop the cycle from completing.
public struct ConsolidationRefusal: Equatable, Sendable {
    public let stage: ConsolidationStage
    public let code: String
    public init(stage: ConsolidationStage = .authorization, code: String) {
        self.stage = stage; self.code = code
    }
}

/// What a phase actually did. "Ran and found nothing" is `empty` — a success — and is never
/// retried; "could not do its work" is `failed` and carries the stage and retryability.
public struct ConsolidationPhaseResult: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable { case committed, empty, failed }

    public let phase: SleepPhase
    public let outcome: Outcome
    /// Units the phase persisted (nodes, edges, summaries, embeddings — phase-defined).
    public let committed: Int
    /// Writes the store lawfully refused. Reported, never retried.
    public let refusals: [ConsolidationRefusal]
    public let failure: ConsolidationFailure?

    init(phase: SleepPhase, outcome: Outcome, committed: Int = 0,
         refusals: [ConsolidationRefusal] = [], failure: ConsolidationFailure? = nil) {
        self.phase = phase; self.outcome = outcome; self.committed = committed
        self.refusals = refusals; self.failure = failure
    }

    public static func committed(_ phase: SleepPhase, _ count: Int,
                                 refusals: [ConsolidationRefusal] = []) -> ConsolidationPhaseResult {
        .init(phase: phase, outcome: .committed, committed: count, refusals: refusals)
    }
    public static func empty(_ phase: SleepPhase,
                             refusals: [ConsolidationRefusal] = []) -> ConsolidationPhaseResult {
        .init(phase: phase, outcome: .empty, refusals: refusals)
    }
    public static func failed(_ phase: SleepPhase, _ failure: ConsolidationFailure,
                              committed: Int = 0,
                              refusals: [ConsolidationRefusal] = []) -> ConsolidationPhaseResult {
        .init(phase: phase, outcome: .failed, committed: committed, refusals: refusals, failure: failure)
    }

    public var didFail: Bool { outcome == .failed }
    public var isRetryable: Bool { failure?.retryable ?? false }

    /// A phase that produced something, found nothing, or was lawfully refused has nothing left to
    /// do; only a failure is worth running again.
    var succeeded: Bool { outcome != .failed }
}

/// Everything one cycle did, phase by phase. `inputsConsolidated` is the honesty bit: it is true
/// only when the phases that *read* the transcript turns all succeeded and the turns were marked
/// in the same transaction that closed the cycle.
public struct ConsolidationCycleReport: Equatable, Sendable {
    public var jobID: String
    public var results: [ConsolidationPhaseResult]
    /// True only when every turn the job owned was absorbed. False while any unit failed, even
    /// though other units committed — which is why `results` still carries their counts: a cycle
    /// reports "completed with N turns kept", never a blanket success or a blanket failure.
    public var inputsConsolidated: Bool
    /// Turns left un-consolidated because the unit covering them failed. They stay available, so a
    /// later cycle picks them up again together with whatever has arrived since.
    public var unresolvedInputs: Int
    public var cancelled: Bool

    init(jobID: String, results: [ConsolidationPhaseResult] = [],
         inputsConsolidated: Bool = false, unresolvedInputs: Int = 0, cancelled: Bool = false) {
        self.jobID = jobID; self.results = results
        self.inputsConsolidated = inputsConsolidated
        self.unresolvedInputs = unresolvedInputs; self.cancelled = cancelled
    }

    public var refusals: [ConsolidationRefusal] { results.flatMap { $0.refusals } }
    public func result(for phase: SleepPhase) -> ConsolidationPhaseResult? {
        results.first { $0.phase == phase }
    }
}

extension SleepPhase {
    /// Phases that read the transcript turns a job owns. Only these can lose content: if one of
    /// them fails, the turns it was given must stay un-consolidated so a later cycle re-reads them.
    /// The remaining phases operate over the whole graph and their failure costs nothing permanent.
    var consumesJobInputs: Bool {
        switch self {
        case .nrem, .summarize, .detect: return true
        case .embeddings, .cluster, .tag, .rem, .reflect, .compress, .clarify, .curate, .shy: return false
        }
    }
}

/// One consolidation job: the transcript turns it owns, the evidence those turns were adapted
/// into, and the timezone its relative dates resolve in. The timezone is stored *per job* so a
/// cycle that resumes days later still dates "tomorrow" the way the user meant it.
public struct ConsolidationJob: Equatable, Sendable {
    public let id: String
    public var phase: SleepPhase
    public let transcriptIDs: [String]
    public var evidenceIDs: [String]
    public let timeZoneIdentifier: String
    public let startedAt: Double

    public init(id: String, phase: SleepPhase, transcriptIDs: [String], evidenceIDs: [String],
                timeZoneIdentifier: String, startedAt: Double) {
        self.id = id; self.phase = phase; self.transcriptIDs = transcriptIDs
        self.evidenceIDs = evidenceIDs; self.timeZoneIdentifier = timeZoneIdentifier
        self.startedAt = startedAt
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// Deterministic job id: the same input set always yields the same id, so receipts written
    /// before a crash are still found by the process that resumes the work.
    public static func identifier(transcriptIDs: [String]) -> String {
        "job:" + ConsolidationDigest.hex(transcriptIDs.sorted().joined(separator: "\u{1}"))
    }

    /// Stable operation id for one phase of this job. A replay recomputes exactly this string.
    public func operationID(for phase: SleepPhase) -> String { "\(id):\(phase.rawValue)" }

    /// Stable operation id for one independent item inside a phase, so a retry after a partial
    /// failure skips the items that already landed instead of writing them a second time.
    public func operationID(for phase: SleepPhase, item key: String) -> String {
        "\(id):\(phase.rawValue):item:" + ConsolidationDigest.hex(key)
    }

    /// Stable operation id for one input unit in one phase.
    ///
    /// Units are the grain at which input work succeeds or fails: one unprocessable conversation
    /// slice must not stop the others from being absorbed, so each carries its own receipt with
    /// its own stage and reason.
    public func operationID(for phase: SleepPhase, unit key: String) -> String {
        "\(id):\(phase.rawValue):unit:" + key
    }

    /// Stable operation id for the job's single completion record.
    public var completionOperationID: String { id + ":complete" }
}

/// A persisted phase receipt: what the phase did, and how many times it has been attempted.
public struct ConsolidationReceipt: Equatable, Sendable {
    public let jobID: String
    public let operationID: String
    public let phase: SleepPhase
    public let outcome: ConsolidationPhaseResult.Outcome
    public let committed: Int
    public let refused: Int
    /// Input turns this receipt left un-absorbed. Non-zero on a unit that failed and on the
    /// completion receipt of a cycle that kept turns back.
    public let unresolved: Int
    public let stage: ConsolidationStage?
    public let retryable: Bool
    public let attempts: Int
    public let at: Double

    public var succeeded: Bool { outcome != .failed }
}

/// A checkpoint to persist in the SAME transaction as the content it accounts for.
///
/// An item's write and its receipt in two transactions leaves a window where the write survives
/// and the checkpoint does not; the replay then reinforces what it already stored. Passing this
/// down to the store closes that window: either both land or neither does.
public struct ConsolidationCheckpoint: Sendable {
    public let jobID: String
    public let operationID: String
    public let phase: SleepPhase
    public let at: Double

    public init(jobID: String, operationID: String, phase: SleepPhase, at: Double) {
        self.jobID = jobID; self.operationID = operationID; self.phase = phase; self.at = at
    }
}

/// One contiguous slice of one thread, sized for a single generation. Carries its own rows so the
/// speaker of every line is the transcript's recorded role — never inferred from the text — and so
/// relative dates anchor on when the turns were actually spoken.
public struct ConsolidationSegment: Equatable, Sendable {
    public let threadID: String
    public let rows: [TranscriptRow]
    /// Pre-rendered lines, for the text-only entry points that have no rows to offer. A segment
    /// built this way carries no speaker attribution and no timestamps, so identity extraction
    /// cannot be substantiated from it and relative dates fall back to the clock.
    private let rawTexts: [String]?
    private let rawRange: ClosedRange<Int>?

    public init(threadID: String, rows: [TranscriptRow]) {
        self.threadID = threadID; self.rows = rows; self.rawTexts = nil; self.rawRange = nil
    }

    public init(threadID: String, texts: [String], range: ClosedRange<Int>? = nil) {
        self.threadID = threadID; self.rows = []; self.rawTexts = texts; self.rawRange = range
    }

    /// Role-prefixed lines, oldest first.
    public var texts: [String] {
        rawTexts ?? rows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
    }
    public var seqRange: ClosedRange<Int> {
        if let rawRange { return rawRange }
        let seqs = rows.map { $0.seq }
        return (seqs.min() ?? 0)...(seqs.max() ?? 0)
    }
    /// The moment this segment was spoken: the newest turn in it. Relative dates in the segment
    /// ("tomorrow") are the user's "tomorrow", not consolidation's.
    public var anchorAt: Double? { rows.map { $0.createdAt }.max() }

    /// The turns this unit covers. These are the turns that stay un-consolidated if it fails.
    public var inputIDs: Set<String> { Set(rows.map { $0.id }) }

    /// Stable key identifying this unit by the turns it covers, so a receipt written for it in one
    /// attempt is found again in the next.
    public var unitKey: String {
        ConsolidationDigest.hex(rows.map { $0.id }.sorted().joined(separator: "\u{1}"))
    }

    /// Split transcript rows into per-thread, char-budgeted segments, chronological by thread.
    /// A segment never spans two threads and never grows past `maxChars`, so one generation always
    /// sees a coherent slice of one conversation.
    public static func segments(_ rows: [TranscriptRow], maxChars: Int = 6_000) -> [ConsolidationSegment] {
        Dictionary(grouping: rows, by: { $0.threadId })
            .sorted { ($0.value.map(\.createdAt).min() ?? 0) < ($1.value.map(\.createdAt).min() ?? 0) }
            .flatMap { threadID, threadRows -> [ConsolidationSegment] in
                var out: [ConsolidationSegment] = []
                var batch: [TranscriptRow] = []
                var chars = 0
                for row in threadRows.sorted(by: { $0.seq < $1.seq }) {
                    if !batch.isEmpty, chars + row.text.count > maxChars {
                        out.append(ConsolidationSegment(threadID: threadID, rows: batch))
                        batch = []; chars = 0
                    }
                    batch.append(row); chars += row.text.count
                }
                if !batch.isEmpty { out.append(ConsolidationSegment(threadID: threadID, rows: batch)) }
                return out
            }
    }
}
