import XCTest
@testable import DSHPairing

final class PairingKeyTests: XCTestCase {
    private let instanceId = String(repeating: "a", count: 64)
    private let token = String(repeating: "A", count: 43)

    func testParsesDsh1Key() throws {
        let key = try PairingKey.parse("dsh1." + instanceId + "." + token)
        XCTAssertEqual(key.kind, .dsh1)
        XCTAssertEqual(key.instanceId, instanceId)
        XCTAssertEqual(key.token, token)
        XCTAssertFalse(key.requiresPinnedCertificateAuthority)
    }

    func testParsesDsh2KeyAndRequiresPinnedCA() throws {
        let key = try PairingKey.parse("dsh2." + instanceId + "." + token)
        XCTAssertEqual(key.kind, .dsh2)
        XCTAssertTrue(key.requiresPinnedCertificateAuthority)
    }

    func testTrimsSurroundingWhitespace() throws {
        let raw = "\n  dsh1." + instanceId + "." + token + "\n"
        XCTAssertEqual(try PairingKey.parse(raw).kind, .dsh1)
    }

    func testRejectsEmptyInput() {
        XCTAssertThrowsError(try PairingKey.parse("   ")) { error in
            XCTAssertEqual(error as? PairingError, PairingError.empty)
        }
    }

    func testRejectsWrongNumberOfParts() {
        XCTAssertThrowsError(try PairingKey.parse("dsh1." + instanceId)) { error in
            XCTAssertEqual(error as? PairingError, PairingError.malformedKey)
        }
    }

    func testRejectsUnknownPrefix() {
        XCTAssertThrowsError(try PairingKey.parse("dsh3." + instanceId + "." + token)) { error in
            XCTAssertEqual(error as? PairingError, PairingError.unknownKind("dsh3"))
        }
    }

    func testRejectsShortInstanceId() {
        XCTAssertThrowsError(try PairingKey.parse("dsh1." + String(repeating: "a", count: 63) + "." + token)) { error in
            XCTAssertEqual(error as? PairingError, PairingError.invalidInstanceId)
        }
    }

    func testRejectsUppercaseInstanceId() {
        let upper = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try PairingKey.parse("dsh1." + upper + "." + token)) { error in
            XCTAssertEqual(error as? PairingError, PairingError.invalidInstanceId)
        }
    }

    func testRejectsShortToken() {
        let short = String(repeating: "A", count: 42)
        XCTAssertThrowsError(try PairingKey.parse("dsh1." + instanceId + "." + short)) { error in
            XCTAssertEqual(error as? PairingError, PairingError.invalidToken)
        }
    }

    func testRejectsTokenWithIllegalCharacter() {
        var illegal = String(repeating: "A", count: 42)
        illegal.append("!")
        XCTAssertThrowsError(try PairingKey.parse("dsh1." + instanceId + "." + illegal)) { error in
            XCTAssertEqual(error as? PairingError, PairingError.invalidToken)
        }
    }

    func testDescriptionRoundTrips() throws {
        let raw = "dsh2." + instanceId + "." + token
        XCTAssertEqual(try PairingKey.parse(raw).description, raw)
    }
}
