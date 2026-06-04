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

    func test_upsertEvent_dedupsByCanonicalKey() throws {
        let s = try makeStore()
        let id1 = try s.upsertEvent(title: "dentist", start: 1_780_653_600, end: 1_780_657_200,
                                    allDay: false, location: nil, origin: .explicit)
        let id2 = try s.upsertEvent(title: "  Dentist ", start: 1_780_653_630, end: 1_780_657_200,
                                    allDay: false, location: "clinic", origin: .explicit)
        XCTAssertEqual(id1, id2, "same canonicalKey → update, not duplicate")
        let events = try s.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(NodeAttributes.from(events[0].extra).location, "clinic", "update applied")
    }

    func test_cancelEvents_byWindow_softCancels() throws {
        let s = try makeStore()
        try addEvent(s, "A", 100, 160)
        try addEvent(s, "Out", 10_000, 10_060)
        let n = try s.cancelEvents(from: 0, to: 1_000)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try s.scheduleConflicts(start: 100, end: 160).count, 0, "cancelled no longer conflicts")
        let still = try s.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertEqual(still.count, 2, "cancelled is retained, not deleted")
    }

    func test_cancelEvents_idempotent_onAlreadyCancelled() throws {
        let s = try makeStore()
        try addEvent(s, "A", 100, 160)
        XCTAssertEqual(try s.cancelEvents(from: 0, to: 1_000), 1)
        XCTAssertEqual(try s.cancelEvents(from: 0, to: 1_000), 0)
    }

    func test_cancelEvents_byId_ignoresNonEventNodes() throws {
        let s = try makeStore()
        let eventId = try addEvent(s, "A", 100, 160)
        // a non-event id (random) and... nothing else; only the event id should be cancellable
        XCTAssertEqual(try s.cancelEvents(ids: ["does-not-exist"]), 0)
        XCTAssertEqual(try s.cancelEvents(ids: [eventId]), 1)
    }

    func test_upsertEvent_doesNotResurrectCancelled() throws {
        let s = try makeStore()
        let id = try s.upsertEvent(title: "dentist", start: 1000, end: 4600,
                                   allDay: false, location: nil, origin: .explicit)
        XCTAssertEqual(try s.cancelEvents(ids: [id]), 1)
        // re-upsert same canonicalKey (e.g. consolidate sees the appointment again)
        _ = try s.upsertEvent(title: "dentist", start: 1000, end: 4600,
                              allDay: false, location: "clinic", origin: .extracted)
        XCTAssertEqual(try s.scheduleConflicts(start: 1000, end: 4600).count, 0,
                       "a cancelled event must stay cancelled after re-upsert")
    }

    func testScheduleTimeEpochLocalExact() {
        let ny = TimeZone(identifier: "America/New_York")!
        // 2026-06-09 06:00 local → exact, minute-aligned (no 06:13:20 UTC drift)
        let e = ScheduleTime.epoch(date: "2026-06-09", time: "06:00", tz: ny)!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        let comps = cal.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: e))
        XCTAssertEqual(comps.hour, 6); XCTAssertEqual(comps.minute, 0); XCTAssertEqual(comps.second, 0)
    }

    func testScheduleTimeDateOnlyIsMidnight() {
        let ny = TimeZone(identifier: "America/New_York")!
        let e = ScheduleTime.epoch(date: "2026-06-09", time: nil, tz: ny)!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        XCTAssertEqual(cal.dateComponents([.hour], from: Date(timeIntervalSince1970: e)).hour, 0)
    }

    func testScheduleTimeBadInputIsNil() {
        XCTAssertNil(ScheduleTime.epoch(date: "not-a-date", time: "06:00", tz: .current))
    }
}
