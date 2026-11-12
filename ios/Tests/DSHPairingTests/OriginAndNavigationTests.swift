import XCTest
@testable import DSHPairing

final class GatewayOriginTests: XCTestCase {
    func testDefaultHTTPSPortIsEquivalentToExplicit443() throws {
        let implicit = try GatewayOrigin(host: "Example.COM")
        let explicit = try GatewayOrigin(host: "example.com", port: 443)
        XCTAssertEqual(implicit, explicit)
        XCTAssertEqual(implicit.host, "example.com")
        XCTAssertEqual(implicit.effectivePort, 443)
    }

    func testDifferentPortsAreDifferentOrigins() throws {
        let a = try GatewayOrigin(host: "example.com", port: 3443)
        let b = try GatewayOrigin(host: "example.com")
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isSameOrigin(as: b))
    }

    func testDescriptionIncludesNonDefaultPortOnly() throws {
        XCTAssertEqual(try GatewayOrigin(host: "example.com").description, "https://example.com")
        XCTAssertEqual(
            try GatewayOrigin(host: "example.com", port: 3443).description,
            "https://example.com:3443"
        )
    }

    func testPathURLIsAbsolute() throws {
        let origin = try GatewayOrigin(host: "192.168.1.5", port: 3443)
        XCTAssertEqual(
            origin.url(path: "mobile-access/health")?.absoluteString,
            "https://192.168.1.5:3443/mobile-access/health"
        )
    }

    func testRejectsNonHTTPScheme() {
        XCTAssertThrowsError(try GatewayOrigin(scheme: "ftp", host: "example.com")) { error in
            XCTAssertEqual(error as? PairingError, PairingError.unsupportedScheme("ftp"))
        }
    }

    func testRejectsInvalidPort() {
        XCTAssertThrowsError(try GatewayOrigin(host: "example.com", port: 70000)) { error in
            XCTAssertEqual(error as? PairingError, PairingError.invalidPort)
        }
    }

    func testRejectsEmptyHost() {
        XCTAssertThrowsError(try GatewayOrigin(host: "   ")) { error in
            XCTAssertEqual(error as? PairingError, PairingError.missingHost)
        }
    }
}

final class PairingLinkTests: XCTestCase {
    private let token = String(repeating: "A", count: 43)

    func testParsesPairingURLWithToken() throws {
        let raw = "https://192.168.1.5:3443/mobile-access/pair#token=" + token
        let link = try PairingLink.parse(raw)
        XCTAssertEqual(link.origin.host, "192.168.1.5")
        XCTAssertEqual(link.origin.effectivePort, 3443)
        XCTAssertEqual(link.token, token)
        XCTAssertTrue(link.isPairingURL)
    }

    func testParsesBareOrigin() throws {
        let link = try PairingLink.parse("https://dsh.example.com")
        XCTAssertNil(link.token)
        XCTAssertFalse(link.isPairingURL)
        XCTAssertEqual(link.origin.effectivePort, 443)
    }

    func testFindsTokenAmongOtherFragmentFields() throws {
        let raw = "https://host.example/mobile-access/pair#source=qr&token=" + token
        XCTAssertEqual(try PairingLink.parse(raw).token, token)
    }

    func testRejectsInvalidTokenInFragment() {
        let raw = "https://host.example/mobile-access/pair#token=short"
        XCTAssertThrowsError(try PairingLink.parse(raw)) { error in
            XCTAssertEqual(error as? PairingError, PairingError.invalidToken)
        }
    }

    func testRejectsSchemeLessInput() {
        XCTAssertThrowsError(try PairingLink.parse("192.168.1.5:3443")) { error in
            XCTAssertEqual(error as? PairingError, PairingError.malformedLink)
        }
    }

    func testDescriptionRoundTrips() throws {
        let raw = "https://host.example:3443/mobile-access/pair#token=" + token
        let link = try PairingLink.parse(raw)
        XCTAssertEqual(link.description, raw)
    }
}

final class NavigationPolicyTests: XCTestCase {
    private func policy(port: Int? = 3443) throws -> NavigationPolicy {
        NavigationPolicy(origin: try GatewayOrigin(host: "192.168.1.5", port: port))
    }

    func testAllowsExactOrigin() throws {
        let policy = try policy()
        let url = try XCTUnwrap(URL(string: "https://192.168.1.5:3443/"))
        XCTAssertEqual(policy.decideForMainFrame(url), .allow)
    }

    func testAllowsExactOriginWithExplicitDefaultPort() throws {
        let policy = try policy(port: nil)
        let url = try XCTUnwrap(URL(string: "https://192.168.1.5:443/"))
        XCTAssertEqual(policy.decideForMainFrame(url), .allow)
    }

    func testOpensOtherHTTPSInBrowser() throws {
        let policy = try policy()
        let url = try XCTUnwrap(URL(string: "https://github.com/"))
        XCTAssertEqual(policy.decideForMainFrame(url), .openInBrowser)
    }

    func testBlocksNonHTTPS() throws {
        let policy = try policy()
        let url = try XCTUnwrap(URL(string: "http://192.168.1.5:3443/"))
        XCTAssertEqual(policy.decideForMainFrame(url), .block)
    }

    func testBlocksForeignSubframe() throws {
        let policy = try policy()
        let url = try XCTUnwrap(URL(string: "https://tracker.example/frame"))
        XCTAssertEqual(policy.decideForSubframe(url), .block)
    }

    func testAllowsSameOriginSubframe() throws {
        let policy = try policy()
        let url = try XCTUnwrap(URL(string: "https://192.168.1.5:3443/embed"))
        XCTAssertEqual(policy.decideForSubframe(url), .allow)
    }
}
