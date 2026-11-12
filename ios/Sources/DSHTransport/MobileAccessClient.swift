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

/// Where a device credential travels on renew/probe.
///
/// docs/03 lists deviceToken as the authentication for these endpoints but does
/// not pin the wire format, so this is an explicit, single place to change.
public enum CredentialPlacement: String, Sendable {
    case bearerHeader
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
public struct MobileAccessClient {
    public let origin: GatewayOrigin
    public let label: String
    public let credentialPlacement: CredentialPlacement

    private let transport: HTTPTransport

    public init(
        origin: GatewayOrigin,
        transport: HTTPTransport,
        label: String = "DeepSeek Harness iOS",
        credentialPlacement: CredentialPlacement = .bearerHeader
    ) {
        self.origin = origin
        self.transport = transport
        self.label = label
        self.credentialPlacement = credentialPlacement
    }

    public func pair(token: String) async throws -> PairingCredential {
        let body: [String: Any] = ["token": token, "label": label]
        let (data, response) = try await perform(endpoint: .nativePair, body: body, credential: nil)
        try ensureSuccess(response, data: data)
        return try PairingCredential(data: data)
    }

    public func renew(deviceToken: String) async throws -> SessionCredential {
        let (data, response) = try await perform(endpoint: .nativeRenew, body: [:], credential: deviceToken)
        try ensureSuccess(response, data: data)
        return try SessionCredential(data: data)
    }

    public func probe(deviceToken: String) async throws -> ProbeResult {
        let (data, response) = try await perform(endpoint: .nativeProbe, body: [:], credential: deviceToken)
        try ensureSuccess(response, data: data)
        return try ProbeResult(data: data)
    }

    private func perform(
        endpoint: MobileAccessEndpoint,
        body: [String: Any],
        credential: String?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try endpoint.url(on: origin))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin.description, forHTTPHeaderField: "Origin")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("installation-id", forHTTPHeaderField: "X-DSH-Mobile-Capabilities")
        if let credential {
            switch credentialPlacement {
            case .bearerHeader:
                request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
            }
        }
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

    static func errorCode(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let code = dictionary["error"] as? String else {
            return nil
        }
        return code
    }
}
