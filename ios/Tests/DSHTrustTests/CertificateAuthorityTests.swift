import XCTest
import Security
@testable import DSHTrust

final class CertificateAuthorityTests: XCTestCase {
    /// Throwaway self-signed CA generated only for this suite.
    private static let base64DER = "MIIC3jCCAcagAwIBAgIUFChF6e2pa6dbmcQ1OI9S2s+wYXkwDQYJKoZIhvcNAQELBQAwHTEbMBkGA1UEAwwSRFNIIE1vYmlsZSBUZXN0IENBMB4XDTI2MDEwMTAwMDAwMFoXDTM1MTIzMDAwMDAwMFowHTEbMBkGA1UEAwwSRFNIIE1vYmlsZSBUZXN0IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA9eVGg0vVXwnjobDLjdDoe4PEFLtEFOFuFuH6PJe18U/CZB85ThpnqGCmN7+qN6PEiNFoWmhdpTKGJIsInnGO0puu3HpEKxY71lBI4MiNJ3EIyU/OeYN7vwlFGOX5FNfryMdDB8xhcx+/mG5sR8q2GqXNT/0wsVjVCsvChutCafXIGUdwsLkMvDbtMVySQRlud4Dz1mHixZoBDqgWNfaCmbZCD4PVGrW1Z6EqfV7Lw+MsTemZf1wXE4/l6n5N6JvzI2f4Lvo3FUbZCPBk1S8+HF8a7qleM1g3xoMpA1KceRe+ta9WfEoFE4AUo7YVD/++Xt2JxTaVUTSqsRnf1utFtQIDAQABoxYwFDASBgNVHRMBAf8ECDAGAQH/AgEAMA0GCSqGSIb3DQEBCwUAA4IBAQCoxb31mHYSCZHBlFUTzEgiK4bG3xXGvxO0JdNDS4maCiB3Z/du28mkwUzAeMedpcwxGzb31oK4+gu7mWW++kVtHTaCATEoG1AbZz5TWtMwng95aEVqtxBjBnGsMenXZf7XtNy4pyIMJ4gC+DcI5nfATJUk0BIsXUGltt4hfX03SFAhlQ79iN8XM4YPtmPITGyE9T2fGP+P7TZqFAcx9lToUBk1Hkw/PWA/fJX7u8mqDo498r7rkK1GQrOI9XBSITKaommYS8EUVoDvKvaXzSqodkiDQrGKIVfBueH/7IlnVNg1VHOtTOF8CeCpaVmYPoBItkg495AMaxkDtj7Oa7xs"
    private static let expectedSHA256 = "8f8773c6b5553d43e3670680a87a0ef2a6c0dc8d52e43cc57e1266396a10997e"

    private func fixtureDER() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: CertificateAuthorityTests.base64DER))
    }

    func testParsesDERAndComputesSHA256() throws {
        let ca = try XCTUnwrap(CertificateAuthority(der: try fixtureDER()))
        XCTAssertEqual(ca.sha256Hex, CertificateAuthorityTests.expectedSHA256)
        XCTAssertEqual(ca.subjectSummary, "DSH Mobile Test CA")
    }

    func testParsesBase64Input() throws {
        let ca = try XCTUnwrap(CertificateAuthority.parse(base64: CertificateAuthorityTests.base64DER))
        XCTAssertEqual(ca.sha256Hex, CertificateAuthorityTests.expectedSHA256)
    }

    func testMatchesInstanceId() throws {
        let ca = try XCTUnwrap(CertificateAuthority(der: try fixtureDER()))
        XCTAssertTrue(ca.matches(instanceId: CertificateAuthorityTests.expectedSHA256))
        XCTAssertTrue(ca.matches(instanceId: "  " + CertificateAuthorityTests.expectedSHA256.uppercased() + "\n"))
        XCTAssertFalse(ca.matches(instanceId: String(repeating: "0", count: 64)))
    }

    func testRejectsGarbage() {
        XCTAssertNil(CertificateAuthority.parse(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(CertificateAuthority.parse(base64: "not base64 at all!"))
    }

    func testFingerprintIsStableLowercaseHex() throws {
        let der = try fixtureDER()
        let fingerprint = CertificateAuthority.fingerprint(der)
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertEqual(fingerprint, fingerprint.lowercased())
        XCTAssertEqual(fingerprint, CertificateAuthority.fingerprint(der))
    }

    func testParsesPEMDocument() throws {
        let base64 = try fixtureDER().base64EncodedString()
        let pem = "-----BEGIN CERTIFICATE-----\n" + base64 + "\n-----END CERTIFICATE-----\n"
        let ca = try XCTUnwrap(CertificateAuthority(pem: pem))
        XCTAssertEqual(ca.sha256Hex, CertificateAuthorityTests.expectedSHA256)
    }
}
