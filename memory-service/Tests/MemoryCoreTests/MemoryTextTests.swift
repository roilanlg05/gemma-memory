import XCTest
@testable import MemoryCore

/// RC1/RC2 — label normalization that fixes the on-device "me gusta el sushi" labels and the
/// duplicate rows (different phrasings of the same entity).
final class MemoryTextTests: XCTestCase {
    func testStripsLikePrefixAndArticle() {
        XCTAssertEqual(MemoryText.cleanLabel("me gusta el sushi"), "sushi")
        XCTAssertEqual(MemoryText.cleanLabel("Me gusta el sushi"), "sushi")
        XCTAssertEqual(MemoryText.cleanLabel("I like the pizza"), "pizza")
    }

    func testPreservesEntityCase() {
        XCTAssertEqual(MemoryText.cleanLabel("  Juan  "), "Juan")
        XCTAssertEqual(MemoryText.cleanLabel("me gusta Messi"), "Messi")
    }

    func testCollapsesWhitespaceAndPunctuation() {
        XCTAssertEqual(MemoryText.cleanLabel("\"sushi\"."), "sushi")
        XCTAssertEqual(MemoryText.cleanLabel("el   gimnasio"), "gimnasio")
    }

    func testDedupKeyIsCaseInsensitive() {
        XCTAssertEqual(MemoryText.dedupKey("Sushi"), MemoryText.dedupKey("me gusta el sushi"))
        XCTAssertEqual(MemoryText.dedupKey("JUAN"), MemoryText.dedupKey("Juan"))
    }

    func testJunkLabels() {
        XCTAssertTrue(MemoryText.isJunkLabel("me gusta"))
        XCTAssertTrue(MemoryText.isJunkLabel("   "))
        XCTAssertTrue(MemoryText.isJunkLabel("preferences"))
        XCTAssertFalse(MemoryText.isJunkLabel("sushi"))
        XCTAssertFalse(MemoryText.isJunkLabel("Juan"))
    }
}
