import Foundation

/// One inbound bridge message: {version: 1, requestId, action, input}.
public struct BridgeRequest: Equatable {
    public let requestId: String
    public let action: String
    /// Kept as [String: Any] on purpose: the payload is forwarded to a feature
    /// handler that knows its own shape, and the bridge only enforces limits.
    public let input: [String: Any]

    public init(requestId: String, action: String, input: [String: Any] = [:]) {
        self.requestId = requestId
        self.action = action
        self.input = input
    }

    public static func == (lhs: BridgeRequest, rhs: BridgeRequest) -> Bool {
        lhs.requestId == rhs.requestId && lhs.action == rhs.action
    }

    public static func parse(_ text: String) throws -> BridgeRequest {
        let data = Data(text.utf8)
        guard data.count <= BridgeLimits.maxInboundBytes else {
            throw BridgeError.tooLarge(data.count)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw BridgeError.notAnObject
        }

        let version = (dictionary["version"] as? NSNumber)?.intValue
        guard version == BridgeLimits.protocolVersion else {
            throw BridgeError.unsupportedVersion(version ?? -1)
        }

        guard let requestId = dictionary["requestId"] as? String, !requestId.isEmpty else {
            throw BridgeError.missingRequestId
        }
        guard requestId.count <= BridgeLimits.maxRequestIdLength else {
            throw BridgeError.requestIdTooLong(requestId.count)
        }

        guard let action = dictionary["action"] as? String, !action.isEmpty else {
            throw BridgeError.missingAction
        }

        var input: [String: Any] = [:]
        if let raw = dictionary["input"] {
            guard let typed = raw as? [String: Any] else {
                throw BridgeError.inputNotAnObject
            }
            input = typed
        }

        return BridgeRequest(requestId: requestId, action: action, input: input)
    }
}
