import XCTest
@testable import MemoryCore

final class MemoryTextCanonicalTests: XCTestCase {
    func test_strips_user_name_sentence_prefix() {
        XCTAssertEqual(MemoryText.canonicalEntityLabel("User's name is Roilan"), "Roilan")
        XCTAssertEqual(MemoryText.canonicalEntityLabel("the user's name is Roilan"), "Roilan")
        XCTAssertEqual(MemoryText.canonicalEntityLabel("El usuario se llama Roilan"), "Roilan")
    }
    func test_keeps_already_canonical_labels() {
        XCTAssertEqual(MemoryText.canonicalEntityLabel("Roilan"), "Roilan")
        XCTAssertEqual(MemoryText.canonicalEntityLabel("sushi"), "sushi")
    }
    func test_trims_overlong_to_first_words() {
        let out = MemoryText.canonicalEntityLabel("has a medical condition related to vision and eyes")
        XCTAssertFalse(out.isEmpty)
        XCTAssertLessThanOrEqual(out.split(separator: " ").count, 4)
    }
}
