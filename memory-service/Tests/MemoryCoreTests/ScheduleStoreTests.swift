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
}
