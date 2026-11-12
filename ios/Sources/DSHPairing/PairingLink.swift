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
    /// The gateway CA fingerprint carried as `instance` in the fragment. The
    /// fetched CA must hash to this value; see docs/04 section 2.
    public let instanceId: String?

    public init(
        origin: GatewayOrigin,
        path: String = PairingLink.pairingPath,
        token: String? = nil,
        instanceId: String? = nil
    ) throws {
        if let token {
            try PairingKey.validate(token: token)
        }
        if let instanceId {
            try PairingKey.validate(instanceId: instanceId)
        }
        self.origin = origin
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.token = token
        self.instanceId = instanceId
    }

    public static let pairingPath = "/mobile-access/pair"

    public var isPairingURL: Bool {
        path == PairingLink.pairingPath
    }

    public var description: String {
        let base = origin.description + path
        var fields: [String] = []
        if let instanceId { fields.append("instance=" + instanceId) }
        if let token { fields.append("token=" + token) }
        guard !fields.isEmpty else { return base }
        return base + "#" + fields.joined(separator: "&")
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
        var instanceId: String?
        if let fragment = components.fragment, !fragment.isEmpty {
            for field in fragment.split(separator: "&") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let value = String(pair[1])
                switch pair[0] {
                case "token":
                    try PairingKey.validate(token: value)
                    token = value
                case "instance":
                    try PairingKey.validate(instanceId: value)
                    instanceId = value
                default:
                    continue
                }
            }
        }

        let path = components.path.isEmpty ? "/" : components.path
        return try PairingLink(origin: origin, path: path, token: token, instanceId: instanceId)
    }
}
