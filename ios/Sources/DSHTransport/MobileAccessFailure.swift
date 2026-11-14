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
            return "网关响应不符合移动端协议"
        case .deviceRevoked:
            return "电脑端已移除这台设备，请重新配对"
        case .deviceExpired:
            return "设备凭据已过期，请重新配对"
        case .pairingExpired:
            return "配对已失效，请重新配对"
        case .deviceLimit:
            return "电脑端已达到配对设备上限"
        case .rateLimited:
            return "尝试过于频繁，请稍后再试"
        case .serverUnavailable(let status):
            return "网关不可用（HTTP " + String(status) + "）"
        case .transport(let message):
            return "网络错误：" + message
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
            // The gateway answers `authentication_failed` when the device token
            // is not in its list at all (deleted rather than revoked). For the
            // user that is the same situation as a revocation: this phone is no
            // longer accepted and has to pair again.
            case "authentication_failed": return .deviceRevoked
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
