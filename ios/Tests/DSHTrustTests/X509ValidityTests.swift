import XCTest
@testable import DSHTrust

/// A self-signed P-256 certificate, notBefore 2024-01-01, notAfter 2030-06-15
/// 12:00:00 UTC. Generated once with `cryptography`; the DER is what the parser
/// has to read, not a re-encoding of it.
private let fixtureBase64 = """
MIIBKTCB0KADAgECAgQHW80VMAoGCCqGSM49BAMCMB0xGzAZBgNVBAMMEkRTSCBNb2JpbGUgVGVzdCBDQTAeFw0yNDAxMDEwMDAwMDBaFw0z\
MDA2MTUxMjAwMDBaMB0xGzAZBgNVBAMMEkRTSCBNb2JpbGUgVGVzdCBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPESE3K9/0TqnKoM\
tTiXRCZZYLYXufd/jYesy5dvYEfJrSZHAMSX8D4joOcz3gthF9BpWW+wWDEiy9SD2p+AcGcwCgYIKoZIzj0EAwIDSAAwRQIgLpAS8Vf5Zysj\
tN2mAwIfZRtAvK+mK1dyiv44MPSXEQECIQClZOGisyv9MR6urHZ+KR05N3IPZz/kG/50PGOozusZ8w==
"""

final class X509ValidityTests: XCTestCase {
    private var der: Data {
        Data(base64Encoded: fixtureBase64.replacingOccurrences(of: "\n", with: "")) ?? Data()
    }

    func testReadsTheValidityWindow() throws {
        let notAfter = try XCTUnwrap(X509Validity.notAfter(der: der))
        let notBefore = try XCTUnwrap(X509Validity.notBefore(der: der))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let after = calendar.dateComponents([.year, .month, .day, .hour], from: notAfter)
        XCTAssertEqual(after.year, 2030)
        XCTAssertEqual(after.month, 6)
        XCTAssertEqual(after.day, 15)
        XCTAssertEqual(after.hour, 12)

        let before = calendar.dateComponents([.year, .month, .day], from: notBefore)
        XCTAssertEqual(before.year, 2024)
        XCTAssertEqual(before.month, 1)
        XCTAssertEqual(before.day, 1)
    }

    func testRejectsGarbage() {
        XCTAssertNil(X509Validity.notAfter(der: Data([0x30, 0x00])))
        XCTAssertNil(X509Validity.notAfter(der: Data("not a certificate".utf8)))
        XCTAssertNil(X509Validity.notAfter(der: Data()))
    }

    /// The whole point: an expired CA can be recognised without the macOS-only
    /// `SecCertificateCopyValues` (docs/04 section 2, point 3).
    func testAnExpiredCertificateIsComparableToNow() throws {
        let notAfter = try XCTUnwrap(X509Validity.notAfter(der: der))
        // The fixture expires 2030-06-15; a clock after that must see it expired.
        XCTAssertTrue(notAfter < Date(timeIntervalSince1970: 1_950_000_000))
        XCTAssertFalse(notAfter < Date(timeIntervalSince1970: 1_700_000_000))
    }
}
