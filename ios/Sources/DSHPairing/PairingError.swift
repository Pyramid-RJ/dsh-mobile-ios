import Foundation

/// Everything that can go wrong while parsing a pairing key or a gateway URL.
///
/// The cases are deliberately coarse: the UI only has to tell the user which
/// input to fix, and the contract tests assert on these exact values.
public enum PairingError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Empty input, or only whitespace.
    case empty
    /// A pairing key without the dsh1|dsh2.<instanceId>.<token> shape.
    case malformedKey
    /// Key prefix was neither dsh1 nor dsh2.
    case unknownKind(String)
    /// instanceId is not 64 lowercase hex characters.
    case invalidInstanceId
    /// The token is not 43 base64url characters.
    case invalidToken
    /// The URL scheme is neither https nor http.
    case unsupportedScheme(String)
    /// The URL has no host.
    case missingHost
    /// Port outside 1...65535.
    case invalidPort
    /// The string is not a URL.
    case malformedLink

    /// What `error.localizedDescription` shows. Without this the UI falls back
    /// to "The operation couldn't be completed. (DSHPairing.PairingError error 6.)".
    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case .empty:
            return "empty input"
        case .malformedKey:
            return "pairing key must look like dsh1.<instanceId>.<token>"
        case .unknownKind(let value):
            return "unknown pairing key prefix: " + value
        case .invalidInstanceId:
            return "instanceId must be 64 lowercase hex characters"
        case .invalidToken:
            return "token must be 43 base64url characters"
        case .unsupportedScheme(let value):
            return "unsupported scheme: " + value
        case .missingHost:
            return "URL has no usable host"
        case .invalidPort:
            return "port must be between 1 and 65535"
        case .malformedLink:
            return "not a URL"
        }
    }
}
