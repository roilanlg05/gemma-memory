import Foundation
import GRDB

/// Half-open interval overlap: [s1,e1) intersects [s2,e2) iff s1 < e2 ∧ s2 < e1.
/// Touching at an edge (e1 == s2) is NOT an overlap.
public func eventsOverlap(_ s1: Double, _ e1: Double, _ s2: Double, _ e2: Double) -> Bool {
    s1 < e2 && s2 < e1
}
