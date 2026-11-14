import XCTest
import DSHPairing
@testable import DSHTransport

private let instanceId = String(repeating: "a", count: 64)
private let deviceId = String(repeating: "b", count: 32)
private let token = String(repeating: "A", count: 43)

private func data(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func pairPayload(extra: [String: Any] = [:], omit: String? = nil) -> [String: Any] {
    var fields: [String: Any] = [
        "instanceId": instanceId,
        "deviceId": deviceId,
        "deviceToken": token,
        "deviceExpiresAt": 1_735_689_600_000,
        "sessionToken": token,
        "csrfToken": token,
        "sessionExpiresAt": 1_735_603_200_000,
    ]
    if let omit { fields.removeValue(forKey: omit) }
    return fields.merging(extra) { _, new in new }
}

final class PairingPayloadTests: XCTestCase {
    func testDecodesExactKeySet() throws {
        let credential = try PairingCredential(data: data(pairPayload()))
        XCTAssertEqual(credential.instanceId, instanceId)
        XCTAssertEqual(credential.deviceId, deviceId)
        XCTAssertEqual(credential.deviceToken, token)
        XCTAssertTrue(credential.deviceExpiresAt > credential.sessionExpiresAt)
        XCTAssertNil(credential.installationId)
    }

    func testAcceptsOptionalInstallationId() throws {
        let optional = String(repeating: "c", count: 64)
        let credential = try PairingCredential(data: data(pairPayload(extra: ["installationId": optional])))
        XCTAssertEqual(credential.installationId, optional)
    }

    func testRejectsExtraKey() {
        XCTAssertThrowsError(try PairingCredential(data: data(pairPayload(extra: ["unexpected": 1])))) { error in
            XCTAssertEqual(error as? MobileAccessFailure, .invalidResponse)
        }
    }

    func testRejectsMissingKey() {
        XCTAssertThrowsError(try PairingCredential(data: data(pairPayload(omit: "csrfToken")))) { error in
            XCTAssertEqual(error as? MobileAccessFailure, .invalidResponse)
        }
    }

    func testRejectsMalformedInstanceId() {
        let payload = pairPayload(extra: ["instanceId": String(instanceId.dropLast())])
        XCTAssertThrowsError(try PairingCredential(data: data(payload)))
    }

    func testRejectsSessionExpiringAfterDevice() {
        let payload = pairPayload(extra: ["deviceExpiresAt": 1_735_000_000_000])
        XCTAssertThrowsError(try PairingCredential(data: data(payload))) { error in
            XCTAssertEqual(error as? MobileAccessFailure, .invalidResponse)
        }
    }

    func testRejectsOversizedBody() {
        let big = Data(repeating: 0x20, count: StrictJSON.maxBytes + 1)
        XCTAssertThrowsError(try PairingCredential(data: big))
    }
}

final class ErrorMappingTests: XCTestCase {
    func testSuccessfulStatusHasNoFailure() {
        XCTAssertNil(MobileAccessErrorMapper.failure(status: 201, errorCode: nil))
    }

    func testRevokedCodeWins() {
        XCTAssertEqual(MobileAccessErrorMapper.failure(status: 401, errorCode: "device_revoked"), .deviceRevoked)
    }

    func testExpiredCodeWins() {
        XCTAssertEqual(MobileAccessErrorMapper.failure(status: 401, errorCode: "device_expired"), .deviceExpired)
    }

    /// The gateway answers `authentication_failed` when the device was deleted
    /// rather than revoked; the user-facing meaning is the same.
    func testAuthenticationFailedMeansTheDeviceIsGone() {
        XCTAssertEqual(MobileAccessErrorMapper.failure(status: 401, errorCode: "authentication_failed"), .deviceRevoked)
    }

    func testUnauthorizedWithoutCodeIsPairingExpired() {
        XCTAssertEqual(MobileAccessErrorMapper.failure(status: 401, errorCode: nil), .pairingExpired)
    }

    func testConflictIsDeviceLimit() {
        XCTAssertEqual(MobileAccessErrorMapper.failure(status: 409, errorCode: nil), .deviceLimit)
    }

    func testTooManyRequests() {
        XCTAssertEqual(MobileAccessErrorMapper.failure(status: 429, errorCode: nil), .rateLimited)
    }

    func testServerError() {
        XCTAssertEqual(MobileAccessErrorMapper.failure(status: 503, errorCode: nil), .serverUnavailable(status: 503))
    }

    func testOtherClientErrorsAreInvalidResponse() {
        XCTAssertEqual(MobileAccessErrorMapper.failure(status: 400, errorCode: nil), .invalidResponse)
    }
}

private final class FakeTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    var status: Int = 201
    var body: Data = Data()
    var contentType: String = "application/json; charset=utf-8"

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        return (body, response)
    }
}

final class ClientRequestTests: XCTestCase {
    private func makeClient(_ transport: FakeTransport) throws -> MobileAccessClient {
        MobileAccessClient(origin: try GatewayOrigin(host: "192.168.1.5", port: 3443), transport: transport)
    }

    func testPairBuildsContractRequest() async throws {
        let transport = FakeTransport()
        transport.status = 201
        transport.body = data(pairPayload())
        let client = try makeClient(transport)
        _ = try await client.pair(token: token)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://192.168.1.5:3443/mobile-access/auth/native-pair")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://192.168.1.5:3443")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-origin")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DSH-Mobile-Capabilities"), "installation-id")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(request.httpBody)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(decoded["token"], token)
        XCTAssertEqual(decoded["label"], "DeepSeek Harness iOS")
    }

    func testRenewSendsDeviceTokenInBody() async throws {
        let transport = FakeTransport()
        transport.status = 200
        transport.body = data([
            "instanceId": instanceId,
            "deviceId": deviceId,
            "sessionToken": token,
            "csrfToken": token,
            "sessionExpiresAt": 1_735_603_200_000,
        ])
        let client = try makeClient(transport)
        let session = try await client.renew(deviceToken: token)

        XCTAssertEqual(session.sessionToken, token)
        let request = try XCTUnwrap(transport.requests.first)
        // Verified against upstream NativeAuthClient.kt: the credential is a
        // body field, not an Authorization header.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(decoded["deviceToken"], token)
    }

    func testRejectsUnexpectedInstance() async throws {
        let transport = FakeTransport()
        transport.status = 201
        transport.body = data(pairPayload())
        let client = MobileAccessClient(
            origin: try GatewayOrigin(host: "192.168.1.5", port: 3443),
            transport: transport,
            expectedInstanceId: String(repeating: "d", count: 64)
        )

        do {
            _ = try await client.pair(token: token)
            XCTFail("expected a failure")
        } catch let failure as MobileAccessFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }

    func testErrorBodyDrivesFailure() async throws {
        let transport = FakeTransport()
        transport.status = 401
        transport.body = data(["error": "device_revoked"])
        let client = try makeClient(transport)

        do {
            _ = try await client.renew(deviceToken: token)
            XCTFail("expected a failure")
        } catch let failure as MobileAccessFailure {
            XCTAssertEqual(failure, .deviceRevoked)
        }
    }

    func testNonJSONContentTypeIsRejected() async throws {
        let transport = FakeTransport()
        transport.status = 201
        transport.body = data(pairPayload())
        transport.contentType = "text/html"
        let client = try makeClient(transport)

        do {
            _ = try await client.pair(token: token)
            XCTFail("expected a failure")
        } catch let failure as MobileAccessFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }
}
