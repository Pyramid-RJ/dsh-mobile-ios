import Foundation

/// A pairing link, as printed by the computer or opened from a QR code:
/// https://<host>[:port]/mobile-access/pair#token=<43 characters>.
///
/// A bare origin (https://<host>[:port]) is also accepted, because a user may
/// type the gateway address by hand instead of scanning a pairing QR code.
public struct PairingLink: Equatable, Sendable, CustomStringConvertible {
    public let origin: GatewayOrigin
    public let path: String
    /// Present only when the link carried a pairing token in its fragment.
    public let token: String?

    public init(origin: GatewayOrigin, path: String = PairingLink.pairingPath, token: String? = nil) throws {
        if let token {
            try PairingKey.validate(token: token)
        }
        self.origin = origin
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.token = token
    }

    public static let pairingPath = "/mobile-access/pair"

    public var isPairingURL: Bool {
        path == PairingLink.pairingPath
    }

    public var description: String {
        let base = origin.description + path
        guard let token else { return base }
        return base + "#token=" + token
    }

    public static func parse(_ raw: String) throws -> PairingLink {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PairingError.empty }
        guard let components = URLComponents(string: trimmed) else {
            throw PairingError.malformedLink
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw PairingError.malformedLink
        }
        guard let host = components.host, !host.isEmpty else {
            throw PairingError.missingHost
        }

        let origin = try GatewayOrigin(scheme: scheme, host: host, port: components.port)

        var token: String?
        if let fragment = components.fragment, !fragment.isEmpty {
            for field in fragment.split(separator: "&") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, pair[0] == "token" else { continue }
                let value = String(pair[1])
                try PairingKey.validate(token: value)
                token = value
            }
        }

        let path = components.path.isEmpty ? "/" : components.path
        return try PairingLink(origin: origin, path: path, token: token)
    }
}
