import XCTest
@testable import MemoryCore

final class ScheduleStoreTests: XCTestCase {
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

    func test_eventCanonicalKey_collapsesSameStartAndTitle() {
        // 2026-06-04 10:00 and 10:00:30 round to the same minute; title normalized.
        let k1 = MemoryText.eventCanonicalKey(title: "Dentist Appointment", startAt: 1_780_653_600)
        let k2 = MemoryText.eventCanonicalKey(title: "  dentist   appointment ", startAt: 1_780_653_630)
        XCTAssertEqual(k1, k2)
        let k3 = MemoryText.eventCanonicalKey(title: "dentist appointment", startAt: 1_780_657_200) // +1h
        XCTAssertNotEqual(k1, k3)
    }
}
