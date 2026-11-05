import Foundation

public struct BrainEvaluationMessage: Codable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public var state: String
    public init(id: String, role: String, text: String, state: String = "active") {
        self.id = id; self.role = role; self.text = text; self.state = state
    }
}

public struct BrainEvaluationAssertion: Codable, Hashable, Sendable {
    public var subject: String
    public var predicate: String
    public var value: String
    public var number: Double?
    public var state: String
    public var sourceRole: String
    public var sourceIDs: [String]
    public init(subject: String, predicate: String, value: String, number: Double? = nil, state: String,
         sourceRole: String, sourceIDs: [String]) {
        self.subject = subject; self.predicate = predicate; self.value = value; self.number = number
        self.state = state; self.sourceRole = sourceRole; self.sourceIDs = sourceIDs
    }
}

public struct BrainEvaluationCase: Codable, Sendable {
    public var id: String
    public var category: String
    public var language: String
    public var messages: [BrainEvaluationMessage]
    public var query: String
    public var expectedEvidenceIDs: [String]
    public var expectedAssertions: [BrainEvaluationAssertion]
    public var forbiddenAssertions: [BrainEvaluationAssertion]
    public var legacyRecall: Bool
    public init(id: String, category: String, language: String, messages: [BrainEvaluationMessage], query: String,
         expectedEvidenceIDs: [String], expectedAssertions: [BrainEvaluationAssertion],
         forbiddenAssertions: [BrainEvaluationAssertion], legacyRecall: Bool = false) {
        self.id = id; self.category = category; self.language = language; self.messages = messages; self.query = query
        self.expectedEvidenceIDs = expectedEvidenceIDs; self.expectedAssertions = expectedAssertions
        self.forbiddenAssertions = forbiddenAssertions; self.legacyRecall = legacyRecall
    }
}

public struct BrainEvaluationPrediction: Codable, Sendable {
    public var caseID: String
    public var unsupportedReason: String?
    public var evidenceIDs: [String]
    public var assertions: [BrainEvaluationAssertion]
    public init(caseID: String, unsupportedReason: String? = nil, evidenceIDs: [String], assertions: [BrainEvaluationAssertion]) {
        self.caseID = caseID; self.unsupportedReason = unsupportedReason
        self.evidenceIDs = evidenceIDs; self.assertions = assertions
    }
}

public struct BrainEvaluationCounts: Codable, Sendable {
    public var total = 0
    public var evaluated = 0
    public var unsupported = 0
    public var missing = 0
    public var correct = 0
}

public struct BrainEvaluationResult: Codable, Sendable {
    public var caseID: String
    public var outcome: String
    public var reasons: [String]
}

public struct BrainEvaluationReport: Codable, Sendable {
    public var counts = BrainEvaluationCounts()
    public var byCategory: [String: BrainEvaluationCounts] = [:]
    public var results: [BrainEvaluationResult] = []
    /// Unsupported cases are excluded; absent outputs are included as failures.
    public var exactAssertionAccuracy: Double? {
        let denominator = counts.evaluated + counts.missing
        return denominator == 0 ? nil : Double(counts.correct) / Double(denominator)
    }
    public var coverage: Double? {
        counts.total == 0 ? nil : Double(counts.evaluated) / Double(counts.total)
    }
    public var overallExactAssertionAccuracy: Double? {
        counts.total == 0 ? nil : Double(counts.correct) / Double(counts.total)
    }
}

/// A malformed run is rejected rather than reported as model/system accuracy.
public struct BrainEvaluationValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
}

/// Exact structured contract checks only. Does not infer facts from prose or score lexical overlap.
public enum BrainEvaluation {
    public static func score(cases: [BrainEvaluationCase], predictions: [BrainEvaluationPrediction]) throws -> BrainEvaluationReport {
        var caseIDs = Set<String>()
        for c in cases {
            try require(caseIDs.insert(c.id).inserted, "Duplicate case ID: \(c.id)")
            try validate(c)
        }
        var indexed: [String: BrainEvaluationPrediction] = [:]
        for p in predictions {
            try require(caseIDs.contains(p.caseID), "Unknown prediction case ID: \(p.caseID)")
            try require(indexed[p.caseID] == nil, "Duplicate prediction ID: \(p.caseID)")
            try require(uniqueNonblank(p.evidenceIDs), "Malformed prediction evidence IDs: \(p.caseID)")
            try require(p.assertions.allSatisfy(validShape), "Malformed prediction assertions: \(p.caseID)")
            try require(Set(p.assertions.map(canonical)).count == p.assertions.count, "Duplicate prediction assertions: \(p.caseID)")
            if let reason = p.unsupportedReason {
                try require(nonblank(reason) && p.evidenceIDs.isEmpty && p.assertions.isEmpty,
                            "Unsupported prediction requires a reason and no output: \(p.caseID)")
            }
            indexed[p.caseID] = p
        }

        var report = BrainEvaluationReport()
        for c in cases {
            let result: BrainEvaluationResult
            if let p = indexed[c.id] {
                if let reason = p.unsupportedReason {
                    result = BrainEvaluationResult(caseID: c.id, outcome: "unsupported", reasons: [reason])
                } else {
                    let reasons = discrepancies(c, p)
                    result = BrainEvaluationResult(caseID: c.id, outcome: reasons.isEmpty ? "correct" : "incorrect", reasons: reasons)
                }
            } else {
                result = BrainEvaluationResult(caseID: c.id, outcome: "missing", reasons: ["No prediction supplied"])
            }
            add(result, to: &report.counts)
            var category = report.byCategory[c.category] ?? BrainEvaluationCounts()
            add(result, to: &category)
            report.byCategory[c.category] = category
            report.results.append(result)
        }
        return report
    }

    private static let categories: Set<String> = ["factsCorrections", "temporal", "forgettingProvenance",
                                                  "conversationAffect", "procedure", "failurePortability"]
    private static let roles: Set<String> = ["user", "assistant", "tool", "system"]

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BrainEvaluationValidationError(description: message) }
    }

    private static func nonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func uniqueNonblank(_ values: [String]) -> Bool {
        values.allSatisfy(nonblank) && Set(values).count == values.count
    }

    private static func validShape(_ a: BrainEvaluationAssertion) -> Bool {
        [a.subject, a.predicate, a.value, a.state].allSatisfy(nonblank)
            && roles.contains(a.sourceRole) && !a.sourceIDs.isEmpty && uniqueNonblank(a.sourceIDs)
            && (a.number?.isFinite ?? true)
    }

    private static func canonical(_ a: BrainEvaluationAssertion) -> BrainEvaluationAssertion {
        var result = a
        result.sourceIDs.sort()
        return result
    }

    /// Forbidden claim identity ignores citation/role, so changing a citation cannot evade it.
    private static func claim(_ a: BrainEvaluationAssertion) -> BrainEvaluationAssertion {
        var result = a
        result.sourceIDs = []
        result.sourceRole = ""
        return result
    }

    private static func validate(_ c: BrainEvaluationCase) throws {
        try require(nonblank(c.id) && nonblank(c.query) && categories.contains(c.category)
                    && ["es", "en"].contains(c.language), "Malformed case header: \(c.id)")
        try require(!c.messages.isEmpty && uniqueNonblank(c.messages.map(\.id)), "Malformed source IDs: \(c.id)")
        try require(c.messages.allSatisfy { roles.contains($0.role) && nonblank($0.text)
                    && ["active", "withdrawn"].contains($0.state) }, "Malformed source message: \(c.id)")
        try require(!c.expectedAssertions.isEmpty && !c.expectedEvidenceIDs.isEmpty
                    && uniqueNonblank(c.expectedEvidenceIDs), "Empty or duplicate expectations: \(c.id)")
        let all = c.expectedAssertions + c.forbiddenAssertions
        try require(all.allSatisfy(validShape), "Malformed expected/forbidden assertion: \(c.id)")
        try require(Set(c.expectedAssertions.map(canonical)).count == c.expectedAssertions.count,
                    "Duplicate expected assertion: \(c.id)")
        let sources = Dictionary(uniqueKeysWithValues: c.messages.map { ($0.id, $0) })
        try require(all.allSatisfy { a in a.sourceIDs.allSatisfy { sources[$0]?.role == a.sourceRole } },
                    "Unknown source or wrong expected source role: \(c.id)")
        try require(c.expectedAssertions.allSatisfy { a in a.sourceIDs.allSatisfy { sources[$0]?.state == "active" } },
                    "Expected assertion cites withdrawn evidence: \(c.id)")
        try require(Set(c.expectedEvidenceIDs) == Set(c.expectedAssertions.flatMap(\.sourceIDs)),
                    "Expected evidence differs from assertion citations: \(c.id)")
        let forbidden = Set(c.forbiddenAssertions.map(claim))
        try require(!c.expectedAssertions.contains { forbidden.contains(claim($0)) }, "Contradictory expectations: \(c.id)")
    }

    private static func discrepancies(_ c: BrainEvaluationCase, _ p: BrainEvaluationPrediction) -> [String] {
        var reasons: [String] = []
        if Set(p.evidenceIDs) != Set(c.expectedEvidenceIDs) { reasons.append("Evidence set differs") }
        if Set(p.assertions.map(canonical)) != Set(c.expectedAssertions.map(canonical)) {
            reasons.append("Exact structured assertions differ")
        }
        let forbidden = Set(c.forbiddenAssertions.map(claim))
        if p.assertions.contains(where: { forbidden.contains(claim($0)) }) { reasons.append("Forbidden assertion emitted") }
        let sources = Dictionary(uniqueKeysWithValues: c.messages.map { ($0.id, $0) })
        let citations = p.evidenceIDs + p.assertions.flatMap(\.sourceIDs)
        if citations.contains(where: { sources[$0] == nil }) { reasons.append("Unknown evidence cited") }
        if citations.contains(where: { sources[$0]?.state == "withdrawn" }) { reasons.append("Withdrawn evidence cited") }
        if p.assertions.contains(where: { a in a.sourceIDs.contains { sources[$0]?.role != a.sourceRole } }) {
            reasons.append("Source role differs")
        }
        return reasons
    }

    private static func add(_ result: BrainEvaluationResult, to counts: inout BrainEvaluationCounts) {
        counts.total += 1
        switch result.outcome {
        case "missing": counts.missing += 1
        case "unsupported": counts.unsupported += 1
        default:
            counts.evaluated += 1
            if result.outcome == "correct" { counts.correct += 1 }
        }
    }
}
