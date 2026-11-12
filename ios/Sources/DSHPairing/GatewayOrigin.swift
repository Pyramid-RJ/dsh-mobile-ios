import Foundation

/// A gateway origin: scheme + host + port, compared exactly.
///
/// The gateway authenticates requests by Origin header and the page bridge
/// checks securityOrigin, so "roughly the same host" is not good enough:
/// https://a:3443 and https://a:443 are different origins here.
public struct GatewayOrigin: Hashable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int?

    public init(scheme: String = "https", host: String, port: Int? = nil) throws {
        let normalizedScheme = scheme.lowercased()
        guard normalizedScheme == "https" || normalizedScheme == "http" else {
            throw PairingError.unsupportedScheme(scheme)
        }

        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedHost.isEmpty else { throw PairingError.missingHost }
        guard normalizedHost.rangeOfCharacter(from: CharacterSet(charactersIn: " /?#@")) == nil else {
            throw PairingError.missingHost
        }

        if let port, !(1...65535).contains(port) {
            throw PairingError.invalidPort
        }

        self.scheme = normalizedScheme
        self.host = normalizedHost
        self.port = port
    }

    /// Port actually dialled, with the scheme default applied.
    public var effectivePort: Int {
        if let port { return port }
        return scheme == "https" ? 443 : 80
    }

    public var description: String {
        if let port { return scheme + "://" + host + ":" + String(port) }
        return scheme + "://" + host
    }

    public var url: URL? {
        URL(string: description)
    }

    /// Builds an absolute URL for a gateway path, e.g. /mobile-access/health.
    public func url(path: String) -> URL? {
        guard var components = URLComponents(string: description) else { return nil }
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url
    }

    public func isSameOrigin(as other: GatewayOrigin) -> Bool {
        self == other
    }

    public static func == (lhs: GatewayOrigin, rhs: GatewayOrigin) -> Bool {
        lhs.scheme == rhs.scheme
            && lhs.host == rhs.host
            && lhs.effectivePort == rhs.effectivePort
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scheme)
        hasher.combine(host)
        hasher.combine(effectivePort)
    }
}
