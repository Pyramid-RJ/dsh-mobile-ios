import Foundation
import DSHPairing

/// Every mobile-access path the client uses (docs/03 section 1).
public enum MobileAccessEndpoint: String, CaseIterable, Sendable {
    case caCertificate = "/mobile-access/ca.cer"
    case discovery = "/mobile-access/discovery"
    case metadata = "/mobile-access/metadata"
    case health = "/mobile-access/health"
    case nativePair = "/mobile-access/auth/native-pair"
    case nativeRenew = "/mobile-access/auth/native-renew"
    case nativeProbe = "/mobile-access/auth/native-probe"
    case logout = "/mobile-access/auth/logout"

    public func url(on origin: GatewayOrigin) throws -> URL {
        guard let url = origin.url(path: rawValue) else {
            throw MobileAccessFailure.invalidResponse
        }
        return url
    }
}

public protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession-backed transport. The session (and therefore the pinned trust
/// delegate) is injected, so this type never decides trust on its own.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MobileAccessFailure.invalidResponse
            }
            return (data, http)
        } catch let failure as MobileAccessFailure {
            throw failure
        } catch {
            throw MobileAccessFailure.transport(error.localizedDescription)
        }
    }
}

/// The three mobile-access calls: request building plus response validation.
///
/// Wire format verified against upstream NativeAuthClient.kt (2026-11-13): the
/// credential always travels in the JSON body, never in an Authorization
/// header. pair: {"token", "label"}; renew/probe: {"deviceToken"}.
public struct MobileAccessClient {
    public let origin: GatewayOrigin
    public let label: String
    /// When set, every response must carry exactly this instanceId.
    public let expectedInstanceId: String?

    private let transport: HTTPTransport

    public init(
        origin: GatewayOrigin,
        transport: HTTPTransport,
        label: String = "DeepSeek Harness iOS",
        expectedInstanceId: String? = nil
    ) {
        self.origin = origin
        self.transport = transport
        self.label = label
        self.expectedInstanceId = expectedInstanceId
    }

    public func pair(token: String) async throws -> PairingCredential {
        let (data, response) = try await perform(
            endpoint: .nativePair,
            body: ["token": token, "label": label]
        )
        try ensureSuccess(response, data: data)
        let credential = try PairingCredential(data: data)
        try ensureInstance(credential.instanceId)
        return credential
    }

    public func renew(deviceToken: String) async throws -> SessionCredential {
        let (data, response) = try await perform(
            endpoint: .nativeRenew,
            body: ["deviceToken": deviceToken]
        )
        try ensureSuccess(response, data: data)
        let credential = try SessionCredential(data: data)
        try ensureInstance(credential.instanceId)
        return credential
    }

    public func probe(deviceToken: String) async throws -> ProbeResult {
        let (data, response) = try await perform(
            endpoint: .nativeProbe,
            body: ["deviceToken": deviceToken]
        )
        try ensureSuccess(response, data: data)
        let result = try ProbeResult(data: data)
        try ensureInstance(result.instanceId)
        return result
    }

    private func perform(endpoint: MobileAccessEndpoint, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try endpoint.url(on: origin))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin.description, forHTTPHeaderField: "Origin")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("installation-id", forHTTPHeaderField: "X-DSH-Mobile-Capabilities")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await transport.send(request)
    }

    private func ensureSuccess(_ response: HTTPURLResponse, data: Data) throws {
        if let failure = MobileAccessErrorMapper.failure(
            status: response.statusCode,
            errorCode: MobileAccessClient.errorCode(in: data)
        ) {
            throw failure
        }
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.hasPrefix("application/json") else {
            throw MobileAccessFailure.invalidResponse
        }
    }

    /// The gateway must answer for the instance we paired with (docs/03 section 3.4).
    private func ensureInstance(_ actual: String) throws {
        guard let expectedInstanceId, !expectedInstanceId.isEmpty else { return }
        guard actual == expectedInstanceId else {
            throw MobileAccessFailure.invalidResponse
        }
    }

    static func errorCode(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let code = dictionary["error"] as? String else {
            return nil
        }
        return code
    }
}
