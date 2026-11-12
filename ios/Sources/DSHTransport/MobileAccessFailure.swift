import Foundation

/// Failures the mobile-access endpoints can produce, normalised from the HTTP
/// status and the JSON `error` field (docs/03 section 4).
public enum MobileAccessFailure: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidResponse
    case deviceRevoked
    case deviceExpired
    case pairingExpired
    case deviceLimit
    case rateLimited
    case serverUnavailable(status: Int)
    case transport(String)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "gateway response did not match the mobile-access contract"
        case .deviceRevoked:
            return "this device was removed on the computer"
        case .deviceExpired:
            return "the device credential expired; pair again"
        case .pairingExpired:
            return "pairing expired; pair again"
        case .deviceLimit:
            return "the gateway reached its paired-device limit"
        case .rateLimited:
            return "too many attempts; wait and retry"
        case .serverUnavailable(let status):
            return "gateway unavailable (HTTP " + String(status) + ")"
        case .transport(let message):
            return "network error: " + message
        }
    }

    public var errorDescription: String? { description }
}

/// Maps an HTTP status (and the optional `error` code in the body) to a failure.
public enum MobileAccessErrorMapper {
    /// Returns nil for 2xx, which means "the body still has to be validated".
    public static func failure(status: Int, errorCode: String?) -> MobileAccessFailure? {
        if (200...299).contains(status) { return nil }

        if let code = normalized(errorCode) {
            switch code {
            case "device_revoked": return .deviceRevoked
            case "device_expired": return .deviceExpired
            default: break
            }
        }

        switch status {
        case 401, 403: return .pairingExpired
        case 409: return .deviceLimit
        case 429: return .rateLimited
        case 500...599: return .serverUnavailable(status: status)
        default: return .invalidResponse
        }
    }

    /// The contract only accepts 1...64 character codes (docs/03 section 4).
    static func normalized(_ code: String?) -> String? {
        guard let code, (1...64).contains(code.count) else { return nil }
        return code
    }
}
