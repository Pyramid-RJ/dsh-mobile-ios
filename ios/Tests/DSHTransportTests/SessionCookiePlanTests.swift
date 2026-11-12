import XCTest
import DSHPairing
@testable import DSHTransport

final class SessionCookiePlanTests: XCTestCase {
    private let instanceId = String(repeating: "a", count: 64)
    private let deviceId = String(repeating: "b", count: 32)
    private let token = String(repeating: "A", count: 43)

    private func session() throws -> SessionCredential {
        let payload: [String: Any] = [
            "instanceId": instanceId,
            "deviceId": deviceId,
            "sessionToken": token,
            "csrfToken": token,
            "sessionExpiresAt": 1_735_603_200_000,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try SessionCredential(data: data)
    }

    func testBuildsHostPrefixedCookies() throws {
        let origin = try GatewayOrigin(host: "192.168.1.5", port: 3443)
        let cookies = SessionCookiePlan.cookies(for: origin, session: try session())

        XCTAssertEqual(cookies.map { $0.name }, ["__Host-dsh_ma_session", "__Host-dsh_ma_csrf"])
        XCTAssertEqual(cookies.map { $0.value }, [token, token])
        XCTAssertEqual(Set(cookies.map { $0.domain }), ["192.168.1.5"])
        XCTAssertEqual(Set(cookies.map { $0.path }), ["/"])
        XCTAssertTrue(cookies.allSatisfy { $0.secure })
        XCTAssertEqual(cookies.first?.expires, Date(timeIntervalSince1970: 1_735_603_200))
    }
}
