import Foundation

/// One outbound reply: {requestId, ok: true, value} or {requestId, ok: false, code, message}.
public struct BridgeReply {
    public let requestId: String
    public let ok: Bool
    public let value: Any?
    public let code: BridgeFailureCode?
    public let message: String?

    private init(requestId: String, ok: Bool, value: Any?, code: BridgeFailureCode?, message: String?) {
        self.requestId = requestId
        self.ok = ok
        self.value = value
        self.code = code
        self.message = message
    }

    public static func success(requestId: String, value: Any?) -> BridgeReply {
        BridgeReply(requestId: requestId, ok: true, value: value, code: nil, message: nil)
    }

    public static func failure(requestId: String, code: BridgeFailureCode, message: String) -> BridgeReply {
        BridgeReply(requestId: requestId, ok: false, value: nil, code: code, message: message)
    }

    /// Encodes the reply; a reply over the limit degrades to payload_too_large
    /// instead of being silently truncated (docs/02 section 4.3).
    public func json(limit: Int = BridgeLimits.maxReplyBytes) -> String {
        var dictionary: [String: Any] = ["requestId": requestId, "ok": ok]
        if ok {
            dictionary["value"] = value ?? [:]
        } else {
            dictionary["code"] = (code ?? .failed).rawValue
            dictionary["message"] = message ?? ""
        }

        if let data = try? JSONSerialization.data(withJSONObject: dictionary),
           data.count <= limit,
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        let downgraded: [String: Any] = [
            "requestId": requestId,
            "ok": false,
            "code": BridgeFailureCode.payloadTooLarge.rawValue,
            "message": "reply exceeded " + String(limit) + " bytes",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: downgraded),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{\"requestId\":\"" + requestId + "\",\"ok\":false,\"code\":\"failed\",\"message\":\"encoding failed\"}"
    }
}
