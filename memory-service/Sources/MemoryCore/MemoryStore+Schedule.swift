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
}
