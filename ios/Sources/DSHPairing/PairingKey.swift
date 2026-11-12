import Foundation

/// A pairing key printed by the computer: dsh1.<instanceId>.<token>.
///
/// dsh1 keys are used with gateways whose certificate the system already
/// trusts; dsh2 keys require the gateway CA to be fetched from
/// /mobile-access/ca.cer and pinned before any trusted request is made.
public struct PairingKey: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable, CaseIterable {
        case dsh1
        case dsh2
    }

    public let kind: Kind
    /// 64 lowercase hex characters, identifies the gateway instance.
    public let instanceId: String
    /// 43 base64url characters, single-use pairing token.
    public let token: String

    public init(kind: Kind, instanceId: String, token: String) throws {
        try PairingKey.validate(instanceId: instanceId)
        try PairingKey.validate(token: token)
        self.kind = kind
        self.instanceId = instanceId
        self.token = token
    }

    public var requiresPinnedCertificateAuthority: Bool {
        kind == .dsh2
    }

    public var description: String {
        kind.rawValue + "." + instanceId + "." + token
    }

    /// Parses a scanned or pasted pairing key. Surrounding whitespace and
    /// newlines are tolerated because QR scanners and clipboards add them.
    public static func parse(_ raw: String) throws -> PairingKey {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PairingError.empty }

        let parts = trimmed
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3 else { throw PairingError.malformedKey }

        guard let kind = Kind(rawValue: parts[0].lowercased()) else {
            throw PairingError.unknownKind(parts[0])
        }
        return try PairingKey(kind: kind, instanceId: parts[1], token: parts[2])
    }

    public static func validate(instanceId: String) throws {
        guard instanceId.count == 64 else { throw PairingError.invalidInstanceId }
        guard instanceId.allSatisfy({ isLowercaseHexDigit($0) }) else {
            throw PairingError.invalidInstanceId
        }
    }

    public static func validate(token: String) throws {
        guard token.count == 43 else { throw PairingError.invalidToken }
        guard token.allSatisfy({ isBase64URLCharacter($0) }) else {
            throw PairingError.invalidToken
        }
    }

    static func isLowercaseHexDigit(_ character: Character) -> Bool {
        "0123456789abcdef".contains(character)
    }

    static func isBase64URLCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter
            || character.isNumber
            || character == "-"
            || character == "_"
    }
}
