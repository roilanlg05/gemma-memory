import XCTest
@testable import MemoryCore

final class ScheduleStoreTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(path: ":memory:", embeddingDim: 8) }

    @discardableResult
    private func addEvent(_ store: MemoryStore, _ title: String, _ start: Double, _ end: Double,
                          status: String = "scheduled", location: String? = nil) throws -> String {
        let attrs = NodeAttributes(status: status, startAt: start, endAt: end, location: location,
                                   canonicalKey: MemoryText.eventCanonicalKey(title: title, startAt: start))
        let id = UUID().uuidString; let t = start
        let node = Node(id: id, kind: NodeKind.event.rawValue, label: title, body: title, layer: .daily,
                        createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3, decayRate: 0,
                        confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                        origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
        try store.upsert(node)
        return id
    }

    func test_nodeAttributes_roundtrip_eventFields() {
        var a = NodeAttributes()
        a.startAt = 1_000; a.endAt = 4_600; a.allDay = false
        a.location = "Miami"; a.status = "scheduled"; a.canonicalKey = "k1"
        let json = a.toJSON()
        XCTAssertNotNil(json)
        let back = NodeAttributes.from(json)
        XCTAssertEqual(back.startAt, 1_000)
        XCTAssertEqual(back.endAt, 4_600)
        XCTAssertEqual(back.allDay, false)
        XCTAssertEqual(back.location, "Miami")
        XCTAssertEqual(back.status, "scheduled")
        XCTAssertEqual(back.canonicalKey, "k1")
    }

    func test_nodeAttributes_toJSON_nonNil_whenOnlyOneEventFieldSet() {
        var a = NodeAttributes(); a.allDay = true
        XCTAssertNotNil(a.toJSON())
    }

    func test_eventCanonicalKey_collapsesSameStartAndTitle() {
        // 2026-06-04 10:00 and 10:00:30 round to the same minute; title normalized.
        let k1 = MemoryText.eventCanonicalKey(title: "Dentist Appointment", startAt: 1_780_653_600)
        let k2 = MemoryText.eventCanonicalKey(title: "  dentist   appointment ", startAt: 1_780_653_630)
        XCTAssertEqual(k1, k2)
        let k3 = MemoryText.eventCanonicalKey(title: "dentist appointment", startAt: 1_780_657_200) // +1h
        XCTAssertNotEqual(k1, k3)
    }

    func test_eventsOverlap_rules() {
        // [0,10) vs [10,20) touch at the edge → NO overlap
        XCTAssertFalse(eventsOverlap(0, 10, 10, 20))
        // [0,10) vs [5,15) → overlap
        XCTAssertTrue(eventsOverlap(0, 10, 5, 15))
        // nested [0,100) vs [10,20) → overlap
        XCTAssertTrue(eventsOverlap(0, 100, 10, 20))
        // identical → overlap
        XCTAssertTrue(eventsOverlap(5, 6, 5, 6))
        // disjoint → no overlap
        XCTAssertFalse(eventsOverlap(0, 5, 100, 200))
    }

    func test_scheduleWindow_returnsScheduledInRange_sortedByStart() throws {
        let s = try makeStore()
        try addEvent(s, "B", 200, 260)
        try addEvent(s, "A", 100, 160)
        try addEvent(s, "Out", 10_000, 10_060)
        try addEvent(s, "Cancelled", 120, 180, status: "cancelled")
        let win = try s.scheduleWindow(from: 0, to: 1_000, includeCancelled: false)
        XCTAssertEqual(win.map { $0.label }, ["A", "B"])   // sorted by start, cancelled excluded, Out excluded
        let withCancelled = try s.scheduleWindow(from: 0, to: 1_000, includeCancelled: true)
        XCTAssertEqual(withCancelled.count, 3)
    }

    func test_scheduleConflicts_findsOverlappingScheduledOnly() throws {
        let s = try makeStore()
        try addEvent(s, "Trip", 0, 1_000)
        try addEvent(s, "CancelledTrip", 0, 1_000, status: "cancelled")
        let conflicts = try s.scheduleConflicts(start: 500, end: 600)
        XCTAssertEqual(conflicts.map { $0.label }, ["Trip"])   // cancelled not a conflict
        XCTAssertEqual(try s.scheduleConflicts(start: 2_000, end: 2_100).count, 0)
    }
}
