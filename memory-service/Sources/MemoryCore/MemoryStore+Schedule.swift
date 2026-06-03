import Foundation
import GRDB

/// Half-open interval overlap: [s1,e1) intersects [s2,e2) iff s1 < e2 ∧ s2 < e1.
/// Touching at an edge (e1 == s2) is NOT an overlap.
public func eventsOverlap(_ s1: Double, _ e1: Double, _ s2: Double, _ e2: Double) -> Bool {
    s1 < e2 && s2 < e1
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
    public func scheduleConflicts(start: Double, end: Double) throws -> [Node] {
        let events = try allNodes().filter { $0.kind == NodeKind.event.rawValue }
        return events.filter { node in
            let a = NodeAttributes.from(node.extra)
            guard let s = a.startAt, let e = a.endAt, a.status == "scheduled" else { return false }
            return eventsOverlap(s, e, start, end)
        }
    }

    /// Create or update an event, deduping by canonicalKey. Returns the node id.
    @discardableResult
    public func upsertEvent(title: String, start: Double, end: Double, allDay: Bool,
                            location: String?, origin: Origin) throws -> String {
        let key = MemoryText.eventCanonicalKey(title: title, startAt: start)
        let existing = try allNodes().first { node in
            node.kind == NodeKind.event.rawValue && NodeAttributes.from(node.extra).canonicalKey == key
        }
        let now = Date().timeIntervalSince1970
        let attrs = NodeAttributes(status: "scheduled", startAt: start, endAt: end,
                                   allDay: allDay, location: location, canonicalKey: key)
        if let existing {
            var node = existing
            node.label = title; node.body = title; node.updatedAt = now; node.lastSeenAt = now
            node.extra = attrs.toJSON(); node.dirty = true
            try upsert(node)
            return existing.id
        } else {
            let id = UUID().uuidString
            let node = Node(id: id, kind: NodeKind.event.rawValue, label: title, body: title, layer: .daily,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0,
                            confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                            origin: origin, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
            try upsert(node)
            return id
        }
    }

    /// Soft-cancel: set status="cancelled" on the given ids, or on all scheduled events in [from,to).
    /// Returns the count changed. Cancelled events are retained (for future notifications).
    @discardableResult
    public func cancelEvents(ids: [String]? = nil, from: Double? = nil, to: Double? = nil) throws -> Int {
        let targets: [Node]
        if let ids {
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
}
