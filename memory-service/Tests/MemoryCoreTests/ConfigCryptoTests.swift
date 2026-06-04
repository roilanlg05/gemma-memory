import XCTest
import Foundation
@testable import MemoryCore

final class ConfigCryptoTests: XCTestCase {
    func test_roundTrip_sameToken() throws {
        let c = ConfigCrypto(bearerToken: "tok-abc")
        let blob = try c.seal("my-api-key")
        XCTAssertNotEqual(blob, Data("my-api-key".utf8))     // ciphertext, not plaintext
        XCTAssertEqual(try c.open(blob), "my-api-key")
    }
    func test_wrongToken_failsToOpen() throws {
        let blob = try ConfigCrypto(bearerToken: "tok-abc").seal("k")
        XCTAssertThrowsError(try ConfigCrypto(bearerToken: "different").open(blob))
    }
}
