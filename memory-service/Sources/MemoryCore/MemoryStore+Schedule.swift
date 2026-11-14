import Foundation
import GRDB

/// Half-open interval overlap: [s1,e1) intersects [s2,e2) iff s1 < e2 ∧ s2 < e1.
/// Touching at an edge (e1 == s2) is NOT an overlap.
public func eventsOverlap(_ s1: Double, _ e1: Double, _ s2: Double, _ e2: Double) -> Bool {
    s1 < e2 && s2 < e1
}

/// Result of resolving which event the user means for an edit (time-first).
public enum EditTarget: Sendable {
    case found(Node)
    case none
    case ambiguous([Node])
}

extension MemoryStore {
    /// All `event` nodes whose [start,end) intersects [from,to), sorted by start ascending.
    /// Excludes cancelled unless `includeCancelled`. Pure read.
    public func scheduleWindow(from: Double, to: Double, includeCancelled: Bool = false) throws -> [Node] {
        let events = try allNodes().filter { $0.kind == NodeKind.event.rawValue }
        return events.compactMap { node -> (Node, Double)? in
            let a = NodeAttributes.from(node.extra)
            guard let s = a.startAt, let e = a.endAt else { return nil }
            if !includeCancelled, a.status == "cancelled" { return nil }
            guard eventsOverlap(s, e, from, to) else { return nil }
            return (node, s)
        }
        .sorted { $0.1 < $1.1 }
        .map { $0.0 }
    }

    /// Scheduled events overlapping the proposed [start,end). Cancelled/done excluded.
    /// `excluding` drops nodes by id so an edit never conflicts with the event being edited.
    public func scheduleConflicts(start: Double, end: Double, excluding: Set<String> = []) throws -> [Node] {
        try dbQueue.read { db in
            try Self.scheduleConflicts(in: Self.liveEvents(db), start: start, end: end, excluding: excluding)
        }
    }

    private static func liveEvents(_ db: Database) throws -> [Node] {
        try Node.filter(Column("kind") == NodeKind.event.rawValue && Column("deleted") == false).fetchAll(db)
    }

    private static func scheduleConflicts(in events: [Node], start: Double, end: Double,
                                          excluding: Set<String>) -> [Node] {
        events.filter { node in
            guard !excluding.contains(node.id) else { return false }
            let a = NodeAttributes.from(node.extra)
            guard let s = a.startAt, let e = a.endAt, a.status == "scheduled" else { return false }
            return eventsOverlap(s, e, start, end)
        }
    }

    /// The ONLY supported way to create an event. Always runs scheduleConflicts.
    /// Returns (id, conflicts) on create; (nil, conflicts) when blocked by a conflict and !force.
    @discardableResult
    public func createEventChecked(title: String, start: Double, end: Double, allDay: Bool,
                                   location: String?, origin: Origin, force: Bool,
                                   checkpoint: ConsolidationCheckpoint? = nil)
        throws -> (id: String?, conflicts: [Node]) {
        let key = MemoryText.eventCanonicalKey(title: title, startAt: start)
        let result: (id: String?, conflicts: [Node]) = try dbQueue.write { db in
            let events = try Self.liveEvents(db)
            let existing = Self.matchingEvent(in: events, key: key)
            if let existing, Self.retainsEvent(existing, against: origin) {
                try Self.recordMatchedEvent(checkpoint, db: db)
                return (existing.id, [])
            }
            let conflicts = Self.scheduleConflicts(in: events, start: start, end: end,
                                                   excluding: existing.map { [$0.id] } ?? [])
            if !conflicts.isEmpty && !force { return (nil, conflicts) }
            let id = try Self.writeEvent(title: title, start: start, end: end, allDay: allDay,
                                         location: location, origin: origin, key: key,
                                         existing: existing, checkpoint: checkpoint, db: db)
            return (id, conflicts)
        }
        if let id = result.id { try? linkToHub(nodeId: id, kindRaw: NodeKind.event.rawValue) }
        return result
    }

    /// Create or update an event, deduping by canonicalKey. Returns the node id.
    @discardableResult
    public func upsertEvent(title: String, start: Double, end: Double, allDay: Bool,
                            location: String?, origin: Origin,
                            checkpoint: ConsolidationCheckpoint? = nil) throws -> String {
        let key = MemoryText.eventCanonicalKey(title: title, startAt: start)
        let id = try dbQueue.write { db in
            let existing = try Self.matchingEvent(in: Self.liveEvents(db), key: key)
            if let existing, Self.retainsEvent(existing, against: origin) {
                try Self.recordMatchedEvent(checkpoint, db: db)
                return existing.id
            }
            return try Self.writeEvent(title: title, start: start, end: end, allDay: allDay,
                                       location: location, origin: origin, key: key,
                                       existing: existing, checkpoint: checkpoint, db: db)
        }
        try? linkToHub(nodeId: id, kindRaw: NodeKind.event.rawValue)
        return id
    }

    private static func matchingEvent(in events: [Node], key: String) -> Node? {
        events.first { node in
            guard let start = NodeAttributes.from(node.extra).startAt else { return false }
            return MemoryText.eventCanonicalKey(title: node.label, startAt: start) == key
        }
    }

    private static func retainsEvent(_ event: Node, against origin: Origin) -> Bool {
        origin == .extracted && (event.origin == .explicit || NodeAttributes.from(event.extra).appleEventId != nil)
    }

    private static func recordMatchedEvent(_ checkpoint: ConsolidationCheckpoint?, db: Database) throws {
        guard let checkpoint else { return }
        try writeReceipt(db, jobID: checkpoint.jobID, operationID: checkpoint.operationID,
                         phase: checkpoint.phase, outcome: .committed, committed: 1,
                         refused: 0, unresolved: 0, stage: nil, retryable: false, at: checkpoint.at)
    }

    private static func writeEvent(title: String, start: Double, end: Double, allDay: Bool,
                                   location: String?, origin: Origin, key: String, existing: Node?,
                                   checkpoint: ConsolidationCheckpoint?, db: Database) throws -> String {
        let now = Date().timeIntervalSince1970
        var attrs = NodeAttributes(status: "scheduled", startAt: start, endAt: end,
                                   allDay: allDay, location: location, canonicalKey: key)
        if let existing {
            var node = existing
            let old = NodeAttributes.from(existing.extra)
            attrs = old
            attrs.startAt = start; attrs.endAt = end; attrs.allDay = allDay
            attrs.location = location; attrs.canonicalKey = key
            if existing.label != title || old.startAt != start || old.endAt != end || old.allDay != allDay || old.location != location { attrs.contentUpdatedAt = now }
            let existingStatus = old.status
            if existingStatus == "cancelled" || existingStatus == "done" {
                attrs.status = existingStatus   // don't resurrect a cancelled/done event
            }
            node.label = title; node.body = title; node.updatedAt = now; node.lastSeenAt = now
            if origin == .explicit { node.origin = .explicit }
            node.extra = attrs.toJSON(); node.dirty = true
            try writeNode(node, checkpoint: checkpoint, db: db)
            return existing.id
        } else {
            attrs.contentUpdatedAt = now
            let id = UUID().uuidString
            let node = Node(id: id, kind: NodeKind.event.rawValue, label: title, body: title, layer: .daily,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0,
                            confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                            origin: origin, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
            try writeNode(node, checkpoint: checkpoint, db: db)
            return id
        }
    }

    /// Soft-cancel: set status="cancelled" on the given ids, or on all scheduled events in [from,to).
    /// Returns the count changed. Cancelled events are retained (for future notifications).
    @discardableResult
    public func cancelEvents(ids: [String]? = nil, from: Double? = nil, to: Double? = nil) throws -> Int {
        let targets: [Node]
        if let ids, !ids.isEmpty {
            targets = try ids.compactMap { try node(id: $0) }.filter { $0.kind == NodeKind.event.rawValue }
        } else if let from, let to {
            targets = try scheduleWindow(from: from, to: to, includeCancelled: false)
        } else {
            return 0
        }
        var changed = 0
        let now = Date().timeIntervalSince1970
        for var node in targets {
            var a = NodeAttributes.from(node.extra)
            guard a.status != "cancelled" else { continue }
            a.status = "cancelled"
            node.extra = a.toJSON(); node.updatedAt = now; node.dirty = true
            try upsert(node)
            changed += 1
        }
        return changed
    }

    /// Resolve which scheduled event the user means for an edit, anchored on TIME.
    /// Candidates = scheduled events on the same calendar day as `start` (server TZ), optionally
    /// filtered by `title` (case-insensitive). One candidate → .found; several → prefer an
    /// exact-minute start match, else .ambiguous; none → .none.
    /// Note: with a single same-day candidate it returns .found regardless of how far `start` is
    /// from the event's time (the `< 60s` tolerance only disambiguates among multiple candidates).
    public func findEditTarget(start: Double, title: String?) throws -> EditTarget {
        let cal = Calendar.current
        let day = Date(timeIntervalSince1970: start)
        var candidates = try allNodes().filter { node in
            guard node.kind == NodeKind.event.rawValue else { return false }
            let a = NodeAttributes.from(node.extra)
            guard a.status == "scheduled", let s = a.startAt else { return false }
            return cal.isDate(Date(timeIntervalSince1970: s), inSameDayAs: day)
        }
        if let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            candidates = candidates.filter { $0.label.caseInsensitiveCompare(title) == .orderedSame }
        }
        if candidates.isEmpty { return .none }
        if candidates.count == 1 { return .found(candidates[0]) }
        let exact = candidates.filter { node in
            guard let s = NodeAttributes.from(node.extra).startAt else { return false }
            return abs(s - start) < 60   // within a minute = the same start
        }
        if exact.count == 1 { return .found(exact[0]) }
        return .ambiguous(candidates)
    }

    /// Edit an event in place: override ONLY the provided fields, keep the same node id, recompute
    /// canonicalKey, stay scheduled. `location == ""` clears it; nil leaves a field unchanged.
    /// Precondition: caller passes a scheduled event (e.g. a `.found` from `findEditTarget`); this
    /// leaves `status` untouched, so it must not be used to edit a cancelled/done node.
    /// The effective [start,end) an edit will produce. A start-only move (newStart set, newEnd nil)
    /// shifts the end by the same delta so the event keeps its duration. Centralized so the
    /// pre-edit conflict check and the persisted event always agree. Pure (no I/O).
    public func effectiveEditInterval(for node: Node, newStart: Double?, newEnd: Double?) -> (start: Double, end: Double) {
        let a = NodeAttributes.from(node.extra)
        let oldStart = a.startAt ?? newStart ?? 0
        let oldEnd = a.endAt ?? oldStart
        let start = newStart ?? oldStart
        let end: Double
        if let newEnd {
            end = newEnd
        } else if newStart != nil {
            end = oldEnd + (start - oldStart)   // start-only move preserves duration
        } else {
            end = oldEnd
        }
        return (start, end)
    }

    @discardableResult
    public func applyEventEdit(_ node: Node, newTitle: String? = nil, newStart: Double? = nil,
                               newEnd: Double? = nil, location: String? = nil, allDay: Bool? = nil) throws -> Node {
        var node = node
        var a = NodeAttributes.from(node.extra)
        let trimmed = newTitle?.trimmingCharacters(in: .whitespaces)
        let effTitle = (trimmed?.isEmpty == false) ? trimmed! : node.label
        let interval = effectiveEditInterval(for: node, newStart: newStart, newEnd: newEnd)
        let old = a
        a.startAt = interval.start
        a.endAt = interval.end
        if let allDay { a.allDay = allDay }
        if let location { a.location = location.isEmpty ? nil : location }
        a.canonicalKey = MemoryText.eventCanonicalKey(title: effTitle, startAt: a.startAt ?? 0)
        let now = Date().timeIntervalSince1970
        if node.label != effTitle || old.startAt != a.startAt || old.endAt != a.endAt || old.allDay != a.allDay || old.location != a.location { a.contentUpdatedAt = now }
        node.label = effTitle; node.body = effTitle
        node.updatedAt = now; node.lastSeenAt = now
        node.extra = a.toJSON(); node.dirty = true
        try upsert(node)
        return node
    }
}
