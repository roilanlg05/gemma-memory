import XCTest
@testable import MemoryCore

final class ScheduleStoreEditTests: XCTestCase {

    private func store() throws -> MemoryStore { try MemoryStore(path: ":memory:", embeddingDim: 8) }

    /// 2099-03-01 09:00 and 10:00 local, as epoch, for deterministic same-day tests.
    private func epoch(_ iso: String) -> Double {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: iso)!.timeIntervalSince1970
    }

    func test_findEditTarget_found_by_same_day_and_title() throws {
        let s = try store()
        let start = epoch("2099-03-01T09:00"), end = epoch("2099-03-01T10:00")
        _ = try s.upsertEvent(title: "dentist", start: start, end: end, allDay: false, location: nil, origin: .explicit)
        // A slightly-off start on the same day still resolves (tolerant match).
        guard case .found(let n) = try s.findEditTarget(start: epoch("2099-03-01T09:30"), title: "dentist") else {
            return XCTFail("expected .found")
        }
        XCTAssertEqual(n.label, "dentist")
    }

    func test_findEditTarget_none_when_no_event() throws {
        let s = try store()
        guard case .none = try s.findEditTarget(start: epoch("2099-03-01T09:00"), title: nil) else {
            return XCTFail("expected .none")
        }
    }

    func test_findEditTarget_ambiguous_two_same_day_no_exact_match() throws {
        let s = try store()
        _ = try s.upsertEvent(title: "call A", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                              allDay: false, location: nil, origin: .explicit)
        _ = try s.upsertEvent(title: "call B", start: epoch("2099-03-01T14:00"), end: epoch("2099-03-01T15:00"),
                              allDay: false, location: nil, origin: .explicit)
        // No title, a start matching neither exactly → ambiguous.
        guard case .ambiguous(let list) = try s.findEditTarget(start: epoch("2099-03-01T11:00"), title: nil) else {
            return XCTFail("expected .ambiguous")
        }
        XCTAssertEqual(list.count, 2)
    }

    func test_findEditTarget_exact_minute_disambiguates() throws {
        let s = try store()
        _ = try s.upsertEvent(title: "call A", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                              allDay: false, location: nil, origin: .explicit)
        _ = try s.upsertEvent(title: "call B", start: epoch("2099-03-01T14:00"), end: epoch("2099-03-01T15:00"),
                              allDay: false, location: nil, origin: .explicit)
        guard case .found(let n) = try s.findEditTarget(start: epoch("2099-03-01T14:00"), title: nil) else {
            return XCTFail("expected .found via exact start")
        }
        XCTAssertEqual(n.label, "call B")
    }

    func test_applyEventEdit_location_only_keeps_id_and_time() throws {
        let s = try store()
        let start = epoch("2099-03-01T09:00"), end = epoch("2099-03-01T10:00")
        let id = try s.upsertEvent(title: "dentist", start: start, end: end, allDay: false, location: nil, origin: .explicit)
        let node = try s.node(id: id)!
        let updated = try s.applyEventEdit(node, location: "Miami")
        XCTAssertEqual(updated.id, id)                                  // same node
        let a = NodeAttributes.from(updated.extra)
        XCTAssertEqual(a.location, "Miami")
        XCTAssertEqual(a.startAt, start)                               // time unchanged
    }

    func test_applyEventEdit_time_move_recomputes_canonicalKey() throws {
        let s = try store()
        let id = try s.upsertEvent(title: "dentist", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                                   allDay: false, location: nil, origin: .explicit)
        let node = try s.node(id: id)!
        let newStart = epoch("2099-03-01T11:00")
        let updated = try s.applyEventEdit(node, newStart: newStart, newEnd: epoch("2099-03-01T12:00"))
        XCTAssertEqual(updated.id, id)
        let a = NodeAttributes.from(updated.extra)
        XCTAssertEqual(a.startAt, newStart)
        XCTAssertEqual(a.canonicalKey, MemoryText.eventCanonicalKey(title: "dentist", startAt: newStart))
    }

    func test_applyEventEdit_empty_location_clears_it() throws {
        let s = try store()
        let id = try s.upsertEvent(title: "dentist", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                                   allDay: false, location: "Miami", origin: .explicit)
        let updated = try s.applyEventEdit(try s.node(id: id)!, location: "")
        XCTAssertNil(NodeAttributes.from(updated.extra).location)
    }

    func test_scheduleConflicts_excluding_self() throws {
        let s = try store()
        let id = try s.upsertEvent(title: "dentist", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                                   allDay: false, location: nil, origin: .explicit)
        // Same slot, excluding the event itself → no conflict.
        let none = try s.scheduleConflicts(start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"), excluding: [id])
        XCTAssertTrue(none.isEmpty)
        // A different overlapping event is still detected.
        _ = try s.upsertEvent(title: "gym", start: epoch("2099-03-01T09:30"), end: epoch("2099-03-01T10:30"),
                              allDay: false, location: nil, origin: .explicit)
        let some = try s.scheduleConflicts(start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"), excluding: [id])
        XCTAssertTrue(some.contains { $0.label == "gym" })
    }
}
